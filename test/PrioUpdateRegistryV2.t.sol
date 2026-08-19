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
        registry = new PrioUpdateRegistryV2(address(0), address(0));
        _authorize(target, updater);
    }

    function _noCalls() internal pure returns (PrioUpdateRegistryV2.TrustedCall[] memory calls) {
        return new PrioUpdateRegistryV2.TrustedCall[](0);
    }

    function _trustedCall(address callTarget, bytes memory data)
        internal
        pure
        returns (PrioUpdateRegistryV2.TrustedCall memory)
    {
        return PrioUpdateRegistryV2.TrustedCall({target: callTarget, data: data});
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

    function testFuzz_rawWordsRoundTrip(uint256 laneIndex, uint256 first, uint256 second, uint256 third) public {
        uint256[] memory slots = new uint256[](3);
        slots[0] = first;
        slots[1] = second;
        slots[2] = third;
        _write(target, updater, laneIndex, slots);

        assertEq(_read(target, laneIndex, 3), slots);
    }

    /*
     * Trusted Call Configuration
     */

    function test_trustedCallTargetMembershipSupportsZeroOneOrTwoTargets() public {
        TrustedCallTarget first = new TrustedCallTarget();
        TrustedCallTarget second = new TrustedCallTarget();

        PrioUpdateRegistryV2 none = new PrioUpdateRegistryV2(address(0), address(0));
        assertFalse(none.isTrustedCallTarget(address(0)));
        assertFalse(none.isTrustedCallTarget(address(first)));

        PrioUpdateRegistryV2 one = new PrioUpdateRegistryV2(address(first), address(0));
        assertTrue(one.isTrustedCallTarget(address(first)));
        assertFalse(one.isTrustedCallTarget(address(second)));
        assertFalse(one.isTrustedCallTarget(address(0)));

        PrioUpdateRegistryV2 two = new PrioUpdateRegistryV2(address(first), address(second));
        assertTrue(two.isTrustedCallTarget(address(first)));
        assertTrue(two.isTrustedCallTarget(address(second)));
    }

    function test_duplicateTrustedCallTargetsAreAllowed() public {
        TrustedCallTarget callTarget = new TrustedCallTarget();
        PrioUpdateRegistryV2 duplicate = new PrioUpdateRegistryV2(address(callTarget), address(callTarget));

        assertTrue(duplicate.isTrustedCallTarget(address(callTarget)));
    }

    function test_constructorRevertsForFirstTargetWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(PrioUpdateRegistryV2.TrustedCallTargetHasNoCode.selector, relayer));
        new PrioUpdateRegistryV2(relayer, address(0));
    }

    function test_constructorRevertsForSecondTargetWithoutCode() public {
        TrustedCallTarget first = new TrustedCallTarget();

        vm.expectRevert(abi.encodeWithSelector(PrioUpdateRegistryV2.TrustedCallTargetHasNoCode.selector, relayer));
        new PrioUpdateRegistryV2(address(first), relayer);
    }

    function test_trustedTargetAddressesHaveNoIndividualGetters() public {
        TrustedCallTarget callTarget = new TrustedCallTarget();
        PrioUpdateRegistryV2 configured = new PrioUpdateRegistryV2(address(callTarget), address(0));

        (bool firstSuccess,) = address(configured).staticcall(abi.encodeWithSignature("trustedCallTarget0()"));
        (bool secondSuccess,) = address(configured).staticcall(abi.encodeWithSignature("trustedCallTarget1()"));

        assertFalse(firstSuccess);
        assertFalse(secondSuccess);
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
        registry.updateStateWithDecoder(target, 0, bytes(""), _noCalls());
    }

    function test_decoderWriteIsPermissionless() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory slots = new uint256[](2);
        slots[0] = type(uint256).max;
        slots[1] = 42;

        vm.prank(relayer);
        registry.updateStateWithDecoder(target, 0, abi.encode(slots), _noCalls());

        assertEq(_read(target, 0, 2), slots);
    }

    function test_decoderReceivesTargetAndLane() public {
        ArgumentDecoder decoder = new ArgumentDecoder();
        _setDecoder(target, 123, address(decoder));

        vm.prank(relayer);
        registry.updateStateWithDecoder(target, 123, bytes(""), _noCalls());

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
        registry.updateStateWithDecoder(target, 0, abi.encode(slots), _noCalls());
    }

    function test_decoderWriteRevertsForTooManySlots() public {
        RawDecoder decoder = new RawDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory slots = new uint256[](MAX_SLOTS + 1);
        vm.prank(relayer);
        vm.expectRevert(PrioUpdateRegistryV2.TooManySlots.selector);
        registry.updateStateWithDecoder(target, 0, abi.encode(slots), _noCalls());
    }

    function test_decoderRevertBubbles() public {
        RevertingDecoder decoder = new RevertingDecoder();
        _setDecoder(target, 0, address(decoder));

        vm.prank(relayer);
        vm.expectRevert(RevertingDecoder.Rejected.selector);
        registry.updateStateWithDecoder(target, 0, bytes(""), _noCalls());
    }

    function test_decoderRunsUnderStaticcall() public {
        StateWritingDecoder decoder = new StateWritingDecoder();
        _setDecoder(target, 0, address(decoder));

        vm.prank(relayer);
        (bool success,) = address(registry).call{gas: 100_000}(
            abi.encodeCall(PrioUpdateRegistryV2.updateStateWithDecoder, (target, 0, bytes(""), _noCalls()))
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
        registry.updateStateWithDecoder(target, 0, abi.encode(first), _noCalls());

        uint256[] memory second = new uint256[](1);
        second[0] = 9;
        registry.updateStateWithDecoder(target, 0, abi.encode(second), _noCalls());

        uint256[] memory stored = _read(target, 0, 3);
        assertEq(stored[0], 9);
        assertEq(stored[1], 2);
        assertEq(stored[2], 3);
    }

    /*
     * Trusted Calls
     */

    function test_trustedCallsExecuteInOrderAndResultsReachDecoder() public {
        TrustedCallTarget callTarget = new TrustedCallTarget();
        registry = new PrioUpdateRegistryV2(address(callTarget), address(0));
        ResultsDecoder decoder = new ResultsDecoder();
        _setDecoder(target, 7, address(decoder));

        PrioUpdateRegistryV2.TrustedCall[] memory calls = new PrioUpdateRegistryV2.TrustedCall[](2);
        calls[0] = _trustedCall(address(callTarget), abi.encodeCall(TrustedCallTarget.setAndReturn, (0, 11)));
        calls[1] = _trustedCall(address(callTarget), abi.encodeCall(TrustedCallTarget.setAndReturn, (11, 22)));

        vm.prank(relayer);
        registry.updateStateWithDecoder(target, 7, bytes(""), calls);

        assertEq(callTarget.value(), 22);
        assertEq(callTarget.lastCaller(), address(registry));
        uint256[] memory stored = _read(target, 7, 4);
        assertEq(stored[0], 11);
        assertEq(stored[1], uint256(uint160(address(registry))));
        assertEq(stored[2], 22);
        assertEq(stored[3], uint256(uint160(address(registry))));
    }

    function test_auxCommitmentBindsExactTrustedCallsEvenWhenResultsMatch() public {
        TrustedCallTarget callTarget = new TrustedCallTarget();
        registry = new PrioUpdateRegistryV2(address(callTarget), address(0));
        CallCommitmentDecoder decoder = new CallCommitmentDecoder();
        _setDecoder(target, 0, address(decoder));

        PrioUpdateRegistryV2.TrustedCall[] memory authorizedCalls = new PrioUpdateRegistryV2.TrustedCall[](1);
        authorizedCalls[0] =
            _trustedCall(address(callTarget), abi.encodeCall(TrustedCallTarget.setValueAndReturn, (11, 42)));
        bytes memory aux = abi.encode(keccak256(abi.encode(authorizedCalls)));

        registry.updateStateWithDecoder(target, 0, aux, authorizedCalls);

        assertEq(callTarget.value(), 11);
        assertEq(_read(target, 0, 1)[0], 42);

        PrioUpdateRegistryV2.TrustedCall[] memory alteredCalls = new PrioUpdateRegistryV2.TrustedCall[](1);
        alteredCalls[0] =
            _trustedCall(address(callTarget), abi.encodeCall(TrustedCallTarget.setValueAndReturn, (22, 42)));

        vm.expectRevert(CallCommitmentDecoder.TrustedCallsHashMismatch.selector);
        registry.updateStateWithDecoder(target, 0, aux, alteredCalls);

        assertEq(callTarget.value(), 11);
        assertEq(_read(target, 0, 1)[0], 42);
    }

    function test_emptyTrustedCallsForwardEmptyResults() public {
        EmptyResultsDecoder decoder = new EmptyResultsDecoder();
        _setDecoder(target, 0, address(decoder));

        registry.updateStateWithDecoder(target, 0, bytes(""), _noCalls());

        assertEq(_read(target, 0, 1)[0], 1);
    }

    function test_untrustedTargetRevertsBeforeAnyCallExecutes() public {
        TrustedCallTarget allowed = new TrustedCallTarget();
        TrustedCallTarget untrusted = new TrustedCallTarget();
        registry = new PrioUpdateRegistryV2(address(allowed), address(0));
        ResultsDecoder decoder = new ResultsDecoder();
        _setDecoder(target, 0, address(decoder));

        PrioUpdateRegistryV2.TrustedCall[] memory calls = new PrioUpdateRegistryV2.TrustedCall[](2);
        calls[0] = _trustedCall(address(allowed), abi.encodeCall(TrustedCallTarget.setAndReturn, (0, 11)));
        calls[1] = _trustedCall(address(untrusted), abi.encodeCall(TrustedCallTarget.setAndReturn, (0, 22)));

        vm.expectRevert(abi.encodeWithSelector(PrioUpdateRegistryV2.UntrustedCallTarget.selector, address(untrusted)));
        registry.updateStateWithDecoder(target, 0, bytes(""), calls);

        assertEq(allowed.value(), 0);
        assertEq(untrusted.value(), 0);
    }

    function test_trustedCallRevertBubblesAndRollsBackEarlierCalls() public {
        TrustedCallTarget callTarget = new TrustedCallTarget();
        registry = new PrioUpdateRegistryV2(address(callTarget), address(0));
        ResultsDecoder decoder = new ResultsDecoder();
        _setDecoder(target, 0, address(decoder));

        PrioUpdateRegistryV2.TrustedCall[] memory calls = new PrioUpdateRegistryV2.TrustedCall[](2);
        calls[0] = _trustedCall(address(callTarget), abi.encodeCall(TrustedCallTarget.setAndReturn, (0, 11)));
        calls[1] = _trustedCall(address(callTarget), abi.encodeCall(TrustedCallTarget.reject, (42)));

        vm.expectRevert(abi.encodeWithSelector(TrustedCallTarget.Rejected.selector, 42));
        registry.updateStateWithDecoder(target, 0, bytes(""), calls);

        assertEq(callTarget.value(), 0);
        assertEq(_read(target, 0, 1)[0], 0);
    }

    function test_decoderRevertRollsBackTrustedCalls() public {
        TrustedCallTarget callTarget = new TrustedCallTarget();
        registry = new PrioUpdateRegistryV2(address(callTarget), address(0));
        RevertingDecoder decoder = new RevertingDecoder();
        _setDecoder(target, 0, address(decoder));

        PrioUpdateRegistryV2.TrustedCall[] memory calls = new PrioUpdateRegistryV2.TrustedCall[](1);
        calls[0] = _trustedCall(address(callTarget), abi.encodeCall(TrustedCallTarget.setAndReturn, (0, 11)));

        vm.expectRevert(RevertingDecoder.Rejected.selector);
        registry.updateStateWithDecoder(target, 0, bytes(""), calls);

        assertEq(callTarget.value(), 0);
        assertEq(_read(target, 0, 1)[0], 0);
    }

    function test_trustedTargetCallbacksToProtectedRegistryEntryPointsAreBlocked() public {
        CallbackTarget callbackTarget = new CallbackTarget();
        registry = new PrioUpdateRegistryV2(address(callbackTarget), address(0));
        CallbackResultsDecoder decoder = new CallbackResultsDecoder();
        _setDecoder(target, 0, address(decoder));

        uint256[] memory emptySlots = new uint256[](0);
        bytes[] memory callbackData = new bytes[](7);
        callbackData[0] = abi.encodeCall(PrioUpdateRegistryV2.addUpdater, (updater));
        callbackData[1] = abi.encodeCall(PrioUpdateRegistryV2.removeUpdater, (updater));
        callbackData[2] = abi.encodeCall(PrioUpdateRegistryV2.setDecoder, (1, address(decoder)));
        callbackData[3] = abi.encodeCall(PrioUpdateRegistryV2.updateState, (target, 0, emptySlots));
        callbackData[4] =
            abi.encodeCall(PrioUpdateRegistryV2.updateStateWithDecoder, (target, 0, bytes(""), _noCalls()));
        callbackData[5] = abi.encodeCall(PrioUpdateRegistryV2.getSlot, (0, 0));
        callbackData[6] = abi.encodeCall(PrioUpdateRegistryV2.getState, (0, 0));

        PrioUpdateRegistryV2.TrustedCall[] memory calls = new PrioUpdateRegistryV2.TrustedCall[](callbackData.length);
        for (uint256 i; i < calls.length; ++i) {
            calls[i] = _trustedCall(
                address(callbackTarget),
                abi.encodeCall(CallbackTarget.attemptCallback, (address(registry), callbackData[i]))
            );
        }

        registry.updateStateWithDecoder(target, 0, bytes(""), calls);

        assertEq(_read(target, 0, 1)[0], callbackData.length);
    }

    function test_decoderCanReadPublicMappingGetterDuringValidation() public {
        CallbackDecoder decoder = new CallbackDecoder(registry);
        _setDecoder(target, 0, address(decoder));

        registry.updateStateWithDecoder(target, 0, bytes(""), _noCalls());

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
    function validateAndUnpack(address, uint256, bytes calldata aux, bytes32, bytes[] calldata)
        external
        pure
        returns (uint256[] memory slots)
    {
        return abi.decode(aux, (uint256[]));
    }
}

contract ArgumentDecoder is IPrioUpdateDecoder {
    function validateAndUnpack(address target, uint256 laneIndex, bytes calldata, bytes32, bytes[] calldata)
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

    function validateAndUnpack(address, uint256, bytes calldata, bytes32, bytes[] calldata)
        external
        pure
        returns (uint256[] memory)
    {
        revert Rejected();
    }
}

contract StateWritingDecoder {
    uint256 public value;

    function validateAndUnpack(address, uint256, bytes calldata, bytes32, bytes[] calldata)
        external
        returns (uint256[] memory slots)
    {
        value = 1;
        slots = new uint256[](1);
        slots[0] = 1;
    }
}

contract TrustedCallTarget {
    error UnexpectedValue();
    error Rejected(uint256 reason);

    uint256 public value;
    address public lastCaller;

    function setAndReturn(uint256 expectedValue, uint256 newValue)
        external
        returns (uint256 returnedValue, address caller)
    {
        if (value != expectedValue) revert UnexpectedValue();
        value = newValue;
        lastCaller = msg.sender;
        return (newValue, msg.sender);
    }

    function setValueAndReturn(uint256 newValue, uint256 returnedValue) external returns (uint256) {
        value = newValue;
        lastCaller = msg.sender;
        return returnedValue;
    }

    function reject(uint256 reason) external pure {
        revert Rejected(reason);
    }
}

contract ResultsDecoder is IPrioUpdateDecoder {
    function validateAndUnpack(address, uint256, bytes calldata, bytes32, bytes[] calldata callResults)
        external
        pure
        returns (uint256[] memory slots)
    {
        slots = new uint256[](callResults.length * 2);
        for (uint256 i; i < callResults.length; ++i) {
            (uint256 value, address caller) = abi.decode(callResults[i], (uint256, address));
            slots[i * 2] = value;
            slots[i * 2 + 1] = uint256(uint160(caller));
        }
    }
}

contract CallCommitmentDecoder is IPrioUpdateDecoder {
    error TrustedCallsHashMismatch();
    error UnexpectedResults();

    function validateAndUnpack(
        address,
        uint256,
        bytes calldata aux,
        bytes32 trustedCallsHash,
        bytes[] calldata callResults
    ) external pure returns (uint256[] memory slots) {
        if (abi.decode(aux, (bytes32)) != trustedCallsHash) revert TrustedCallsHashMismatch();
        if (callResults.length != 1) revert UnexpectedResults();

        slots = new uint256[](1);
        slots[0] = abi.decode(callResults[0], (uint256));
    }
}

contract EmptyResultsDecoder is IPrioUpdateDecoder {
    error UnexpectedResults();

    function validateAndUnpack(address, uint256, bytes calldata, bytes32, bytes[] calldata callResults)
        external
        pure
        returns (uint256[] memory slots)
    {
        if (callResults.length != 0) revert UnexpectedResults();
        slots = new uint256[](1);
        slots[0] = 1;
    }
}

contract CallbackTarget {
    error CallbackSucceeded();
    error UnexpectedCallbackError();

    function attemptCallback(address registry, bytes calldata data) external returns (bytes4 selector) {
        (bool success, bytes memory result) = registry.call(data);
        if (success) revert CallbackSucceeded();
        if (result.length < 4) revert UnexpectedCallbackError();
        assembly {
            selector := mload(add(result, 0x20))
        }
        if (selector != PrioUpdateRegistryV2.CallbackNotAllowed.selector) revert UnexpectedCallbackError();
    }
}

contract CallbackResultsDecoder is IPrioUpdateDecoder {
    error UnexpectedCallbackResult();

    function validateAndUnpack(address, uint256, bytes calldata, bytes32, bytes[] calldata callResults)
        external
        pure
        returns (uint256[] memory slots)
    {
        for (uint256 i; i < callResults.length; ++i) {
            if (abi.decode(callResults[i], (bytes4)) != PrioUpdateRegistryV2.CallbackNotAllowed.selector) {
                revert UnexpectedCallbackResult();
            }
        }
        slots = new uint256[](1);
        slots[0] = callResults.length;
    }
}

contract CallbackDecoder is IPrioUpdateDecoder {
    PrioUpdateRegistryV2 private immutable registry;

    constructor(PrioUpdateRegistryV2 registry_) {
        registry = registry_;
    }

    function validateAndUnpack(address, uint256, bytes calldata, bytes32, bytes[] calldata)
        external
        view
        returns (uint256[] memory slots)
    {
        registry.isUpdater(address(this), address(this));
        slots = new uint256[](1);
        slots[0] = 1;
    }
}
