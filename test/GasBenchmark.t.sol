// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {PrioUpdateRegistry} from "../src/PrioUpdateRegistry.sol";

contract GasBenchmarkTest is Test {
    PrioUpdateRegistry registry;
    uint256 updaterKey = 0xA11CE;
    address updater;
    address target = address(0x2);

    uint256 constant MAX_K = 10;
    uint256 constant MAX_N = 10;

    function _target(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function _signUpdate(address t, uint256 laneIndex, uint256 ts, uint256 cid, uint256[] memory slots)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(registry.UPDATE_TYPEHASH(), t, laneIndex, ts, cid, keccak256(abi.encodePacked(slots)))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(updaterKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeUpdateSlots(uint32 seed, uint256 additionalSlots) internal returns (uint256[] memory slots) {
        slots = new uint256[](1 + additionalSlots);
        slots[0] = 0xaa + seed;
        for (uint256 i = 1; i < slots.length; i++) {
            slots[i] = 0xaa + seed + i;
        }
        return slots;
    }

    function setUp() public {
        updater = vm.addr(updaterKey);
        registry = new PrioUpdateRegistry();

        uint256[] memory slots = _makeUpdateSlots(0xdead, MAX_K);

        registry.setUpdater(target, updater);
        vm.prank(updater);
        registry.updateState(target, 0, block.timestamp, slots);

        for (uint256 n = 0; n < MAX_N; n++) {
            address t = _target(n);
            registry.setUpdater(t, updater);
            vm.prank(updater);
            registry.updateState(t, 0, block.timestamp, slots);
        }
    }

    function estimateUpdateGas(uint256 k) internal pure returns (uint256) {
        /// 21000 + A0 + k * A1
        return 21000 + 9324 + k * 5212;
    }

    function estimateBatchSigGas(uint256 n, uint256 k) internal pure returns (uint256) {
        /// 21000 + B0 + n*(B1 + k * B2)
        return 21000 + 872 + n * (15757 + k * 5238);
    }

    function estimateStateReadCost(bool warm, uint256 k) internal pure returns (uint256) {
        if (warm) {
            /// C0 + C1*k
            return 1196 + 269 * k;
        } else {
            /// D0 + D1*k
            return 3196 + 2269 * k;
        }
    }

    /// forge-config: default.isolate = true
    function test_calculate_A0() public {
        PrioUpdateRegistry r = registry;
        address t = target;

        uint256 snap = vm.snapshot();
        vm.cool(address(r));

        uint256[] memory slots = _makeUpdateSlots(0, 0);

        vm.prank(updater);
        vm.startSnapshotGas("update_direct_k=0");
        r.updateState(t, 0, block.timestamp, slots);
        uint256 used = vm.snapshotGasLastCall("update_direct_k=0");

        uint256 A0 = used - 21000;
        console.log("A0 = %d", A0);

        vm.revertTo(snap);
    }

    /// forge-config: default.isolate = true
    function test_calculate_A1() public {
        PrioUpdateRegistry r = registry;
        address t = target;

        uint256 initialSlots = 5;
        uint256 slotsToAdd = 5;

        uint256[] memory slots0 = _makeUpdateSlots(0, initialSlots);
        uint256[] memory slots1 = _makeUpdateSlots(1, initialSlots + slotsToAdd);

        uint256 snap = vm.snapshot();
        vm.cool(address(r));
        vm.prank(updater);
        vm.startSnapshotGas("update_direct_k=5");
        r.updateState(t, 0, block.timestamp, slots0);
        uint256 gas_before = vm.snapshotGasLastCall("update_direct_k=5");
        vm.stopSnapshotGas("update_direct_k=5");
        vm.revertTo(snap);

        vm.cool(address(r));
        vm.prank(updater);
        vm.startSnapshotGas("update_direct_k=10");
        r.updateState(t, 0, block.timestamp, slots1);
        uint256 gas_after = vm.snapshotGasLastCall("update_direct_k=10");
        vm.stopSnapshotGas("update_direct_k=10");

        uint256 A1 = (gas_after - gas_before) / slotsToAdd;
        console.log("A1 = %d", A1);
    }

    function _prepareBatch(uint256 n, uint256 k) internal returns (PrioUpdateRegistry.SignedUpdate[] memory updates) {
        updates = new PrioUpdateRegistry.SignedUpdate[](n);
        for (uint256 i = 0; i < n; i++) {
            address t = _target(i);
            uint256[] memory slots = _makeUpdateSlots(0xcc + uint32(i), k);
            bytes memory sig = _signUpdate(t, 0, block.timestamp, block.chainid, slots);
            updates[i] = PrioUpdateRegistry.SignedUpdate(t, 0, block.timestamp, block.chainid, slots, sig);
        }
    }

    /// forge-config: default.isolate = true
    function test_calculate_B0() public {
        PrioUpdateRegistry r = registry;

        PrioUpdateRegistry.SignedUpdate[] memory updates = _prepareBatch(0, 0);

        uint256 snap = vm.snapshot();
        vm.cool(address(r));

        vm.startSnapshotGas("update_batch_k=0,n=0");
        r.batchUpdateStateWithSignature(updates);
        uint256 used = vm.snapshotGasLastCall("update_batch_k=0,n=0");

        uint256 B0 = used - 21000;
        console.log("B0 = %d", B0);

        vm.revertTo(snap);
    }

    /// forge-config: default.isolate = true
    function test_calculate_B1() public {
        PrioUpdateRegistry r = registry;

        uint256 n0 = 5;
        uint256 n1 = 10;
        uint256 k = 0;

        PrioUpdateRegistry.SignedUpdate[] memory updates0 = _prepareBatch(n0, k);
        PrioUpdateRegistry.SignedUpdate[] memory updates1 = _prepareBatch(n1, k);

        uint256 snap = vm.snapshot();
        vm.cool(address(r));
        vm.startSnapshotGas("update_batch_k=0,n=5");
        r.batchUpdateStateWithSignature(updates0);
        uint256 gas0 = vm.snapshotGasLastCall("update_batch_k=0,n=5");
        vm.stopSnapshotGas("update_batch_k=0,n=5");
        vm.revertTo(snap);

        vm.cool(address(r));
        vm.startSnapshotGas("update_batch_k=0,n=10");
        r.batchUpdateStateWithSignature(updates1);
        uint256 gas1 = vm.snapshotGasLastCall("update_batch_k=0,n=10");
        vm.stopSnapshotGas("update_batch_k=0,n=10");

        uint256 B1 = (gas1 - gas0) / (n1 - n0);
        console.log("B1 = %d", B1);
    }

    /// forge-config: default.isolate = true
    function test_calculate_B2() public {
        PrioUpdateRegistry r = registry;

        uint256 n = 5;
        uint256 k0 = 5;
        uint256 k1 = 10;

        PrioUpdateRegistry.SignedUpdate[] memory updates0 = _prepareBatch(n, k0);
        PrioUpdateRegistry.SignedUpdate[] memory updates1 = _prepareBatch(n, k1);

        uint256 snap = vm.snapshot();
        vm.cool(address(r));
        vm.startSnapshotGas("update_batch_n=5,k=5");
        r.batchUpdateStateWithSignature(updates0);
        uint256 gas0 = vm.snapshotGasLastCall("update_batch_n=5,k=5");
        vm.stopSnapshotGas("update_batch_n=5,k=5");
        vm.revertTo(snap);

        vm.cool(address(r));
        vm.startSnapshotGas("update_batch_n=5,k=10");
        r.batchUpdateStateWithSignature(updates1);
        uint256 gas1 = vm.snapshotGasLastCall("update_batch_n=5,k=10");
        vm.stopSnapshotGas("update_batch_n=5,k=10");

        uint256 B2 = (gas1 - gas0) / (n * (k1 - k0));
        console.log("B2 = %d", B2);
    }

    function test_calculate_C0() public {
        vm.prank(target);
        registry.getState(0, 1 + MAX_K);

        vm.prank(target);
        vm.startSnapshotGas("read_warm_k=0");
        registry.getState(0, 1);
        uint256 used = vm.snapshotGasLastCall("read_warm_k=0");

        console.log("C0 = %d", used);
    }

    function test_calculate_C1() public {
        uint256 k0 = 5;
        uint256 k1 = 10;

        vm.prank(target);
        registry.getState(0, 1 + MAX_K);

        vm.prank(target);
        vm.startSnapshotGas("read_warm_k=5");
        registry.getState(0, 1 + k0);
        uint256 gas0 = vm.snapshotGasLastCall("read_warm_k=5");
        vm.stopSnapshotGas("read_warm_k=5");

        vm.prank(target);
        vm.startSnapshotGas("read_warm_k=10");
        registry.getState(0, 1 + k1);
        uint256 gas1 = vm.snapshotGasLastCall("read_warm_k=10");
        vm.stopSnapshotGas("read_warm_k=10");

        uint256 C1 = (gas1 - gas0) / (k1 - k0);
        console.log("C1 = %d", C1);
    }

    function test_calculate_D0() public {
        vm.cool(address(registry));

        vm.prank(target);
        vm.startSnapshotGas("read_cold_k=0");
        registry.getState(0, 1);
        uint256 used = vm.snapshotGasLastCall("read_cold_k=0");

        console.log("D0 = %d", used);
    }

    function test_calculate_D1() public {
        uint256 k0 = 5;
        uint256 k1 = 10;

        uint256 snap = vm.snapshot();
        vm.cool(address(registry));

        vm.prank(target);
        vm.startSnapshotGas("read_cold_k=5");
        registry.getState(0, 1 + k0);
        uint256 gas0 = vm.snapshotGasLastCall("read_cold_k=5");
        vm.stopSnapshotGas("read_cold_k=5");
        vm.revertTo(snap);

        vm.cool(address(registry));

        vm.prank(target);
        vm.startSnapshotGas("read_cold_k=10");
        registry.getState(0, 1 + k1);
        uint256 gas1 = vm.snapshotGasLastCall("read_cold_k=10");
        vm.stopSnapshotGas("read_cold_k=10");

        uint256 D1 = (gas1 - gas0) / (k1 - k0);
        console.log("D1 = %d", D1);
    }

    /// forge-config: default.isolate = true
    function test_verify_write_formulas() public {
        PrioUpdateRegistry r = registry;
        address t = target;

        for (uint256 k = 0; k <= MAX_K; k++) {
            uint256 snap = vm.snapshot();
            uint256[] memory slots = _makeUpdateSlots(uint32(k), k);

            vm.cool(address(r));
            vm.prank(updater);
            vm.startSnapshotGas("verify");
            r.updateState(t, 0, block.timestamp, slots);
            uint256 actual = vm.snapshotGasLastCall("verify");
            vm.stopSnapshotGas("verify");

            assertApproxEqRel(actual, estimateUpdateGas(k), 0.05e18, string.concat("updateState k=", vm.toString(k)));
            vm.revertTo(snap);
        }

        uint256[3] memory ns = [uint256(1), 5, MAX_N];
        for (uint256 ni = 0; ni < 3; ni++) {
            uint256 n = ns[ni];
            for (uint256 k = 0; k <= MAX_K; k++) {
                uint256 snap = vm.snapshot();
                PrioUpdateRegistry.SignedUpdate[] memory updates = _prepareBatch(n, k);

                vm.cool(address(r));
                vm.startSnapshotGas("verify");
                r.batchUpdateStateWithSignature(updates);
                uint256 actual = vm.snapshotGasLastCall("verify");
                vm.stopSnapshotGas("verify");

                assertApproxEqRel(
                    actual,
                    estimateBatchSigGas(n, k),
                    0.05e18,
                    string.concat("batch n=", vm.toString(n), " k=", vm.toString(k))
                );
                vm.revertTo(snap);
            }
        }
    }

    function test_verify_read_formulas() public {
        vm.prank(target);
        registry.getState(0, 1 + MAX_K);

        for (uint256 k = 0; k <= MAX_K; k++) {
            vm.prank(target);
            vm.startSnapshotGas("verify");
            registry.getState(0, 1 + k);
            uint256 actual = vm.snapshotGasLastCall("verify");
            vm.stopSnapshotGas("verify");

            assertApproxEqRel(actual, estimateStateReadCost(true, k), 0.05e18, string.concat("warm k=", vm.toString(k)));
        }

        for (uint256 k = 0; k <= MAX_K; k++) {
            uint256 snap = vm.snapshot();
            vm.cool(address(registry));

            vm.prank(target);
            vm.startSnapshotGas("verify");
            registry.getState(0, 1 + k);
            uint256 actual = vm.snapshotGasLastCall("verify");
            vm.stopSnapshotGas("verify");

            assertApproxEqRel(
                actual, estimateStateReadCost(false, k), 0.05e18, string.concat("cold k=", vm.toString(k))
            );
            vm.revertTo(snap);
        }
    }

    function test_comparison_table() public pure {
        uint256[4] memory ns = [uint256(1), 2, 5, 10];
        for (uint256 i = 0; i < 4; i++) {
            uint256 n = ns[i];
            uint256 direct = n * estimateUpdateGas(0);
            uint256 batched = estimateBatchSigGas(n, 0);
            int256 savings = 100 - int256(batched * 100 / direct);
            console.log("n=%d | direct=%d | batched=%d", n, direct, batched);
            console.log("  savings=%d%%", savings);
        }
    }
}
