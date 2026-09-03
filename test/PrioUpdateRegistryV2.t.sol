// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrioUpdateRegistryV2, IPrioUpdateDecoder} from "../src/PrioUpdateRegistryV2.sol";

contract PrioUpdateRegistryV2Test is Test {
    event UpdaterAdded(address indexed target, address indexed updater);
    event UpdaterRemoved(address indexed target, address indexed updater);
    event DecoderSet(address indexed target, uint256 indexed laneIndex, address indexed decoder);

    PrioUpdateRegistryV2 internal registry;

    address internal target = makeAddr("target");
    address internal otherTarget = makeAddr("otherTarget");
    address internal updater = makeAddr("updater");
    address internal otherUpdater = makeAddr("otherUpdater");
    address internal relayer = makeAddr("relayer");

    uint256 internal constant MAX_SLOTS = 255;

    function setUp() public {
        registry = new PrioUpdateRegistryV2();
        _authorize(target, updater);
    }

    function _authorize(address target_, address updater_) internal {
        vm.prank(target_);
        registry.addUpdater(updater_);
    }

    function _setDecoder(address target_, uint256 laneIndex, address decoder) internal {
        vm.prank(target_);
        registry.setDecoder(laneIndex, decoder);
    }

    function _write(address target_, address updater_, uint256 laneIndex, uint256[] memory slots) internal {
        vm.prank(updater_);
        registry.updateState(target_, laneIndex, slots);
    }

    function _read(address target_, uint256 laneIndex, uint256 count) internal returns (uint256[] memory slots) {
        vm.prank(target_);
        return registry.getState(laneIndex, count);
    }

    function _readRange(address target_, uint256 laneIndex, uint256 slotIndex, uint256 slotCount)
        internal
        returns (uint256[] memory slots)
    {
        vm.prank(target_);
        return registry.getSlots(laneIndex, slotIndex, slotCount);
    }

    /*
     * Updaters
     */

    function test_addUpdater() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit UpdaterAdded(target, otherUpdater);
        vm.prank(target);
        registry.addUpdater(otherUpdater);

        assertTrue(registry.isUpdater(target, otherUpdater));
    }

    function test_addUpdater_emitsWhenAlreadyAuthorized() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit UpdaterAdded(target, updater);
        vm.prank(target);
        registry.addUpdater(updater);

        assertTrue(registry.isUpdater(target, updater));
    }

    function test_removeUpdater() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit UpdaterRemoved(target, updater);
        vm.prank(target);
        registry.removeUpdater(updater);

        assertFalse(registry.isUpdater(target, updater));
    }

    function test_removeUpdater_emitsWhenNotAuthorized() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit UpdaterRemoved(target, otherUpdater);
        vm.prank(target);
        registry.removeUpdater(otherUpdater);

        assertFalse(registry.isUpdater(target, otherUpdater));
    }

    function test_updaterAuthorizationIsTargetScoped() public view {
        assertTrue(registry.isUpdater(target, updater));
        assertFalse(registry.isUpdater(otherTarget, updater));
    }

    function test_removedUpdaterCannotWrite() public {
        vm.prank(target);
        registry.removeUpdater(updater);

        uint256[] memory slots = new uint256[](1);
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistryV2.NotAuthorized.selector);
        registry.updateState(target, 0, slots);
    }

    /*
     * Raw State
     */

    function test_writeAndReadSingleFullWidthSlot() public {
        uint256[] memory slots = new uint256[](1);
        slots[0] = type(uint256).max;
        _write(target, updater, 0, slots);

        uint256[] memory stored = _read(target, 0, 1);
        assertEq(stored, slots);

        vm.prank(target);
        assertEq(registry.getSlot(0, 0), type(uint256).max);
    }

    function test_writeAndReadMultipleSlots() public {
        uint256[] memory slots = new uint256[](3);
        slots[0] = 11;
        slots[1] = 22;
        slots[2] = 33;
        _write(target, updater, 7, slots);

        uint256[] memory stored = _read(target, 7, 3);
        assertEq(stored, slots);
    }

    function test_getSlotsReturnsRequestedRange() public {
        uint256[] memory slots = new uint256[](5);
        slots[0] = 11;
        slots[1] = 22;
        slots[2] = 33;
        slots[3] = 44;
        slots[4] = 55;
        _write(target, updater, 7, slots);

        uint256[] memory stored = _readRange(target, 7, 1, 3);
        assertEq(stored.length, 3);
        assertEq(stored[0], 22);
        assertEq(stored[1], 33);
        assertEq(stored[2], 44);
    }

    function test_unwrittenSlotsReturnZero() public {
        uint256[] memory stored = _read(target, 9, 3);
        assertEq(stored.length, 3);
        assertEq(stored[0], 0);
        assertEq(stored[1], 0);
        assertEq(stored[2], 0);

        vm.prank(target);
        assertEq(registry.getSlot(9, 42), 0);
    }

    function test_getStateAllowsZeroCount() public {
        uint256[] memory stored = _read(target, 0, 0);
        assertEq(stored.length, 0);
    }

    function test_getSlotsAllowsEmptyRangeAtLaneEnd() public {
        uint256[] memory stored = _readRange(target, 0, MAX_SLOTS, 0);
        assertEq(stored.length, 0);
    }

    function test_readsAreSelfScoped() public {
        _authorize(otherTarget, updater);

        uint256[] memory targetSlots = new uint256[](1);
        targetSlots[0] = 111;
        _write(target, updater, 0, targetSlots);

        uint256[] memory otherSlots = new uint256[](1);
        otherSlots[0] = 222;
        _write(otherTarget, updater, 0, otherSlots);

        assertEq(_read(target, 0, 1)[0], 111);
        assertEq(_read(otherTarget, 0, 1)[0], 222);
        assertEq(_readRange(target, 0, 0, 1)[0], 111);
        assertEq(_readRange(otherTarget, 0, 0, 1)[0], 222);
    }

    function test_lanesAreIndependent() public {
        uint256[] memory first = new uint256[](1);
        first[0] = 111;
        _write(target, updater, 1, first);

        uint256[] memory second = new uint256[](1);
        second[0] = 222;
        _write(target, updater, 2, second);

        assertEq(_read(target, 1, 1)[0], 111);
        assertEq(_read(target, 2, 1)[0], 222);
    }

    function test_shorterWritePreservesTrailingSlots() public {
        uint256[] memory first = new uint256[](3);
        first[0] = 1;
        first[1] = 2;
        first[2] = 3;
        _write(target, updater, 0, first);

        uint256[] memory second = new uint256[](1);
        second[0] = 9;
        _write(target, updater, 0, second);

        uint256[] memory stored = _read(target, 0, 3);
        assertEq(stored[0], 9);
        assertEq(stored[1], 2);
        assertEq(stored[2], 3);
    }

    function test_applicationValueCanMoveBackward() public {
        uint256[] memory first = new uint256[](1);
        first[0] = 1_000;
        _write(target, updater, 0, first);

        uint256[] memory second = new uint256[](1);
        second[0] = 1;
        _write(target, updater, 0, second);

        assertEq(_read(target, 0, 1)[0], 1);
    }

    function test_blockAndTimestampDoNotAffectState() public {
        uint256[] memory slots = new uint256[](2);
        slots[0] = block.timestamp;
        slots[1] = block.number;
        _write(target, updater, 0, slots);

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1_000_000);

        uint256[] memory stored = _read(target, 0, 2);
        assertEq(stored, slots);
    }

    function test_updateStateRevertsForUnauthorizedCaller() public {
        uint256[] memory slots = new uint256[](1);
        vm.prank(otherUpdater);
        vm.expectRevert(PrioUpdateRegistryV2.NotAuthorized.selector);
        registry.updateState(target, 0, slots);
    }

    function test_updateStateRevertsForEmptySlots() public {
        uint256[] memory slots = new uint256[](0);
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistryV2.EmptySlots.selector);
        registry.updateState(target, 0, slots);
    }

    function test_updateStateRevertsForTooManySlots() public {
        uint256[] memory slots = new uint256[](MAX_SLOTS + 1);
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistryV2.TooManySlots.selector);
        registry.updateState(target, 0, slots);
    }

    function test_maximumSlotCountRoundTrip() public {
        uint256[] memory slots = new uint256[](MAX_SLOTS);
        for (uint256 i; i < slots.length; ++i) {
            slots[i] = i + 1;
        }
        _write(target, updater, 0, slots);

        assertEq(_read(target, 0, MAX_SLOTS), slots);
        assertEq(_readRange(target, 0, 0, MAX_SLOTS), slots);
        assertEq(_readRange(target, 0, MAX_SLOTS - 1, 1)[0], MAX_SLOTS);
    }

    function test_getSlotRevertsAtMaximumSlotIndex() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.SlotIndexOutOfRange.selector);
        registry.getSlot(0, MAX_SLOTS);
    }

    function test_getStateRevertsAboveMaximumCount() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.SlotIndexOutOfRange.selector);
        registry.getState(0, MAX_SLOTS + 1);
    }

    function test_getSlotsRevertsWhenStartIsPastLaneEnd() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.SlotIndexOutOfRange.selector);
        registry.getSlots(0, MAX_SLOTS + 1, 0);
    }

    function test_getSlotsRevertsWhenRangeExceedsLaneEnd() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.SlotIndexOutOfRange.selector);
        registry.getSlots(0, MAX_SLOTS - 1, 2);
    }

    function test_getSlotsLargeIndexUsesCustomError() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.SlotIndexOutOfRange.selector);
        registry.getSlots(0, type(uint256).max, 1);
    }

    function testFuzz_rawWordsRoundTrip(uint256 laneIndex, uint256 first, uint256 second, uint256 third) public {
        uint256[] memory slots = new uint256[](3);
        slots[0] = first;
        slots[1] = second;
        slots[2] = third;
        _write(target, updater, laneIndex, slots);

        assertEq(_read(target, laneIndex, 3), slots);
    }

    function testFuzz_getSlotsReturnsRange(uint256 laneIndex, uint256 slotIndex, uint256 slotCount) public {
        uint256[] memory slots = new uint256[](8);
        for (uint256 i; i < slots.length; ++i) {
            slots[i] = i + 1;
        }
        _write(target, updater, laneIndex, slots);

        slotIndex = bound(slotIndex, 0, slots.length);
        slotCount = bound(slotCount, 0, slots.length - slotIndex);
        uint256[] memory stored = _readRange(target, laneIndex, slotIndex, slotCount);

        assertEq(stored.length, slotCount);
        for (uint256 i; i < slotCount; ++i) {
            assertEq(stored[i], slots[slotIndex + i]);
        }
    }

    /*
     * Decoders
     */

    function test_setDecoder() public {
        RawDecoder decoder = new RawDecoder();

        vm.expectEmit(true, true, true, true, address(registry));
        emit DecoderSet(target, 4, address(decoder));
        vm.prank(target);
        registry.setDecoder(4, address(decoder));

        assertEq(registry.laneDecoder(target, 4), address(decoder));
    }

    function test_setDecoderRevertsForZeroAddress() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.ZeroDecoder.selector);
        registry.setDecoder(0, address(0));
    }

    function test_setDecoderRevertsForAddressWithoutCode() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.DecoderHasNoCode.selector);
        registry.setDecoder(0, relayer);
    }

    function test_setDecoderCannotReplaceExistingDecoder() public {
        RawDecoder first = new RawDecoder();
        RawDecoder second = new RawDecoder();
        _setDecoder(target, 0, address(first));

        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistryV2.DecoderAlreadySet.selector);
        registry.setDecoder(0, address(second));
    }

    function test_decoderIsTargetAndLaneScoped() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 3, address(decoder));

        assertEq(registry.laneDecoder(target, 3), address(decoder));
        assertEq(registry.laneDecoder(target, 4), address(0));
        assertEq(registry.laneDecoder(otherTarget, 3), address(0));
    }

    function test_directWriteRevertsForDecoderManagedLane() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory slots = new uint256[](1);
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistryV2.DecoderBoundLane.selector);
        registry.updateState(target, 0, slots);
    }

    function test_decoderWriteRevertsForLaneWithoutDecoder() public {
        vm.prank(relayer);
        vm.expectRevert(PrioUpdateRegistryV2.DecoderNotSet.selector);
        registry.updateStateWithDecoder(target, 0, bytes(""));
    }

    function test_decoderWriteIsPermissionless() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory slots = new uint256[](2);
        slots[0] = type(uint256).max;
        slots[1] = 42;

        vm.prank(relayer);
        registry.updateStateWithDecoder(target, 0, abi.encode(slots));

        assertEq(_read(target, 0, 2), slots);
    }

    function test_decoderReceivesTargetAndLane() public {
        ArgumentDecoder decoder = new ArgumentDecoder();
        _setDecoder(target, 123, address(decoder));

        vm.prank(relayer);
        registry.updateStateWithDecoder(target, 123, bytes(""));

        uint256[] memory stored = _read(target, 123, 2);
        assertEq(stored[0], uint256(uint160(target)));
        assertEq(stored[1], 123);
    }

    function test_decoderWriteRevertsForEmptySlots() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory slots = new uint256[](0);
        vm.prank(relayer);
        vm.expectRevert(PrioUpdateRegistryV2.DecoderReturnedNoSlots.selector);
        registry.updateStateWithDecoder(target, 0, abi.encode(slots));
    }

    function test_decoderWriteRevertsForTooManySlots() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory slots = new uint256[](MAX_SLOTS + 1);
        vm.prank(relayer);
        vm.expectRevert(PrioUpdateRegistryV2.TooManySlots.selector);
        registry.updateStateWithDecoder(target, 0, abi.encode(slots));
    }

    function test_decoderRevertBubbles() public {
        RevertingDecoder decoder = new RevertingDecoder();
        _setDecoder(target, 0, address(decoder));

        vm.prank(relayer);
        vm.expectRevert(RevertingDecoder.Rejected.selector);
        registry.updateStateWithDecoder(target, 0, bytes(""));
    }

    function test_decoderRunsUnderStaticcall() public {
        StateWritingDecoder decoder = new StateWritingDecoder();
        _setDecoder(target, 0, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(registry).call{gas: 100_000}(
            abi.encodeCall(PrioUpdateRegistryV2.updateStateWithDecoder, (target, 0, bytes("")))
        );

        assertFalse(success);
        assertEq(decoder.value(), 0);
    }

    function test_shorterDecoderWritePreservesTrailingSlots() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory first = new uint256[](3);
        first[0] = 1;
        first[1] = 2;
        first[2] = 3;
        registry.updateStateWithDecoder(target, 0, abi.encode(first));

        uint256[] memory second = new uint256[](1);
        second[0] = 9;
        registry.updateStateWithDecoder(target, 0, abi.encode(second));

        uint256[] memory stored = _read(target, 0, 3);
        assertEq(stored[0], 9);
        assertEq(stored[1], 2);
        assertEq(stored[2], 3);
    }

    function test_decoderCallbacksToProtectedRegistryEntryPointsAreBlocked() public {
        CallbackProbingDecoder decoder = new CallbackProbingDecoder();
        _setDecoder(target, 0, address(decoder));

        registry.updateStateWithDecoder(target, 0, bytes(""));

        assertEq(_read(target, 0, 1)[0], decoder.PROBE_COUNT());
    }

    function test_decoderCanReadPublicMappingGetterDuringValidation() public {
        CallbackDecoder decoder = new CallbackDecoder(registry);
        _setDecoder(target, 0, address(decoder));

        registry.updateStateWithDecoder(target, 0, bytes(""));

        assertEq(_read(target, 0, 1)[0], 1);
    }

    /*
     * Storage Isolation
     */

    function test_craftedLaneCannotForgeUpdaterAuthorization() public {
        address victim = makeAddr("victim");
        address attacker = makeAddr("attacker");
        uint256 craftedLane = uint256(keccak256(abi.encode(victim, uint256(0))));

        _authorize(attacker, attacker);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;
        _write(attacker, attacker, craftedLane, slots);

        assertFalse(registry.isUpdater(victim, attacker));

        vm.prank(attacker);
        vm.expectRevert(PrioUpdateRegistryV2.NotAuthorized.selector);
        registry.updateState(victim, 0, slots);
    }
}

