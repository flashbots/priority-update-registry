// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrioUpdateRegistry} from "../src/PrioUpdateRegistry.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

contract MockERC1271 {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recoverCalldata(hash, signature) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract PrioUpdateRegistryTest is Test {
    PrioUpdateRegistry registry;
    uint256 updaterKey = 0xA11CE;
    address updater;
    address target = address(0x2);
    address nobody = address(0x3);

    uint256 constant MAX_UPDATE_AGE = 1 hours;
    uint256 constant MAX_UPDATE_LEAD_TIME = 1 hours;

    function setUp() public {
        updater = vm.addr(updaterKey);
        vm.warp(1_700_000_000);
        registry = new PrioUpdateRegistry(MAX_UPDATE_AGE, MAX_UPDATE_LEAD_TIME);
    }

    function _signUpdate(address _target, uint256 _laneIndex, uint32 ts, uint256[] memory slots)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(registry.UPDATE_TYPEHASH(), _target, _laneIndex, ts, keccak256(abi.encodePacked(slots)))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(updaterKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeSignedUpdate(address _target, uint256 _laneIndex, uint32 ts, uint256[] memory slots)
        internal
        view
        returns (PrioUpdateRegistry.SignedUpdate memory)
    {
        return PrioUpdateRegistry.SignedUpdate({
            target: _target,
            signer: updater,
            laneIndex: _laneIndex,
            updateTimestamp: ts,
            slots: slots,
            signature: _signUpdate(_target, _laneIndex, ts, slots)
        });
    }

    function _addUpdater(address _target, address _updater) internal {
        vm.prank(_target);
        registry.addUpdater(_updater);
    }

    function test_addUpdater() public {
        _addUpdater(target, updater);
        assertTrue(registry.isUpdater(target, updater));
    }

    function test_addUpdater_only_authorizes_for_msg_sender() public {
        vm.prank(nobody);
        registry.addUpdater(updater);
        assertTrue(registry.isUpdater(nobody, updater));
        assertFalse(registry.isUpdater(target, updater));
    }

    function test_removeUpdater() public {
        _addUpdater(target, updater);
        vm.prank(target);
        registry.removeUpdater(updater);
        assertFalse(registry.isUpdater(target, updater));
    }

    function test_removeUpdater_only_affects_msg_sender() public {
        _addUpdater(target, updater);
        vm.prank(nobody);
        registry.removeUpdater(updater);
        assertTrue(registry.isUpdater(target, updater));
    }

    function test_multiple_updaters_per_target() public {
        address updater2 = address(0xBEEF);
        _addUpdater(target, updater);
        _addUpdater(target, updater2);

        uint256[] memory slots = new uint256[](1);
        slots[0] = 0x1;
        vm.prank(updater);
        registry.updateState(target, 0, uint32(block.timestamp), slots);

        slots[0] = 0x2;
        vm.prank(updater2);
        registry.updateState(target, 0, uint32(block.timestamp), slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, uint32(block.timestamp));
        assertEq(got[0], 0x2);
    }

    function test_addUpdater_noop_when_already_authorized() public {
        _addUpdater(target, updater);
        vm.recordLogs();
        _addUpdater(target, updater);
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(registry.isUpdater(target, updater));
    }

    function test_removeUpdater_noop_when_not_authorized() public {
        vm.recordLogs();
        vm.prank(target);
        registry.removeUpdater(updater);
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(registry.isUpdater(target, updater));
    }

    function test_removed_updater_cannot_update() public {
        _addUpdater(target, updater);
        vm.prank(target);
        registry.removeUpdater(updater);

        uint256[] memory slots = new uint256[](1);
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.updateState(target, 0, uint32(block.timestamp), slots);
    }

    function test_updateState_and_getState_single_slot() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xdeadbeef;

        vm.prank(updater);
        registry.updateState(target, 0, uint32(block.timestamp), slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, uint32(block.timestamp));
        assertEq(got[0], slots[0]);
    }

    function test_updateState_and_getState_multi_slot() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](3);
        slots[0] = 0xaabbccdd;
        slots[1] = 0x1111111111111111;
        slots[2] = 0x2222222222222222;

        vm.prank(updater);
        registry.updateState(target, 0, uint32(block.timestamp), slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, uint32(block.timestamp));
        assertEq(got.length, 3);
        assertEq(got[0], slots[0]);
        assertEq(got[1], slots[1]);
        assertEq(got[2], slots[2]);
    }

    function test_updateState_reverts_unauthorized() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);

        vm.prank(nobody);
        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.updateState(target, 0, uint32(block.timestamp), slots);
    }

    function test_updateState_arbitrary_timestamp() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        vm.warp(3000);
        vm.prank(updater);
        registry.updateState(target, 0, uint32(500), slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, 500);
        assertEq(got[0], 0xaa);

        slots[0] = 0xbb;
        vm.prank(updater);
        registry.updateState(target, 0, uint32(2000), slots);

        vm.prank(target);
        (ts, got) = registry.getState(0);
        assertEq(ts, 2000);
        assertEq(got[0], 0xbb);
    }

    function test_updateState_reverts_stale_update() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        uint32 newer = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(target, 0, newer, slots);

        slots[0] = 0xbb;
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.StaleUpdate.selector);
        registry.updateState(target, 0, newer - 1, slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, newer);
        assertEq(got[0], 0xaa);
    }

    function test_updateState_allows_equal_timestamp() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        uint32 ts0 = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(target, 0, ts0, slots);

        slots[0] = 0xbb;
        vm.prank(updater);
        registry.updateState(target, 0, ts0, slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, ts0);
        assertEq(got[0], 0xbb);
    }

    function test_updateState_stale_check_is_per_lane() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        uint32 newer = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(target, 0, newer, slots);

        slots[0] = 0xbb;
        vm.prank(updater);
        registry.updateState(target, 1, newer - 1, slots);

        vm.prank(target);
        (uint32 ts1, uint256[] memory got1) = registry.getState(1);
        assertEq(ts1, newer - 1);
        assertEq(got1[0], 0xbb);
    }

    function test_batchUpdateStateWithSignature_reverts_stale_update() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        uint32 newer = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(target, 0, newer, slots);

        slots[0] = 0xbb;
        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, newer - 1, slots);

        vm.expectRevert(PrioUpdateRegistry.StaleUpdate.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_updateState_reverts_empty_slots() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](0);

        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.EmptySlots.selector);
        registry.updateState(target, 0, uint32(block.timestamp), slots);
    }

    function test_updateState_reverts_slot0_too_large() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = uint256(1) << 216;

        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.Slot0Exceeds27Bytes.selector);
        registry.updateState(target, 0, uint32(block.timestamp), slots);
    }

    function test_constructor_sets_bounds() public view {
        assertEq(registry.MAX_UPDATE_AGE(), MAX_UPDATE_AGE);
        assertEq(registry.MAX_UPDATE_LEAD_TIME(), MAX_UPDATE_LEAD_TIME);
    }

    function test_updateState_accepts_boundary_timestamps() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 oldestAllowed = uint32(block.timestamp - MAX_UPDATE_AGE);
        vm.prank(updater);
        registry.updateState(target, 0, oldestAllowed, slots);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 newestAllowed = uint32(block.timestamp + MAX_UPDATE_LEAD_TIME);
        vm.prank(updater);
        registry.updateState(target, 0, newestAllowed, slots);
    }

    function test_updateState_reverts_timestamp_too_old() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 tooOld = uint32(block.timestamp - MAX_UPDATE_AGE - 1);
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.InvalidUpdateTimestamp.selector);
        registry.updateState(target, 0, tooOld, slots);
    }

    function test_updateState_reverts_timestamp_too_far_in_future() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 tooNew = uint32(block.timestamp + MAX_UPDATE_LEAD_TIME + 1);
        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.InvalidUpdateTimestamp.selector);
        registry.updateState(target, 0, tooNew, slots);
    }

    function test_batchUpdateStateWithSignature_reverts_timestamp_too_old() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 tooOld = uint32(block.timestamp - MAX_UPDATE_AGE - 1);
        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, tooOld, slots);

        vm.expectRevert(PrioUpdateRegistry.InvalidUpdateTimestamp.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_timestamp_too_far_in_future() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 tooNew = uint32(block.timestamp + MAX_UPDATE_LEAD_TIME + 1);
        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, tooNew, slots);

        vm.expectRevert(PrioUpdateRegistry.InvalidUpdateTimestamp.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_getState_returns_stale_timestamp() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        uint32 writtenAt = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(target, 0, writtenAt, slots);

        vm.warp(block.timestamp + 12);
        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, writtenAt);
        assertEq(got[0], 0xaa);
    }

    function test_getState_never_updated() public {
        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, 0);
        assertEq(got.length, 0);
    }

    function test_overwrite_state_same_block() public {
        _addUpdater(target, updater);
        uint256[] memory slots1 = new uint256[](1);
        slots1[0] = 0xaa;
        uint256[] memory slots2 = new uint256[](1);
        slots2[0] = 0xbb;

        vm.prank(updater);
        registry.updateState(target, 0, uint32(block.timestamp), slots1);

        vm.prank(updater);
        registry.updateState(target, 0, uint32(block.timestamp), slots2);

        vm.prank(target);
        (, uint256[] memory got) = registry.getState(0);
        assertEq(got[0], 0xbb);
    }

    function test_updater_preserved_after_update() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xff;

        vm.prank(updater);
        registry.updateState(target, 0, uint32(block.timestamp), slots);

        assertTrue(registry.isUpdater(target, updater));
    }

    function test_independent_lanes() public {
        _addUpdater(target, updater);

        uint256[] memory slots0 = new uint256[](1);
        slots0[0] = 0xaa;
        uint256[] memory slots1 = new uint256[](1);
        slots1[0] = 0xbb;

        uint32 t0 = uint32(block.timestamp);

        vm.prank(updater);
        registry.updateState(target, 0, t0, slots0);
        vm.prank(updater);
        registry.updateState(target, 1, t0, slots1);

        vm.prank(target);
        (uint32 ts0, uint256[] memory got0) = registry.getState(0);
        assertEq(ts0, t0);
        assertEq(got0[0], 0xaa);

        vm.prank(target);
        (uint32 ts1, uint256[] memory got1) = registry.getState(1);
        assertEq(ts1, t0);
        assertEq(got1[0], 0xbb);

        vm.warp(block.timestamp + 12);

        vm.prank(updater);
        registry.updateState(target, 0, uint32(block.timestamp), slots0);

        vm.prank(target);
        (ts0, got0) = registry.getState(0);
        assertEq(ts0, uint32(block.timestamp));

        vm.prank(target);
        (ts1, got1) = registry.getState(1);
        assertEq(ts1, t0);
        assertEq(got1[0], 0xbb);
    }

    function test_batchUpdateStateWithSignature_and_getState_single_slot() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xdeadbeef;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), slots);

        registry.batchUpdateStateWithSignature(updates);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, uint32(block.timestamp));
        assertEq(got[0], slots[0]);
    }

    function test_batchUpdateStateWithSignature_reverts_invalid_signature() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: target,
            signer: updater,
            laneIndex: 0,
            updateTimestamp: uint32(block.timestamp),
            slots: slots,
            signature: hex"1234"
        });

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_unauthorized_signer() public {
        _addUpdater(target, updater);
        uint256 wrongKey = 0xB0B;
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        bytes32 structHash = keccak256(
            abi.encode(
                registry.UPDATE_TYPEHASH(), target, uint256(0), block.timestamp, keccak256(abi.encodePacked(slots))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        address wrongSigner = vm.addr(wrongKey);
        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: target,
            signer: wrongSigner,
            laneIndex: 0,
            updateTimestamp: uint32(block.timestamp),
            slots: slots,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_signer_mismatch() public {
        _addUpdater(target, updater);
        uint256 wrongKey = 0xB0B;
        address wrongSigner = vm.addr(wrongKey);
        _addUpdater(target, wrongSigner);

        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        bytes32 structHash = keccak256(
            abi.encode(
                registry.UPDATE_TYPEHASH(), target, uint256(0), block.timestamp, keccak256(abi.encodePacked(slots))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: target,
            signer: updater,
            laneIndex: 0,
            updateTimestamp: uint32(block.timestamp),
            slots: slots,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_erc1271() public {
        MockERC1271 wallet = new MockERC1271(updater);
        address walletAddr = address(wallet);

        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xcafe;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: walletAddr,
            signer: walletAddr,
            laneIndex: 0,
            updateTimestamp: uint32(block.timestamp),
            slots: slots,
            signature: _signUpdate(walletAddr, 0, uint32(block.timestamp), slots)
        });

        registry.batchUpdateStateWithSignature(updates);

        vm.prank(walletAddr);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, uint32(block.timestamp));
        assertEq(got[0], slots[0]);
    }

    function test_batchUpdateStateWithSignature_erc1271_reverts_invalid() public {
        MockERC1271 wallet = new MockERC1271(updater);
        address walletAddr = address(wallet);

        uint256 wrongKey = 0xB0B;
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        bytes32 structHash = keccak256(
            abi.encode(
                registry.UPDATE_TYPEHASH(), walletAddr, uint256(0), block.timestamp, keccak256(abi.encodePacked(slots))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: walletAddr,
            signer: walletAddr,
            laneIndex: 0,
            updateTimestamp: uint32(block.timestamp),
            slots: slots,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_empty_slots() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](0);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), slots);

        vm.expectRevert(PrioUpdateRegistry.EmptySlots.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_slot0_too_large() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = uint256(1) << 216;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), slots);

        vm.expectRevert(PrioUpdateRegistry.Slot0Exceeds27Bytes.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_replay_within_window() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xc0ffee;

        uint32 ts = uint32(block.timestamp);
        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, ts, slots);

        vm.prank(updater);
        registry.batchUpdateStateWithSignature(updates);

        vm.warp(block.timestamp + MAX_UPDATE_AGE);

        vm.prank(nobody);
        registry.batchUpdateStateWithSignature(updates);

        vm.prank(target);
        (uint32 storedTs, uint256[] memory got) = registry.getState(0);
        assertEq(storedTs, ts);
        assertEq(got[0], slots[0]);

        vm.warp(block.timestamp + 1);
        vm.prank(nobody);
        vm.expectRevert(PrioUpdateRegistry.InvalidUpdateTimestamp.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_replay_blocked_after_revoke() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xc0ffee;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), slots);

        registry.batchUpdateStateWithSignature(updates);

        vm.prank(target);
        registry.removeUpdater(updater);

        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function _assertLaneEmpty(address _target, uint256 _laneIndex) internal {
        vm.prank(_target);
        (uint32 ts, uint256[] memory got) = registry.getState(_laneIndex);
        assertEq(ts, 0);
        assertEq(got.length, 0);
    }

    function test_batchUpdateStateWithSignature_atomicity_invalid_signature() public {
        _addUpdater(target, updater);
        uint256[] memory validSlots = new uint256[](1);
        validSlots[0] = 0xaa;
        uint256[] memory laterSlots = new uint256[](1);
        laterSlots[0] = 0xbb;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](2);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), validSlots);
        updates[1] = PrioUpdateRegistry.SignedUpdate({
            target: target,
            signer: updater,
            laneIndex: 1,
            updateTimestamp: uint32(block.timestamp),
            slots: laterSlots,
            signature: hex"1234"
        });

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        registry.batchUpdateStateWithSignature(updates);

        _assertLaneEmpty(target, 0);
        _assertLaneEmpty(target, 1);
    }

    function test_batchUpdateStateWithSignature_atomicity_unauthorized_signer() public {
        _addUpdater(target, updater);
        uint256 wrongKey = 0xB0B;
        address wrongSigner = vm.addr(wrongKey);

        uint256[] memory validSlots = new uint256[](1);
        validSlots[0] = 0xaa;
        uint256[] memory laterSlots = new uint256[](1);
        laterSlots[0] = 0xbb;

        bytes32 structHash = keccak256(
            abi.encode(
                registry.UPDATE_TYPEHASH(), target, uint256(1), block.timestamp, keccak256(abi.encodePacked(laterSlots))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](2);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), validSlots);
        updates[1] = PrioUpdateRegistry.SignedUpdate({
            target: target,
            signer: wrongSigner,
            laneIndex: 1,
            updateTimestamp: uint32(block.timestamp),
            slots: laterSlots,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.batchUpdateStateWithSignature(updates);

        _assertLaneEmpty(target, 0);
        _assertLaneEmpty(target, 1);
    }

    function test_batchUpdateStateWithSignature_atomicity_empty_slots() public {
        _addUpdater(target, updater);
        uint256[] memory validSlots = new uint256[](1);
        validSlots[0] = 0xaa;
        uint256[] memory emptySlots = new uint256[](0);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](2);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), validSlots);
        updates[1] = _makeSignedUpdate(target, 1, uint32(block.timestamp), emptySlots);

        vm.expectRevert(PrioUpdateRegistry.EmptySlots.selector);
        registry.batchUpdateStateWithSignature(updates);

        _assertLaneEmpty(target, 0);
        _assertLaneEmpty(target, 1);
    }

    function test_batchUpdateStateWithSignature_atomicity_slot0_too_large() public {
        _addUpdater(target, updater);
        uint256[] memory validSlots = new uint256[](1);
        validSlots[0] = 0xaa;
        uint256[] memory badSlots = new uint256[](1);
        badSlots[0] = uint256(1) << 216;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](2);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), validSlots);
        updates[1] = _makeSignedUpdate(target, 1, uint32(block.timestamp), badSlots);

        vm.expectRevert(PrioUpdateRegistry.Slot0Exceeds27Bytes.selector);
        registry.batchUpdateStateWithSignature(updates);

        _assertLaneEmpty(target, 0);
        _assertLaneEmpty(target, 1);
    }

    function test_batchUpdateStateWithSignature_atomicity_invalid_timestamp() public {
        _addUpdater(target, updater);
        uint256[] memory validSlots = new uint256[](1);
        validSlots[0] = 0xaa;
        uint256[] memory laterSlots = new uint256[](1);
        laterSlots[0] = 0xbb;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 tooNew = uint32(block.timestamp + MAX_UPDATE_LEAD_TIME + 1);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](2);
        updates[0] = _makeSignedUpdate(target, 0, uint32(block.timestamp), validSlots);
        updates[1] = _makeSignedUpdate(target, 1, tooNew, laterSlots);

        vm.expectRevert(PrioUpdateRegistry.InvalidUpdateTimestamp.selector);
        registry.batchUpdateStateWithSignature(updates);

        _assertLaneEmpty(target, 0);
        _assertLaneEmpty(target, 1);
    }

    function test_batchUpdateStateWithSignature_atomicity_stale_update() public {
        _addUpdater(target, updater);

        // Pre-existing newer state on lane 1.
        uint256[] memory preSlots = new uint256[](1);
        preSlots[0] = 0xc0;
        uint32 newer = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(target, 1, newer, preSlots);

        uint256[] memory validSlots = new uint256[](1);
        validSlots[0] = 0xaa;
        uint256[] memory staleSlots = new uint256[](1);
        staleSlots[0] = 0xbb;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](2);
        updates[0] = _makeSignedUpdate(target, 0, newer, validSlots);
        updates[1] = _makeSignedUpdate(target, 1, newer - 1, staleSlots);

        vm.expectRevert(PrioUpdateRegistry.StaleUpdate.selector);
        registry.batchUpdateStateWithSignature(updates);

        // Lane 0's valid update was rolled back.
        _assertLaneEmpty(target, 0);
        // Lane 1's pre-existing state is unchanged.
        vm.prank(target);
        (uint32 ts1, uint256[] memory got1) = registry.getState(1);
        assertEq(ts1, newer);
        assertEq(got1[0], preSlots[0]);
    }
}
