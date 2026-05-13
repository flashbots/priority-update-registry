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

    function setUp() public {
        updater = vm.addr(updaterKey);
        registry = new PrioUpdateRegistry();
    }

    function _signUpdate(address _target, uint256 _laneIndex, uint256 ts, uint256[] memory slots)
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

    function _makeSignedUpdate(address _target, uint256 _laneIndex, uint256 ts, uint256[] memory slots)
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
        registry.updateState(target, 0, block.timestamp, slots);

        slots[0] = 0x2;
        vm.prank(updater2);
        registry.updateState(target, 0, block.timestamp, slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, block.timestamp);
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
        registry.updateState(target, 0, block.timestamp, slots);
    }

    function test_updateState_and_getState_single_slot() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xdeadbeef;

        vm.prank(updater);
        registry.updateState(target, 0, block.timestamp, slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, block.timestamp);
        assertEq(got[0], slots[0]);
    }

    function test_updateState_and_getState_multi_slot() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](3);
        slots[0] = 0xaabbccdd;
        slots[1] = 0x1111111111111111;
        slots[2] = 0x2222222222222222;

        vm.prank(updater);
        registry.updateState(target, 0, block.timestamp, slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, block.timestamp);
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
        registry.updateState(target, 0, block.timestamp, slots);
    }

    function test_updateState_arbitrary_timestamp() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        vm.warp(1000);
        vm.prank(updater);
        registry.updateState(target, 0, 2000, slots);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, 2000);
        assertEq(got[0], 0xaa);

        slots[0] = 0xbb;
        vm.prank(updater);
        registry.updateState(target, 0, 500, slots);

        vm.prank(target);
        (ts, got) = registry.getState(0);
        assertEq(ts, 500);
        assertEq(got[0], 0xbb);
    }

    function test_updateState_reverts_empty_slots() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](0);

        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.EmptySlots.selector);
        registry.updateState(target, 0, block.timestamp, slots);
    }

    function test_updateState_reverts_slot0_too_large() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = uint256(1) << 216;

        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.Slot0Exceeds27Bytes.selector);
        registry.updateState(target, 0, block.timestamp, slots);
    }

    function test_getState_returns_stale_timestamp() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xaa;

        uint256 writtenAt = block.timestamp;
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
        registry.updateState(target, 0, block.timestamp, slots1);

        vm.prank(updater);
        registry.updateState(target, 0, block.timestamp, slots2);

        vm.prank(target);
        (, uint256[] memory got) = registry.getState(0);
        assertEq(got[0], 0xbb);
    }

    function test_updater_preserved_after_update() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xff;

        vm.prank(updater);
        registry.updateState(target, 0, block.timestamp, slots);

        assertTrue(registry.isUpdater(target, updater));
    }

    function test_independent_lanes() public {
        _addUpdater(target, updater);

        uint256[] memory slots0 = new uint256[](1);
        slots0[0] = 0xaa;
        uint256[] memory slots1 = new uint256[](1);
        slots1[0] = 0xbb;

        uint256 t0 = block.timestamp;

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
        registry.updateState(target, 0, block.timestamp, slots0);

        vm.prank(target);
        (ts0, got0) = registry.getState(0);
        assertEq(ts0, block.timestamp);

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
        updates[0] = _makeSignedUpdate(target, 0, block.timestamp, slots);

        registry.batchUpdateStateWithSignature(updates);

        vm.prank(target);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, block.timestamp);
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
            updateTimestamp: block.timestamp,
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
                registry.UPDATE_TYPEHASH(),
                target,
                uint256(0),
                block.timestamp,
                keccak256(abi.encodePacked(slots))
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
            updateTimestamp: block.timestamp,
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
                registry.UPDATE_TYPEHASH(),
                target,
                uint256(0),
                block.timestamp,
                keccak256(abi.encodePacked(slots))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: target,
            signer: updater,
            laneIndex: 0,
            updateTimestamp: block.timestamp,
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
            updateTimestamp: block.timestamp,
            slots: slots,
            signature: _signUpdate(walletAddr, 0, block.timestamp, slots)
        });

        registry.batchUpdateStateWithSignature(updates);

        vm.prank(walletAddr);
        (uint32 ts, uint256[] memory got) = registry.getState(0);
        assertEq(ts, block.timestamp);
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
                registry.UPDATE_TYPEHASH(),
                walletAddr,
                uint256(0),
                block.timestamp,
                keccak256(abi.encodePacked(slots))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: walletAddr,
            signer: walletAddr,
            laneIndex: 0,
            updateTimestamp: block.timestamp,
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
        updates[0] = _makeSignedUpdate(target, 0, block.timestamp, slots);

        vm.expectRevert(PrioUpdateRegistry.EmptySlots.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_slot0_too_large() public {
        _addUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = uint256(1) << 216;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, 0, block.timestamp, slots);

        vm.expectRevert(PrioUpdateRegistry.Slot0Exceeds27Bytes.selector);
        registry.batchUpdateStateWithSignature(updates);
    }
}
