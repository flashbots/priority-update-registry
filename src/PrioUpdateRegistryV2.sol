// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Interface for a lane decoder that validates an opaque payload and returns the slot values to store.
/// @dev The registry calls decoders with `STATICCALL`, so a decoder cannot modify state, emit events,
/// transfer value, create contracts, or self-destruct. A decoder should bind its payload to `target`
/// and `laneIndex` when those values are part of its authorization scheme.
interface IPrioUpdateDecoder {
    /// @notice Validates `aux` for `target` and `laneIndex` and returns the slot values to store.
    /// @dev Revert to reject the update. The returned array must have between 1 and 255 entries.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param aux The opaque payload interpreted by the decoder.
    /// @param trustedCallsHash `keccak256(abi.encode(calls))`.
    /// @param callResults Ordered call return data.
    /// @return slots The validated slot values to store.
    function validateAndUnpack(
        address target,
        uint256 laneIndex,
        bytes calldata aux,
        bytes32 trustedCallsHash,
        bytes[] calldata callResults
    ) external view returns (uint256[] memory slots);
}

/// @notice Stores raw per-target state written by authorized updaters or target-selected decoders.
/// @dev The registry does not interpret, generate, store, or validate freshness metadata. A target that
/// requires a timestamp, block number, sequence number, or other validity marker must include it in its
/// own slot layout and validate it when reading. Writes only replace the supplied slot prefix and are
/// not required to be monotonic.
contract PrioUpdateRegistryV2 {
    struct TrustedCall {
        address target;
        bytes data;
    }

    event UpdaterAdded(address indexed target, address indexed updater);
    event UpdaterRemoved(address indexed target, address indexed updater);
    event DecoderSet(address indexed target, uint256 indexed laneIndex, address indexed decoder);

    /// @notice Thrown when `msg.sender` is not authorized to update state on behalf of `target`.
    error NotAuthorized();
    /// @notice Thrown when `slots` has length zero.
    error EmptySlots();
    /// @notice Thrown when `slots` has more than 255 entries.
    error TooManySlots();
    /// @notice Thrown when a read requests a slot outside the 255-slot lane region.
    error SlotIndexOutOfRange();
    /// @notice Thrown when a decoder returns an empty slot array.
    error DecoderReturnedNoSlots();
    /// @notice Thrown when a decoder has already been set for the lane.
    error DecoderAlreadySet();
    /// @notice Thrown when a decoder update is requested for a lane without a decoder.
    error DecoderNotSet();
    /// @notice Thrown when the updater path is used for a lane that has a decoder.
    error DecoderBoundLane();
    /// @notice Thrown when `decoder` is the zero address.
    error ZeroDecoder();
    /// @notice Thrown when `decoder` has no code at registration time.
    error DecoderHasNoCode();
    error TrustedCallTargetHasNoCode(address target);
    error UntrustedCallTarget(address target);
    error CallbackNotAllowed();

    /// @notice Maximum number of raw storage words in a lane.
    /// @dev The bound prevents reads or writes from escaping the lane's reserved storage region.
    uint256 internal constant MAX_SLOTS = 255;

    /// @dev Domain-separates lane storage from Solidity mapping storage and other hashed storage regions.
    bytes32 private constant LANE_NAMESPACE = keccak256("PrioUpdateRegistryV2.lane.v1");

    bytes32 private constant CALLBACK_LOCK_SLOT = keccak256("PrioUpdateRegistryV2.callbackLock");

    address private immutable _trustedCallTarget0;
    address private immutable _trustedCallTarget1;

    /// @notice Tracks whether `updater` is authorized to write state on behalf of `target`.
    /// @dev Each target manages its own set of updaters via `addUpdater` and `removeUpdater`.
    mapping(address target => mapping(address updater => bool)) public isUpdater;

    /// @notice Returns the decoder permanently assigned to `target` and `laneIndex`, or zero if none is set.
    /// @dev A non-zero decoder marks the lane as decoder-managed and disables direct updater writes.
    mapping(address target => mapping(uint256 laneIndex => address decoder)) public laneDecoder;

    modifier noCallback() {
        if (_callbackLocked()) revert CallbackNotAllowed();
        _;
    }

    modifier withCallbackLock() {
        if (_callbackLocked()) revert CallbackNotAllowed();
        _setCallbackLock(true);
        _;
        _setCallbackLock(false);
    }

    /// @param trustedCallTarget0 First trusted call target, or zero if unused.
    /// @param trustedCallTarget1 Second trusted call target, or zero if unused.
    constructor(address trustedCallTarget0, address trustedCallTarget1) {
        if (trustedCallTarget0 != address(0) && trustedCallTarget0.code.length == 0) {
            revert TrustedCallTargetHasNoCode(trustedCallTarget0);
        }
        if (trustedCallTarget1 != address(0) && trustedCallTarget1.code.length == 0) {
            revert TrustedCallTargetHasNoCode(trustedCallTarget1);
        }
        _trustedCallTarget0 = trustedCallTarget0;
        _trustedCallTarget1 = trustedCallTarget1;
    }

    /// @notice Returns whether `target` is one of this deployment's trusted call targets.
    function isTrustedCallTarget(address target) external view returns (bool) {
        return _isTrustedCallTarget(target);
    }

    /// @notice Authorizes `updater` to write state on behalf of `msg.sender`.
    /// @dev The stored authorization is idempotent. The event is emitted even if `updater` is already authorized.
    /// @param updater The address being granted write authorization.
    function addUpdater(address updater) external noCallback {
        isUpdater[msg.sender][updater] = true;
        emit UpdaterAdded(msg.sender, updater);
    }

    /// @notice Revokes authorization for `updater` to write state on behalf of `msg.sender`.
    /// @dev The stored authorization is idempotent. The event is emitted even if `updater` is not authorized.
    /// @param updater The address whose write authorization is being revoked.
    function removeUpdater(address updater) external noCallback {
        isUpdater[msg.sender][updater] = false;
        emit UpdaterRemoved(msg.sender, updater);
    }

    /// @notice Permanently assigns `decoder` to `msg.sender` at `laneIndex`.
    /// @dev Once set, the decoder cannot be removed or replaced and direct updater writes to the lane are disabled.
    /// The code-length check only applies at registration time. A proxy decoder may still change behavior.
    /// @param laneIndex The lane to assign the decoder to, scoped to `msg.sender`.
    /// @param decoder The contract that validates and unpacks updates for the lane.
    function setDecoder(uint256 laneIndex, address decoder) external noCallback {
        if (decoder == address(0)) revert ZeroDecoder();
        if (decoder.code.length == 0) revert DecoderHasNoCode();
        if (laneDecoder[msg.sender][laneIndex] != address(0)) revert DecoderAlreadySet();
        laneDecoder[msg.sender][laneIndex] = decoder;
        emit DecoderSet(msg.sender, laneIndex, decoder);
    }

    /*
     * State
     */

    /// @notice Writes raw slot values for `target` at `laneIndex`.
    /// @dev `msg.sender` must be an authorized updater for `target`, and the lane must not have a decoder.
    /// The registry performs no freshness, ordering, or application-level validation. Each supplied word
    /// is stored verbatim. A shorter write does not clear words left by an earlier longer write.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param slots The raw slot values to write. Length must be in `[1, 255]`.
    function updateState(address target, uint256 laneIndex, uint256[] calldata slots) external noCallback {
        if (!isUpdater[target][msg.sender]) revert NotAuthorized();
        if (laneDecoder[target][laneIndex] != address(0)) revert DecoderBoundLane();
        _writeSlotsCalldata(target, laneIndex, slots);
    }

    /// @notice Calls trusted targets, validates their results with the lane's decoder, and stores its slots.
    /// @dev Anyone may relay an update. The decoder is responsible for authorization and all
    /// application-level validation. Calls and validation are atomic. A shorter decoded update does not
    /// clear words left by an earlier longer update.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The decoder-managed lane to write, scoped to `target`.
    /// @param aux The opaque payload passed to the lane's decoder.
    /// @param calls Ordered zero-value calls.
    function updateStateWithDecoder(address target, uint256 laneIndex, bytes calldata aux, TrustedCall[] calldata calls)
        external
        withCallbackLock
    {
        address decoder = laneDecoder[target][laneIndex];
        if (decoder == address(0)) revert DecoderNotSet();

        uint256 callCount = calls.length;
        for (uint256 i; i < callCount; ++i) {
            if (!_isTrustedCallTarget(calls[i].target)) revert UntrustedCallTarget(calls[i].target);
        }

        bytes32 trustedCallsHash = keccak256(abi.encode(calls));
        bytes[] memory callResults = new bytes[](callCount);
        for (uint256 i; i < callCount; ++i) {
            // slither-disable-next-line calls-loop,low-level-calls
            (bool success, bytes memory result) = calls[i].target.call(calls[i].data);
            if (!success) {
                // slither-disable-next-line assembly
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            callResults[i] = result;
        }

        uint256[] memory slots =
            IPrioUpdateDecoder(decoder).validateAndUnpack(target, laneIndex, aux, trustedCallsHash, callResults);
        _writeSlotsMemory(target, laneIndex, slots);
    }

    /// @notice Returns one raw slot from `msg.sender`'s lane, or zero if it has never been written.
    /// @dev Reads are scoped to `msg.sender`; a caller cannot use this function to read another target's lane.
    /// No freshness or application-level validation is performed.
    /// @param laneIndex The lane to read, scoped to `msg.sender`.
    /// @param slotIndex The zero-based slot index. Must be less than 255.
    /// @return value The raw stored value.
    // Assembly is used to read the lane's computed storage slot directly.
    // slither-disable-next-line assembly
    function getSlot(uint256 laneIndex, uint256 slotIndex) external view noCallback returns (uint256 value) {
        if (slotIndex >= MAX_SLOTS) revert SlotIndexOutOfRange();
        uint256 slot = _laneBase(msg.sender, laneIndex) + slotIndex;
        assembly {
            value := sload(slot)
        }
    }

    /// @notice Returns a contiguous range of raw slots from `msg.sender`'s lane.
    /// @dev Reads are scoped to `msg.sender`. The returned range is
    /// `[slotIndex, slotIndex + slotCount)`. Unwritten words return zero, and words left by a
    /// shorter overwrite remain visible. No freshness or application-level validation is performed.
    /// @param laneIndex The lane to read, scoped to `msg.sender`.
    /// @param slotIndex The zero-based index of the first slot to return.
    /// @param slotCount The number of slots to return. The requested range must fit within 255 slots.
    /// @return slots The requested raw stored slot values.
    function getSlots(uint256 laneIndex, uint256 slotIndex, uint256 slotCount)
        external
        view
        noCallback
        returns (uint256[] memory slots)
    {
        return _readSlots(msg.sender, laneIndex, slotIndex, slotCount);
    }

    /// @notice Returns the first `count` raw slots from `msg.sender`'s lane.
    /// @dev Reads are scoped to `msg.sender`. The registry does not store a lane length, so the caller
    /// supplies `count`. Unwritten words return zero, and words left by a shorter overwrite remain visible.
    /// No freshness or application-level validation is performed.
    /// @param laneIndex The lane to read, scoped to `msg.sender`.
    /// @param count The number of slots to return. Must not exceed 255.
    /// @return slots The raw stored slot values.
    function getState(uint256 laneIndex, uint256 count) external view noCallback returns (uint256[] memory slots) {
        return _readSlots(msg.sender, laneIndex, 0, count);
    }

    /// @notice Returns the base storage slot for `target` and `laneIndex`.
    /// @dev Slot `i` of the lane is stored at `_laneBase(target, laneIndex) + i` for `0 <= i < 255`.
    function _laneBase(address target, uint256 laneIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(LANE_NAMESPACE, target, laneIndex)));
    }

    /// @notice Reads a contiguous range of raw slots for `target` at `laneIndex`.
    /// @dev The range check uses subtraction to avoid overflowing `slotIndex + slotCount`.
    // Assembly is used to read each computed storage slot directly.
    // slither-disable-next-line assembly
    function _readSlots(address target, uint256 laneIndex, uint256 slotIndex, uint256 slotCount)
        internal
        view
        returns (uint256[] memory slots)
    {
        if (slotIndex > MAX_SLOTS || slotCount > MAX_SLOTS - slotIndex) revert SlotIndexOutOfRange();

        slots = new uint256[](slotCount);
        if (slotCount == 0) return slots;

        uint256 base = _laneBase(target, laneIndex) + slotIndex;
        for (uint256 i; i < slotCount; ++i) {
            uint256 slot = base + i;
            uint256 value;
            assembly {
                value := sload(slot)
            }
            slots[i] = value;
        }
    }

    function _isTrustedCallTarget(address target) internal view returns (bool) {
        return target != address(0) && (target == _trustedCallTarget0 || target == _trustedCallTarget1);
    }

    // Assembly is required because Solidity does not expose transient storage directly.
    // slither-disable-next-line assembly
    function _callbackLocked() internal view returns (bool locked) {
        bytes32 slot = CALLBACK_LOCK_SLOT;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
    }

    // Assembly is required because Solidity does not expose transient storage directly.
    // slither-disable-next-line assembly
    function _setCallbackLock(bool locked) internal {
        bytes32 slot = CALLBACK_LOCK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, locked)
        }
    }

    /// @notice Writes calldata slot values verbatim for `target` at `laneIndex`.
    /// @dev Does not perform authorization or application-level validation. The caller must enforce
    /// the appropriate write path before invoking this function.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param slots The raw slot values to write. Length must be in `[1, 255]`.
    // Assembly is used to store words directly from calldata without copying the array to memory.
    // slither-disable-next-line assembly
    function _writeSlotsCalldata(address target, uint256 laneIndex, uint256[] calldata slots) internal {
        uint256 count = slots.length;
        if (count == 0) revert EmptySlots();
        if (count > MAX_SLOTS) revert TooManySlots();
        uint256 base = _laneBase(target, laneIndex);
        assembly {
            let offset := slots.offset
            for { let i := 0 } lt(i, count) { i := add(i, 1) } {
                sstore(add(base, i), calldataload(add(offset, mul(i, 0x20))))
            }
        }
    }

    /// @notice Writes decoder-returned slot values verbatim for `target` at `laneIndex`.
    /// @dev Does not perform decoder selection or application-level validation. The caller must invoke
    /// the registered decoder before calling this function.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param slots The decoder-returned slot values. Length must be in `[1, 255]`.
    // Assembly is used to store each memory word at its computed lane slot.
    // slither-disable-next-line assembly
    function _writeSlotsMemory(address target, uint256 laneIndex, uint256[] memory slots) internal {
        uint256 count = slots.length;
        if (count == 0) revert DecoderReturnedNoSlots();
        if (count > MAX_SLOTS) revert TooManySlots();
        uint256 base = _laneBase(target, laneIndex);
        for (uint256 i; i < count; ++i) {
            uint256 value = slots[i];
            uint256 slot = base + i;
            assembly {
                sstore(slot, value)
            }
        }
    }
}
