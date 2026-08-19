# PrioUpdateRegistry V2

For the V1 design and documentation, see [`README.v1.md`](README.v1.md).

On-chain registry that allows authorized updaters to publish raw per-target priority updates. Targets (e.g. contracts) can read their current priority update during execution and interpret it according to their own application logic.

Priority updates for the current block are constantly sent to the block builder. The block builder ensures that priority updates for a contract always land in the block before any transaction that interacts with that contract, and that updates for contracts not touched in the block are excluded. The fixed storage layout of this contract ensures that block builders can write an efficient implementation of this functionality. Using a global contract makes it easy for the builder to ensure that direct priority updates only write to registry storage. Decoder updates may call up to two configured contracts.

V2 intentionally has no freshness logic. The registry does not know whether a slot contains a timestamp, block number, sequence number, price, or any other value. Targets define their own slot layout and validate freshness and all other application-specific properties when they read it.

## Motivation

- Priority updates allow any integrated smart contract to set per-block state that will be inserted in the block before any interaction that reads this state.
- Updates that are not used in the block do not land onchain.
- Direct update transactions only update the state of the registry smart contract. This makes block builder integration easier to reason about.
- One fixed contract design is more scalable and more composable. Targets remain free to define their own data layout and validation rules.
- Freshness is application-specific. Removing it from the registry lets targets use timestamps, block numbers, sequence numbers, or no freshness marker at all.

## Why we propose one priority update registry vs allowing each smart contract to define their own priority update transaction.

An alternative design would be to allow each contract to have its own way to execute priority updates. Each contract would send some opaque transaction that must be inserted before anything else that touched its smart contract in the block.

The main downside of this is the complexity of execution when inserting priority updates.

With a fixed priority update structure we get these benefits:

1. Direct updates have a known and narrow effect: they write raw words to a target's lane in the registry.
2. The amount of registry write work is determined by the number of slots supplied by the updater or returned by the decoder.
3. Decoder validation runs under `STATICCALL`, so it cannot introduce external state writes.
4. Targets can opt into a decoder for authorization or payload validation without adding those rules to the registry.
5. Decoder updates may call up to two configured contracts before validation.

## Contract Interface

### Priority Updates

- Each target can authorize addresses to write raw slot values on its behalf.
- Each target can have multiple independent **lanes**, identified by `laneIndex`.
- Each lane contains up to 255 full `uint256` slots. The registry does not reserve a header or interpret any bits.
- The registry does not store the number of slots in a lane. Readers choose how many slots to read.
- Priority updates can only be read through the contract interface by the target itself, via `msg.sender`.

Targets can choose either of two write paths for each lane:

- **Updater-managed lane** — an authorized updater writes raw slots directly.
- **Decoder-managed lane** — the target permanently assigns a decoder that validates an opaque payload and returns the raw slots to store. Anyone can relay the payload.

### Writing Priority Updates

All write methods require between 1 and 255 slots. Every slot is stored as a full `uint256` value.

The registry performs no freshness, ordering, monotonicity, or application-level validation. A target that needs a timestamp, block number, or sequence number must include it in its own slot layout and check it when reading.

Writes replace only the supplied prefix of a lane. A shorter write does not clear values left by an earlier longer write.

- **`updateState(address target, uint256 laneIndex, uint256[] slots)`**
  Direct write from an authorized updater. `msg.sender` must be authorized for `target`, and the lane must not have a decoder.

- **`updateStateWithDecoder(address target, uint256 laneIndex, bytes aux, TrustedCall[] calls)`**
  Permissionless relay for a decoder-managed lane. Executes `calls`, validates through the decoder, and stores the returned slots.

If multiple valid writes to the same lane land in a block, the last write determines the value of every slot it supplies.

### Reading Priority Updates

- **`getSlot(uint256 laneIndex, uint256 slotIndex) → uint256 value`** — returns one slot from `msg.sender`'s lane. `slotIndex` must be less than 255.
- **`getSlots(uint256 laneIndex, uint256 slotIndex, uint256 slotCount) → uint256[] slots`** — returns the contiguous range `[slotIndex, slotIndex + slotCount)` from `msg.sender`'s lane. The complete range must fit within the lane's 255 slots.
- **`getState(uint256 laneIndex, uint256 count) → uint256[] slots`** — returns the first `count` slots from `msg.sender`'s lane. `count` may be between 0 and 255.
- `isUpdater(address target, address updater) → bool` — whether `updater` is authorized to write directly for `target`.
- `laneDecoder(address target, uint256 laneIndex) → address` — the decoder assigned to a lane, or the zero address if the lane is updater-managed.
- `isTrustedCallTarget(address target) → bool` — whether decoder updates may call `target` directly.

Unwritten slots return zero. The registry does not return a stored length, timestamp, or freshness result.

### Updater Management

Each target manages its own set of updaters. Authorizations are scoped to `msg.sender`.

- `addUpdater(address updater)` — authorize `updater` to write state for `msg.sender`.
- `removeUpdater(address updater)` — revoke `updater`'s authorization for `msg.sender`.

Updater authorization applies only to lanes without a decoder.

### Trusted Calls

The constructor accepts up to two trusted targets. Zero leaves a position unused; nonzero targets must have code.

```solidity
struct TrustedCall {
    address target;
    bytes data;
}
```

