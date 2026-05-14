# PrioUpdateRegistry

On-chain registry that allows authorized updaters to publish per-target priority updates that are only valid for the current block. Targets (e.g. contracts) can read their current priority update during execution.

Priority updates for the current block are constantly sent to the block builder. The block builder ensures that priority updates for a contract always land in the block before any transaction that interacts with that contract, and that updates for contracts not touched in the block are excluded. The fixed storage layout of this contract ensures that block builders can write an efficient implementation of this functionality. Using a global contract makes it easy for the builder to ensure the prio updates are not doing anything unexpected (e.g. arbitraging other pools). 

## Motivation

- Priority updates allow any integrated smart contract to set per-block state that will be inserted in the block before any interaction that reads this state.
- Updates that are not used in the block do not land onchain.
- An update transaction can only update the state of the registry smart contract. This makes block builder integration easier to reason about. There is no risk for this priority update to be used in an unintended way.
- One fixed contract design is more scalable and more composable. Because of the defined logic of this update for all smart contracts, it's easy to process updates for many contracts at the same time. Multiple updates from different users can be batched to reduce costs.

## Why we propose one priority update registry vs allowing each smart contract to define their own priority update transaction.

An alternative design would be to allow each contract to have their own way to execute priority update. Each contract would send some opaque transaction that must be inserted before anything else that touched their smart contract in the block. 

The main downside of this is the complexity of execution when inserting priority update.

With fixed priority update structure we get these benefits:
1. Effect of update on state is know upfront even without full transaction simualtion. 
2. The cost of doing an update transaction is fixed.
3. If priority update can execute arbitrary code then updates for different contracts might conflict with each other and it hurts composability. 
4. There is a risk that priority update can be abused to do something that is not desired by the user of that contract.     

## Contract Interface

### Priority Updates