contract RawDecoder is IPrioUpdateDecoder {
    function validateAndUnpack(address, uint256, bytes calldata aux) external pure returns (uint256[] memory slots) {
        return abi.decode(aux, (uint256[]));
    }
}

contract ArgumentDecoder is IPrioUpdateDecoder {
    function validateAndUnpack(address target, uint256 laneIndex, bytes calldata)
        external
        pure
        returns (uint256[] memory slots)
    {
        slots = new uint256[](2);
        slots[0] = uint256(uint160(target));
        slots[1] = laneIndex;
    }
}

contract RevertingDecoder is IPrioUpdateDecoder {
    error Rejected();

    function validateAndUnpack(address, uint256, bytes calldata) external pure returns (uint256[] memory) {
        revert Rejected();
    }
}

contract StateWritingDecoder {
    uint256 public value;

    function validateAndUnpack(address, uint256, bytes calldata) external returns (uint256[] memory slots) {
        value = 1;
        slots = new uint256[](1);
        slots[0] = 1;
    }
}

contract CallbackDecoder is IPrioUpdateDecoder {
    PrioUpdateRegistryV2 private immutable registry;

    constructor(PrioUpdateRegistryV2 registry_) {
        registry = registry_;
    }

    function validateAndUnpack(address, uint256, bytes calldata) external view returns (uint256[] memory slots) {
        registry.isUpdater(address(this), address(this));
        slots = new uint256[](1);
        slots[0] = 1;
    }
}