Calls execute in order with zero value. The decoder receives their return data and `keccak256(abi.encode(calls))`. Failures, state-changing callbacks, and lane reads revert.

### Decoder Management

- **`setDecoder(uint256 laneIndex, address decoder)`** — permanently assign a decoder to `msg.sender`'s lane.

A decoder must have code when it is registered. Once set, it cannot be removed or replaced, and direct updater writes to that lane are disabled.

The decoder implements:

```solidity
function validateAndUnpack(
    address target,
    uint256 laneIndex,
    bytes calldata aux,
    bytes32 trustedCallsHash,
    bytes[] calldata callResults
)
    external
    view
    returns (uint256[] memory slots);
```

The decoder is responsible for authorization, signatures, replay protection, freshness, payload decoding, and any other validation required by the target. It should bind its authorization to `target` and `laneIndex` where appropriate. Authenticated `aux` must also bind `trustedCallsHash` when calls are used. It must return between 1 and 255 slots.

The registry calls the decoder with `STATICCALL`, so the decoder cannot modify state during validation. A proxy decoder can still change behavior through upgrades even though its registered address is permanent.

### Freshness and Application Validation

V2 performs no freshness checks on writes or reads.

A target that needs freshness should store its chosen marker in a slot and validate it every time it reads registry state. For example, a target may store a timestamp in slot 0 and accept it only when:

```solidity
updateTimestamp <= block.timestamp
    && block.timestamp - updateTimestamp <= maxUpdateAge
```

The same pattern can be implemented with block numbers or an application-defined sequence. The registry does not require one convention.

## Storage Layout

**Updater storage.** `isUpdater` is a nested mapping at storage slot `0`:

```
slot = keccak256(abi.encode(updater, keccak256(abi.encode(target, 0))))
value = 1 if authorized, else 0
```

**Decoder storage.** `laneDecoder` is a nested mapping at storage slot `1`:

```
slot = keccak256(abi.encode(laneIndex, keccak256(abi.encode(target, 1))))
value = decoder address, or 0 if no decoder is set
```

**Callback lock.** Transient slot `keccak256("PrioUpdateRegistryV2.callbackLock")` (EIP-1153).

**Trusted call targets.** Two immutable addresses; no storage slots.

**Lane state storage.** Each `(target, laneIndex)` pair has a domain-separated contiguous range of slots:

```
LANE_NAMESPACE = keccak256("PrioUpdateRegistryV2.lane.v1")
base = keccak256(abi.encode(LANE_NAMESPACE, target, laneIndex))
slot[i] = base + i, for 0 <= i < 255
```

Every lane slot stores one raw `uint256`. There is no packed header, timestamp, or stored slot count. The namespace separates lane bases from the registry's mapping storage domains; overlap between independent lane ranges reduces to keccak collision or near-collision resistance.

## Threat Model

### Builder selects which update lands

The block builder receives a continuous stream of priority updates for the upcoming block and may insert any one of them. The registry does not distinguish the newest update from an older update. Builder bugs, propagation issues, or transaction ordering can cause a different valid write to land or a later write to overwrite an earlier one.

### Targets validate freshness on reads

The registry accepts raw slot values without checking their age or order. Every target that relies on freshness must encode a timestamp, block number, or other marker and validate it on every read before using the remaining values. Missing, zero, future, and stale markers must be handled by the target's own policy.

### Authorized updaters control raw lane contents

An authorized updater can write any values to every updater-managed lane for its target. Removing an updater prevents future writes but does not clear previously written state.

### Decoders define their lane's security policy

Anyone can relay `updateStateWithDecoder`. The decoder must authenticate and validate the payload, call hash, and results. A decoder that accepts arbitrary input gives arbitrary callers control over its lane. Decoder addresses are permanent, but proxy decoders may remain upgradeable.

### Trusted targets execute user-selected calldata

Relayers choose calldata for trusted targets. The allowlist trusts all code reachable through those targets, including upgrades and downstream calls.

### Registry reads are target-scoped

`getSlot`, `getSlots`, and `getState` read lanes belonging to `msg.sender`. One contract cannot use these methods to read as another target. Registry storage remains public and can always be inspected offchain.

## Block Builder Integration

Block builders accept these transactions via a special endpoint. If another priority update arrives at the block builder, it replaces the previous one. Only one priority update for a target and lane should land in the block, and the builder verifies that it is the latest one received.

### Simulating priority updates inside the block builder

We suggest this approach to applying priority updates in the builder.

1. Keep a separate "mempool" of unlanded priority updates and maintain it with new updates as they arrive.
2. Prohibit priority updates from landing in the block except if the builder explicitly inserts them.
3. Before a user transaction is executed, insert the relevant priority update transaction in front of it.

## Example Integration

[`src/ExamplePropAmm.sol`](src/ExamplePropAmm.sol) is a minimal proprietary AMM that reads its per-pair pricing parameters from `PrioUpdateRegistryV2`. The market maker writes `[updateTimestamp, concentration, multX, multY]` as raw lane data. The registry does not interpret the timestamp; the AMM checks that it is not in the future and is no older than `maxParameterAge` whenever it reads the parameters. Adapted from [fahimahmedx/prop-amm](https://github.com/fahimahmedx/prop-amm), which uses a different top-of-block storage mechanism.

## Testing

```shell
just test
```

## Deployments

No PrioUpdateRegistry V2 deployments are listed yet.
