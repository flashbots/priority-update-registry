# PrioUpdateRegistry

On-chain registry that allows authorized updaters to publish per-target priority updates that are only valid for the current block. Targets (e.g. contracts) can read their current priority update during execution. See [summary](summary.html) for a visual overview.

Priority updates for the current block are constantly sent to the block builder. The block builder ensures that priority updates for a contract always land in the block before any transaction that interacts with that contract, and that updates for contracts not touched in the block are excluded. The fixed storage layout of this contract ensures that block builders can write an efficient implementation of this functionality. Using a global contract makes it easy for the builder to ensure the prio updates are not doing anything unexpected (e.g. arbitraging other pools). 

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

- Each target manages its own set of authorized updaters. An updater can be an EOA or, via ERC-1271, a smart contract wallet (see [Signed Updates and ERC-1271](#signed-updates-and-erc-1271)).
- A priority update consists of a 27-byte (216-bit) base value plus k additional 32-byte slots. Each additional slot increases the gas cost of an update. The number of slots is stored on-chain (max 255).
- Each target can have multiple independent **lanes** (identified by `laneIndex`). Updates to different lanes are independent — they land separately and have separate freshness.
- A priority update is only valid for the block that it targets.
- Priority updates can only be read by the target contract itself (via `msg.sender`).

### Writing Priority Updates

All write methods require `blockTimestamp == block.timestamp`, `chainId == block.chainid`, and at least one slot (max 255). `slots[0]` must fit in 27 bytes (216 bits), as it is packed into the base storage word alongside the timestamp and slot count. `slots[1..]` are full `uint256` values. Writes overwrite only the supplied slots.

- **`updateState(address target, uint256 laneIndex, uint256 blockTimestamp, uint256[] slots)`**
  Direct call from the authorized updater (`msg.sender` must match the stored updater for `target`).

- **`batchUpdateStateWithSignature(SignedUpdate[] updates)`**
  Batch multiple signed updates in a single transaction. Each element contains `(target, signer, laneIndex, blockTimestamp, slots, signature)`. The signature is verified against `signer` either via ECDSA recovery (EOA) or via ERC-1271 (when `signer == target`). See [Signed Updates and ERC-1271](#signed-updates-and-erc-1271).

### Reading Priority Updates

- **`getState(uint256 laneIndex) → uint256[]`** — called by `target` itself (`msg.sender` is the target). Reverts if no priority update was written in the current block for the given lane. Returns exactly the number of slots that were written.
- `isUpdater(address target, address updater) → bool` — whether `updater` is authorized to write state for `target`.

### Updater Management

Each target manages its own set of updaters. Authorizations are scoped to `msg.sender`.

- `addUpdater(address updater)` — authorize `updater` to write state for `msg.sender`.
- `removeUpdater(address updater)` — revoke `updater`'s authorization for `msg.sender`.

### Signed Updates and ERC-1271

Each `SignedUpdate` carries an explicit `signer`. Verification dispatches on `signer == target`:

- **`signer != target`** — ECDSA: `ecrecover(digest, signature)` must equal `signer`, and `isUpdater[target][signer]` must be `true`.
- **`signer == target`** — [ERC-1271](https://eips.ethereum.org/EIPS/eip-1271): `target.isValidSignature(digest, signature)` must return `0x1626ba7e`. No `addUpdater` registration needed — the target authorizes by signing.

Either failure reverts with `NotAuthorized`. Anyone may relay the batch.

### EIP-712

- `DOMAIN_SEPARATOR() → bytes32`
- `UPDATE_TYPEHASH` — `keccak256("UpdateState(address target,uint256 laneIndex,uint256 blockTimestamp,uint256[] slots)")`

Note: the `signer` field in `SignedUpdate` is **not** part of the typed-data hash. It's claimed by the relayer and either checked against ECDSA recovery (must match) or used as the contract to call `isValidSignature` on (which decides for itself).

Domain name: `"PrioUpdateRegistry"`, version: `"1"`.

## Storage Layout

**Updater storage.** `isUpdater` is a nested mapping at storage slot `0`:

```
slot = keccak256(abi.encode(updater, keccak256(abi.encode(target, 0))))
value = 1 if authorized, else 0
```

**Lane state storage.** Each (target, laneIndex) pair has a contiguous range of slots:

```
base = keccak256(abi.encode(target, laneIndex))
slot[i] = base + i
```

**Slot 0** (base slot) packs three fields into a single word:

```
[ blockTimestamp (32 bits) | numSlots (8 bits) | slot0 value (216 bits) ]
  bits 255..224              bits 223..216        bits 215..0
```

**Slots 1..k** store raw `uint256` values.

`getState` checks that `blockTimestamp` in slot 0 matches `block.timestamp`; if not, the priority update is stale and the call reverts. The `numSlots` field records how many slots were written so `getState` returns exactly that many. Different lanes are fully independent — updating one lane does not affect others.

## Gas Costs

Gas costs are measured via `test/GasBenchmark.t.sol`.

| Method | Formula |
|---|---|
| Direct `updateState` | `21000 + 9393 + k × 5212` |
| Batched `batchUpdateStateWithSignature` (EOA path) | `21000 + 872 + n × (16829 + k × 5237)` |
| `getState` (warm) | `1191 + k × 269` |
| `getState` (cold) | `3191 + k × 2269` |

Where **k** = number of additional slots (beyond the packed slot 0) and **n** = number of updates in the batch. The batched formula is calibrated for ECDSA-signed updates; the ERC-1271 path adds a `staticcall` whose cost depends on the target's `isValidSignature` implementation.

These formulas measure steady-state overwrites on already-initialized storage, which is the benchmark setup used in `test/GasBenchmark.t.sol`. They do not model first writes or cases where a write grows into previously zero slots, which are more expensive because they include zero-to-nonzero `SSTORE`s.

### Comparison: n direct transactions vs 1 batched transaction (k = 0)

| n (updates) | n × direct txs | 1 batched tx | Savings |
|---|---|---|---|
| 1 | 30,393 | 38,701 | -27% |
| 2 | 60,786 | 55,530 | 9% |
| 5 | 151,965 | 106,017 | 31% |
| 10 | 303,930 | 190,162 | 38% |

Batching breaks even at ~2 updates and saves increasingly more as n grows.

## Block Builder Integration

Block builders accept these transactions via `eth_sendBundle`. The priority update must be included as a transaction in the bundle.
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
5. Allow transactions that change the updater set (`addUpdater`/`removeUpdater`) to land at the bottom of the block.

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