contract CallbackProbingDecoder is IPrioUpdateDecoder {
    error CallbackSucceeded();
    error UnexpectedCallbackError();

    uint256 public constant PROBE_COUNT = 8;

    /// @dev Every protected entry point must reject a reentrant call from inside validation.
    function validateAndUnpack(address target, uint256, bytes calldata) external view returns (uint256[] memory slots) {
        uint256[] memory emptySlots = new uint256[](0);
        bytes[] memory probes = new bytes[](PROBE_COUNT);
        probes[0] = abi.encodeCall(PrioUpdateRegistryV2.getSlot, (0, 0));
        probes[1] = abi.encodeCall(PrioUpdateRegistryV2.getState, (0, 0));
        probes[2] = abi.encodeCall(PrioUpdateRegistryV2.getSlots, (0, 0, 0));
        probes[3] = abi.encodeCall(PrioUpdateRegistryV2.addUpdater, (address(this)));
        probes[4] = abi.encodeCall(PrioUpdateRegistryV2.removeUpdater, (address(this)));
        probes[5] = abi.encodeCall(PrioUpdateRegistryV2.setDecoder, (1, address(this)));
        probes[6] = abi.encodeCall(PrioUpdateRegistryV2.updateState, (target, 0, emptySlots));
        probes[7] = abi.encodeCall(PrioUpdateRegistryV2.updateStateWithDecoder, (target, 0, bytes("")));

        for (uint256 i; i < probes.length; ++i) {
            (bool success, bytes memory result) = msg.sender.staticcall(probes[i]);
            if (success) revert CallbackSucceeded();
            if (result.length < 4) revert UnexpectedCallbackError();
            bytes4 selector;
            assembly {
                selector := mload(add(result, 0x20))
            }
            if (selector != PrioUpdateRegistryV2.CallbackNotAllowed.selector) revert UnexpectedCallbackError();
        }

        slots = new uint256[](1);
        slots[0] = probes.length;
    }
}
