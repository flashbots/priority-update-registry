# PrioUpdateRegistry

On-chain registry that allows authorized updaters to publish per-target priority updates that are only valid for the current block. Targets (e.g. contracts) can read their current priority update during execution.

Priority updates for the current block are constantly sent to the block builder. The block builder ensures that priority updates for a contract always land in the block before any transaction that interacts with that contract, and that updates for contracts not touched in the block are excluded. The fixed storage layout of this contract ensures that block builders can write an efficient implementation of this functionality.

## Motivation

- Priority updates allow any integrated smart contract to set per-block state that will be inserted in the block before any interaction that reads this state.
- Updates that are not used in the block do not land onchain.
- An update transaction can only update the state of the registry smart contract. This makes block builder integration easier to reason about. There is no risk for this priority update to be used in an unintended way.
- One fixed contract design is more scalable and more composable. Because of the defined logic of this update for all smart contracts, it's easy to process updates for many contracts at the same time. Multiple updates from different users can be batched to reduce costs.

## Why we propose one priority update registry vs allowing each smart contract to define their own priority update transaction.

An alternative design would be to allow each contract to have their own way to execute priority update. Each contract would send some opaque transaction that must be inserted before anything else that touched their smart contract in the block. 

The main downside of this is the complexity of execution when inserting priority update.
1. When the block builder executes a user transaction that requires the builder to insert a priority update in front of it, the builder would need to stop simulating the user transaction, simulate the priority update, and resimulate the user transaction. With the registry contract, the builder can modify registry state without stopping the user transaction.
2. The cost of doing an update transaction is known upfront.
3. If priority update can execute arbitrary code then updates for different contracts might conflict with each other and it hurts composability. 
4. There is a risk that priority update can be abused to do something that is not desired by the user of that contract.     

## Contract Interface

### Priority Updates

- Each target contract has exactly one authorized updater address that can publish priority updates. Authorized updater must be an EOA.
- A priority update consists of an 8-byte (64-bit) base value plus k additional 32-byte slots. Each additional slot increases the gas cost of an update.
- A priority update is only valid for the block that it targets.
- Priority updates can only be read by the target contract itself (via `msg.sender`).
- Each target is expected to use a fixed read width (value of k).

### Writing Priority Updates

All write methods require `blockTimestamp == block.timestamp`, `chainId == block.chainid`, and at least one slot. `slots[0]` must fit in 8 bytes (64 bits), as it is packed into the base storage word alongside the updater address and timestamp. `slots[1..]` are full `uint256` values. Writes overwrite only the supplied slots.

- **`updateState(address target, uint256 blockTimestamp, uint256[] slots)`**
  Direct call from the authorized updater (`msg.sender` must match the stored updater for `target`).

- **`batchUpdateStateWithSignature(SignedUpdate[] updates)`**
  Batch multiple signed updates in a single transaction. Anyone can relay; the updater is recovered from an EIP-712 signature. Each element contains `(target, blockTimestamp, chainId, slots, signature)`.

### Reading Priority Updates

- **`getState(uint256 numSlots) → uint256[]`** — called by `target` itself (`msg.sender` is the target). Reverts if no priority update was written in the current block. `numSlots` must be at least 1. Returns `numSlots` values starting from the first slot. Callers should use the target's fixed configured width, because shorter writes leave old tail slots unchanged.
- `getUpdater(address target) → address` — returns the authorized updater for `target`.

### Admin

- `admin() → address` — current admin.
- `transferAdmin(address newAdmin)` — transfer admin role. Only callable by current admin.
- `setUpdater(address target, address updater)` — authorize `updater` to write state for `target`. Only callable by admin.


### EIP-712

- `DOMAIN_SEPARATOR() → bytes32`
- `UPDATE_TYPEHASH` — `keccak256("UpdateState(address target,uint256 blockTimestamp,uint256 chainId,uint256[] slots)")`

Domain name: `"PrioUpdateRegistry"`, version: `"1"`.

## Storage Layout

Each target's priority update is stored at a contiguous range of slots computed by `_slot(target, index)`:

```
slot[index] = 0xcc << 248 | uint160(target) << 88 | index
```

**Slot 0** (base slot) packs three fields into a single word:

```
[ blockTimestamp (32 bits) | updater address (160 bits) | slot0 value (64 bits) ]
  bits 255..224              bits 223..64                  bits 63..0
```

**Slots 1..k** store raw `uint256` values.

`getState` checks that `blockTimestamp` in slot 0 matches `block.timestamp`; if not, the priority update is stale and the call reverts. The timestamp freshness check applies only to slot 0; higher slots are trusted as the current state for whatever fixed width the target uses.

## Gas Costs

Gas costs are measured via `test/GasBenchmark.t.sol`.

| Method | Formula |
|---|---|
| Direct `updateState` | `21000 + 6876 + k × 5212` |
| Batched `batchUpdateStateWithSignature` | `21000 + 830 + n × (13331 + k × 5236)` |
| `getState` (warm) | `1090 + k × 269` |
| `getState` (cold) | `3090 + k × 2269` |

Where **k** = number of additional slots (beyond the packed slot 0) and **n** = number of updates in the batch.

These formulas measure steady-state overwrites on already-initialized storage, which is the benchmark setup used in `test/GasBenchmark.t.sol`. They do not model first writes or cases where a write grows into previously zero slots, which are more expensive because they include zero-to-nonzero `SSTORE`s.

### Comparison: n direct transactions vs 1 batched transaction (k = 0)

| n (updates) | n × direct txs | 1 batched tx | Savings |
|---|---|---|---|
| 1 | 27,876 | 35,161 | -26% |
| 2 | 55,752 | 48,492 | 14% |
| 5 | 139,380 | 88,485 | 37% |
| 10 | 278,760 | 155,140 | 45% |

Batching breaks even at ~2 updates and saves increasingly more as n grows.

## Block Builder Integration

Block builders accept these transactions via `eth_sendBundle` or `eth_sendRawTransaction`. The priority update must be included as a transaction in the bundle.
If another prio update arrives at the block builder, it replaces the previous one. Only one priority update can land in the block and the builder verifies that it's the latest that it received.

### Direct updates using `updateState`

* The call must be made in a top-level transaction signed by the authorized updater address.
* The transaction must be an EIP-1559 transaction with 0 priority fee (to ensure that transaction execution does not conflict with other transactions). Set a high max fee so the transaction remains valid if the base fee changes.

### Signed updates using `batchUpdateStateWithSignature`

* Updates should be sent as part of a valid transaction calling `batchUpdateStateWithSignature`.
* The builder may parse signed updates from the transaction and apply them as part of a different transaction.

### Simulating priority updates inside the block builder

We suggest this approach to applying priority update in the builder.

1. Keep separate "mempool" of unlanded priority updates and maintain it with new updates as they arrive.
2. Prohibit priority updates from landing in the block except if the builder explicitly inserts them.
3. When simulating a user transaction that needs a priority update, apply it directly to the state that EVM reads.
4. After a user transaction is executed, a priority update transaction can be inserted in front of the user transaction (e.g. batched on top of block). This is safe to do since only the builder is allowed to modify the registry contract and all priority updates are non-conflicting with other transactions in the block.
5. Allow admin smart contract transactions that change this state to land at the bottom of the block.

## Testing

Build and run the full test suite:

```shell
forge build
forge test
```

Run gas benchmarks (uses `--isolate` via per-test config):

```shell
forge test --match-contract GasBenchmarkTest -vv
```

Run only the main unit tests:

```shell
forge test --match-contract PrioUpdateRegistryTest -vv
```
