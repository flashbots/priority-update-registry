// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {PrioUpdateRegistry} from "../src/PrioUpdateRegistry.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

contract PrioUpdateRegistryTest is Test {
    PrioUpdateRegistry registry;
    address admin = address(this);
    uint256 updaterKey = 0xA11CE;
    address updater;
    address target = address(0x2);
    address nobody = address(0x3);

    function setUp() public {
        updater = vm.addr(updaterKey);
        registry = new PrioUpdateRegistry();
    }

    function _signUpdate(address _target, uint256 ts, uint256 cid, uint256[] memory slots)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(registry.UPDATE_TYPEHASH(), _target, ts, cid, keccak256(abi.encodePacked(slots))));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(updaterKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeSignedUpdate(address _target, uint256 ts, uint256 cid, uint256[] memory slots)
        internal
        view
        returns (PrioUpdateRegistry.SignedUpdate memory)
    {
        return PrioUpdateRegistry.SignedUpdate({
            target: _target,
            blockTimestamp: ts,
            chainId: cid,
            slots: slots,
            signature: _signUpdate(_target, ts, cid, slots)
        });
    }

    function test_admin_is_deployer() public view {
        assertEq(registry.admin(), admin);
    }

    function test_setUpdater() public {
        registry.setUpdater(target, updater);
        assertEq(registry.getUpdater(target), updater);
    }

    function test_setUpdater_reverts_non_admin() public {
        vm.prank(nobody);
        vm.expectRevert(PrioUpdateRegistry.NotAdmin.selector);
        registry.setUpdater(target, updater);
    }

    function test_transferAdmin() public {
        registry.transferAdmin(nobody);
        assertEq(registry.admin(), nobody);
    }

    function test_transferAdmin_reverts_non_admin() public {
        vm.prank(nobody);
        vm.expectRevert(PrioUpdateRegistry.NotAdmin.selector);
        registry.transferAdmin(updater);
    }

    function test_updateState_and_getState_single_slot() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xdeadbeef;

        vm.prank(updater);
        registry.updateState(target, block.timestamp, slots);

        vm.prank(target);
        uint256[] memory got = registry.getState(1);
        assertEq(got[0], slots[0]);
    }

    function test_updateState_and_getState_multi_slot() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](3);
        slots[0] = 0xaabbccdd;
        slots[1] = 0x1111111111111111;
        slots[2] = 0x2222222222222222;

        vm.prank(updater);
        registry.updateState(target, block.timestamp, slots);

        vm.prank(target);
        uint256[] memory got = registry.getState(3);
        assertEq(got[0], slots[0]);
        assertEq(got[1], slots[1]);
        assertEq(got[2], slots[2]);
    }

    function test_updateState_reverts_unauthorized() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);

        vm.prank(nobody);
        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.updateState(target, block.timestamp, slots);
    }

    function test_updateState_reverts_wrong_timestamp() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);

        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.WrongTimestamp.selector);
        registry.updateState(target, block.timestamp + 1, slots);
    }

    function test_updateState_reverts_empty_slots() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](0);

        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.EmptySlots.selector);
        registry.updateState(target, block.timestamp, slots);
    }

    function test_updateState_reverts_slot0_too_large() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = uint256(1) << 64;

        vm.prank(updater);
        vm.expectRevert(PrioUpdateRegistry.Slot0Exceeds8Bytes.selector);
        registry.updateState(target, block.timestamp, slots);
    }

    function test_getState_reverts_stale() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);

        vm.prank(updater);
        registry.updateState(target, block.timestamp, slots);

        vm.warp(block.timestamp + 12);
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistry.StateNotUpdated.selector);
        registry.getState(1);
    }

    function test_getState_reverts_never_updated() public {
        vm.prank(target);
        vm.expectRevert(PrioUpdateRegistry.StateNotUpdated.selector);
        registry.getState(1);
    }

    function test_overwrite_state_same_block() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots1 = new uint256[](1);
        slots1[0] = 0xaa;
        uint256[] memory slots2 = new uint256[](1);
        slots2[0] = 0xbb;

        vm.prank(updater);
        registry.updateState(target, block.timestamp, slots1);

        vm.prank(updater);
        registry.updateState(target, block.timestamp, slots2);

        vm.prank(target);
        uint256[] memory got = registry.getState(1);
        assertEq(got[0], 0xbb);
    }

    function test_updater_preserved_after_update() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xff;

        vm.prank(updater);
        registry.updateState(target, block.timestamp, slots);

        assertEq(registry.getUpdater(target), updater);
    }

    function test_batchUpdateStateWithSignature_and_getState_single_slot() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 0xdeadbeef;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, block.timestamp, block.chainid, slots);

        registry.batchUpdateStateWithSignature(updates);

        vm.prank(target);
        uint256[] memory got = registry.getState(1);
        assertEq(got[0], slots[0]);
    }

    function test_batchUpdateStateWithSignature_reverts_invalid_signature() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: target, blockTimestamp: block.timestamp, chainId: block.chainid, slots: slots, signature: hex"1234"
        });

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_unauthorized_signer() public {
        registry.setUpdater(target, updater);
        uint256 wrongKey = 0xB0B;
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        bytes32 structHash = keccak256(
            abi.encode(
                registry.UPDATE_TYPEHASH(), target, block.timestamp, block.chainid, keccak256(abi.encodePacked(slots))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = PrioUpdateRegistry.SignedUpdate({
            target: target,
            blockTimestamp: block.timestamp,
            chainId: block.chainid,
            slots: slots,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_wrong_timestamp() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, block.timestamp + 1, block.chainid, slots);

        vm.expectRevert(PrioUpdateRegistry.WrongTimestamp.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_wrong_chainId() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, block.timestamp, block.chainid + 1, slots);

        vm.expectRevert(PrioUpdateRegistry.WrongChainId.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_empty_slots() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](0);

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, block.timestamp, block.chainid, slots);

        vm.expectRevert(PrioUpdateRegistry.EmptySlots.selector);
        registry.batchUpdateStateWithSignature(updates);
    }

    function test_batchUpdateStateWithSignature_reverts_slot0_too_large() public {
        registry.setUpdater(target, updater);
        uint256[] memory slots = new uint256[](1);
        slots[0] = uint256(1) << 64;

        PrioUpdateRegistry.SignedUpdate[] memory updates = new PrioUpdateRegistry.SignedUpdate[](1);
        updates[0] = _makeSignedUpdate(target, block.timestamp, block.chainid, slots);

        vm.expectRevert(PrioUpdateRegistry.Slot0Exceeds8Bytes.selector);
        registry.batchUpdateStateWithSignature(updates);
    }
}