- Each target manages its own set of authorized updaters; registered updaters must be EOAs (ECDSA signing). A target can additionally authorize itself by signing via [ERC-1271](https://eips.ethereum.org/EIPS/eip-1271), without prior registration (see [Signed Updates and ERC-1271](#signed-updates-and-erc-1271)).
- A priority update consists of a 27-byte (216-bit) base value plus k additional 32-byte slots. Each additional slot increases the gas cost of an update. The number of slots is stored on-chain (max 255).
- Each target can have multiple independent **lanes** (identified by `laneIndex`). Updates to different lanes are independent — they land separately and carry their own timestamp.
- Each update carries an `updateTimestamp` chosen by the writer, stored alongside the data and returned to readers so they can decide whether to act on it.
- Priority updates can only be read by the target contract itself (via `msg.sender`).

### Writing Priority Updates

All write methods require at least one slot (max 255). `slots[0]` must fit in 27 bytes (216 bits), as it is packed into the base storage word alongside the timestamp and slot count. `slots[1..]` are full `uint256` values.

The `updateTimestamp` is a `uint32` chosen by the writer and subject to two checks:

- It must lie within `[block.timestamp - MAX_UPDATE_AGE, block.timestamp + MAX_UPDATE_LEAD_TIME]` (inclusive); otherwise the call reverts with `InvalidUpdateTimestamp`. `MAX_UPDATE_AGE` and `MAX_UPDATE_LEAD_TIME` are immutable constructor parameters.
- It must be `>=` the timestamp currently stored for that lane; older writes revert with `StaleUpdate`. Writes with an equal or newer timestamp overwrite the previous value.

- **`updateState(address target, uint256 laneIndex, uint32 updateTimestamp, uint256[] slots)`**
  Direct call from the authorized updater (`msg.sender` must match the stored updater for `target`).

- **`batchUpdateStateWithSignature(SignedUpdate[] updates)`**
  Batch multiple signed updates in a single transaction. Each element contains `(address target, address signer, uint256 laneIndex, uint32 updateTimestamp, uint256[] slots, bytes signature)`. The signature is verified against `signer` either via ECDSA recovery (EOA) or via ERC-1271 (when `signer == target`). See [Signed Updates and ERC-1271](#signed-updates-and-erc-1271).

### Reading Priority Updates

- **`getState(uint256 laneIndex) → (uint32 updateTimestamp, uint256[] slots)`** — called by `target` itself (`msg.sender` is the target). Never reverts. Returns the stored `updateTimestamp` (`0` if no update was ever written) together with exactly the number of slots that were written (empty array if no update was ever written). Callers decide how to interpret freshness from `updateTimestamp`.
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
- `UPDATE_TYPEHASH` — `keccak256("UpdateState(address target,uint256 laneIndex,uint32 updateTimestamp,uint256[] slots)")`

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
[ updateTimestamp (32 bits) | numSlots (8 bits) | slot0 value (216 bits) ]
  bits 255..224              bits 223..216        bits 215..0
```

**Slots 1..k** store raw `uint256` values.

`getState` returns the packed `updateTimestamp` alongside the slots without any freshness check — readers decide how to interpret it. The `numSlots` field records how many slots were written so `getState` returns exactly that many (and an empty array when no update has ever been written). Different lanes are fully independent — updating one lane does not affect others.

### Collision resistance

Each lane spans up to 255 contiguous slots from a caller-chosen base.

- Lane base: `keccak256(abi.encode(target, laneIndex))`
- `isUpdater` value: `keccak256(abi.encode(updater, keccak256(abi.encode(target, 0))))`

A collision requires finding a keccak output within 255 of a chosen slot — `≈ 2^248` work. Reduces to keccak preimage/collision resistance.

## Threat Model

### Builder selects which update lands

The block builder receives a continuous stream of priority updates for the upcoming block and may insert any one of them. The contract trusts the builder to insert the most recent update it received. Builder bugs or propagation issues can cause a stale (but still within the validity window) update to land instead of the freshest one. The registry cannot distinguish "stale but valid" from "freshest" on-chain.

### Target contracts must validate `updateTimestamp`

`getState` returns `updateTimestamp` alongside the slots without any freshness check. Target contracts MUST inspect `updateTimestamp` themselves — e.g. require `updateTimestamp == block.timestamp` for strict same-block freshness, or enforce a maximum age tied to their own logic. The registry's `MAX_UPDATE_AGE` / `MAX_UPDATE_LEAD_TIME` bounds only constrain what writers can put on-chain; they are not a substitute for per-target freshness checks.

### Signed updates are replayable within their window

A `SignedUpdate` is not single-use. As long as (a) the update's `updateTimestamp` is `>=` the lane's stored timestamp and (b) `updateTimestamp` still lies within `[block.timestamp - MAX_UPDATE_AGE, block.timestamp + MAX_UPDATE_LEAD_TIME]`, any party can re-relay the signature. A replay produces the same on-chain state as the original write, so it cannot corrupt state.

## Gas Costs

Gas costs are measured via `test/GasBenchmark.t.sol`.

| Method | Formula |
|---|---|
| Direct `updateState` | `21000 + 9712 + k × 5212` |
| Batched `batchUpdateStateWithSignature` (EOA path) | `21000 + 916 + n × (17366 + k × 5235)` |
| `getState` (warm) | `1311 + k × 269` |
| `getState` (cold) | `3311 + k × 2269` |

Where **k** = number of additional slots (beyond the packed slot 0) and **n** = number of updates in the batch. The batched formula is calibrated for ECDSA-signed updates; the ERC-1271 path adds a `staticcall` whose cost depends on the target's `isValidSignature` implementation.

These formulas measure steady-state overwrites on already-initialized storage, which is the benchmark setup used in `test/GasBenchmark.t.sol`. They do not model first writes or cases where a write grows into previously zero slots, which are more expensive because they include zero-to-nonzero `SSTORE`s.

### Comparison: n direct transactions vs 1 batched transaction (k = 0)

| n (updates) | n × direct txs | 1 batched tx | Savings |
|---|---|---|---|
| 1 | 30,712 | 39,282 | -27% |
| 2 | 61,424 | 56,648 | 8% |
| 5 | 153,560 | 108,746 | 30% |
| 10 | 307,120 | 195,576 | 37% |

Batching breaks even at ~2 updates and saves increasingly more as n grows.

## Block Builder Integration

Block builders accept these transactions via special endpoint.
If another prio update arrives at the block builder, it replaces the previous one. Only one priority update can land in the block and the builder verifies that it's the latest that it received.

### Simulating priority updates inside the block builder

We suggest this approach to applying priority update in the builder.

1. Keep separate "mempool" of unlanded priority updates and maintain it with new updates as they arrive.
2. Prohibit priority updates from landing in the block except if the builder explicitly inserts them.
3. After a user transaction is executed, a priority update transaction should be inserted in front of the user transaction.

## Example Integration

[`src/ExamplePropAmm.sol`](src/ExamplePropAmm.sol) is a minimal proprietary AMM that reads its per-pair pricing parameters (`concentration`, `multX`, `multY`) from this registry. The market maker publishes a priority update each block; swappers read the latest parameters via `getState`, and the AMM enforces freshness against a configurable `maxParameterAge`. Adapted from [fahimahmedx/prop-amm](https://github.com/fahimahmedx/prop-amm), which uses a different top-of-block storage mechanism.

## Testing

```shell
just test
```
