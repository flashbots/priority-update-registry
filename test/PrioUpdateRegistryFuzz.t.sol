// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrioUpdateRegistry} from "../src/PrioUpdateRegistry.sol";

contract PrioUpdateRegistryFuzzTest is Test {
    PrioUpdateRegistry registry;
    address updater = address(0xA11CE);

    uint256 constant MAX_UPDATE_AGE = 1 hours;
    uint256 constant MAX_UPDATE_LEAD_TIME = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new PrioUpdateRegistry(MAX_UPDATE_AGE, MAX_UPDATE_LEAD_TIME);
    }

    function _addUpdater(address target, address u) internal {
        vm.prank(target);
        registry.addUpdater(u);
    }

    function _buildSlots(uint8 numSlots, bytes32 seed) internal pure returns (uint256[] memory slots) {
        slots = new uint256[](numSlots);
        if (numSlots == 0) return slots;
        slots[0] = uint256(keccak256(abi.encode(seed, uint256(0)))) & ((uint256(1) << 216) - 1);
        for (uint256 i = 1; i < numSlots; i++) {
            slots[i] = uint256(keccak256(abi.encode(seed, i)));
        }
    }

    function _boundTs(uint32 fuzzTs) internal view returns (uint32) {
        uint256 lo = block.timestamp - MAX_UPDATE_AGE;
        uint256 hi = block.timestamp + MAX_UPDATE_LEAD_TIME;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(bound(uint256(fuzzTs), lo, hi));
    }

    function _assertSlotsEq(uint256[] memory got, uint256[] memory expected) internal pure {
        assertEq(got.length, expected.length);
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(got[i], expected[i]);
        }
    }

    /// Property: After updateState(t, l, ts, slots) succeeds, getState(l) from t
    /// returns (ts, slots) byte-for-byte.
    function testFuzz_round_trip(address target, uint256 laneIndex, uint32 fuzzTs, uint8 numSlots, bytes32 seed)
        public
    {
        numSlots = uint8(bound(uint256(numSlots), 1, 255));
        uint32 ts = _boundTs(fuzzTs);
        uint256[] memory slots = _buildSlots(numSlots, seed);

        _addUpdater(target, updater);
        vm.prank(updater);
        registry.updateState(target, laneIndex, ts, slots);

        vm.prank(target);
        (uint32 gotTs, uint256[] memory got) = registry.getState(laneIndex, 0, type(uint32).max);

        assertEq(gotTs, ts);
        _assertSlotsEq(got, slots);
    }

    struct LaneCase {
        address target;
        uint256 laneA;
        uint256 laneB;
        uint32 tsA;
        uint32 tsB;
        uint256[] slotsA;
        uint256[] slotsB;
    }

    /// Property: Updates to lane i never observably affect lane j for j != i.
    function testFuzz_lane_isolation(
        address target,
        uint256 laneA,
        uint256 laneB,
        uint32 fuzzTsA,
        uint32 fuzzTsB,
        uint8 numSlotsA,
        uint8 numSlotsB,
        bytes32 seedA,
        bytes32 seedB
    ) public {
        vm.assume(laneA != laneB);
        LaneCase memory c = LaneCase({
            target: target,
            laneA: laneA,
            laneB: laneB,
            tsA: _boundTs(fuzzTsA),
            tsB: _boundTs(fuzzTsB),
            slotsA: _buildSlots(uint8(bound(uint256(numSlotsA), 1, 255)), seedA),
            slotsB: _buildSlots(uint8(bound(uint256(numSlotsB), 1, 255)), seedB)
        });
        _runLaneIsolation(c);
    }

    function _runLaneIsolation(LaneCase memory c) internal {
        _addUpdater(c.target, updater);

        vm.prank(updater);
        registry.updateState(c.target, c.laneA, c.tsA, c.slotsA);
        vm.prank(updater);
        registry.updateState(c.target, c.laneB, c.tsB, c.slotsB);

        vm.prank(c.target);
        (uint32 gotTsA, uint256[] memory gotA) = registry.getState(c.laneA, 0, type(uint32).max);
        vm.prank(c.target);
        (uint32 gotTsB, uint256[] memory gotB) = registry.getState(c.laneB, 0, type(uint32).max);

        assertEq(gotTsA, c.tsA);
        assertEq(gotTsB, c.tsB);
        _assertSlotsEq(gotA, c.slotsA);
        _assertSlotsEq(gotB, c.slotsB);
    }

    /// Property: A 255-slot write to lane A never bleeds into any other lane B.
    /// Exercises the worst-case storage footprint for cross-lane collision.
    function testFuzz_lane_isolation_max_slots_no_bleed(uint256 laneA, uint256 laneB, bytes32 seed) public {
        vm.assume(laneA != laneB);
        address target = address(0xBEEF);

        _addUpdater(target, updater);
        uint256[] memory slotsA = _buildSlots(255, seed);

        uint32 ts = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(target, laneA, ts, slotsA);

        vm.prank(target);
        (uint32 gotTs, uint256[] memory gotB) = registry.getState(laneB, 0, type(uint32).max);
        assertEq(gotTs, 0);
        assertEq(gotB.length, 0);
    }

    struct IsolationCase {
        address targetA;
        address targetB;
        uint256 laneIndex;
        uint32 tsA;
        uint32 tsB;
        uint256[] slotsA;
        uint256[] slotsB;
    }

    /// Property: Updates for target a never affect storage observable to target b.
    function testFuzz_target_isolation(
        address targetA,
        address targetB,
        uint256 laneIndex,
        uint32 fuzzTsA,
        uint32 fuzzTsB,
        uint8 numSlotsA,
        uint8 numSlotsB,
        bytes32 seedA,
        bytes32 seedB
    ) public {
        vm.assume(targetA != targetB);
        IsolationCase memory c = IsolationCase({
            targetA: targetA,
            targetB: targetB,
            laneIndex: laneIndex,
            tsA: _boundTs(fuzzTsA),
            tsB: _boundTs(fuzzTsB),
            slotsA: _buildSlots(uint8(bound(uint256(numSlotsA), 1, 255)), seedA),
            slotsB: _buildSlots(uint8(bound(uint256(numSlotsB), 1, 255)), seedB)
        });
        _runTargetIsolation(c);
    }

    function _runTargetIsolation(IsolationCase memory c) internal {
        _addUpdater(c.targetA, updater);
        _addUpdater(c.targetB, updater);

        vm.prank(updater);
        registry.updateState(c.targetA, c.laneIndex, c.tsA, c.slotsA);
        vm.prank(updater);
        registry.updateState(c.targetB, c.laneIndex, c.tsB, c.slotsB);

        vm.prank(c.targetA);
        (uint32 gotTsA, uint256[] memory gotA) = registry.getState(c.laneIndex, 0, type(uint32).max);
        vm.prank(c.targetB);
        (uint32 gotTsB, uint256[] memory gotB) = registry.getState(c.laneIndex, 0, type(uint32).max);

        assertEq(gotTsA, c.tsA);
        assertEq(gotTsB, c.tsB);
        _assertSlotsEq(gotA, c.slotsA);
        _assertSlotsEq(gotB, c.slotsB);
    }

    /// Property: A 255-slot write under target A is invisible to a different target B
    /// at the same lane index.
    function testFuzz_target_isolation_max_slots_no_bleed(
        address targetA,
        address targetB,
        uint256 laneIndex,
        bytes32 seed
    ) public {
        vm.assume(targetA != targetB);
        _addUpdater(targetA, updater);
        uint256[] memory slotsA = _buildSlots(255, seed);

        uint32 ts = uint32(block.timestamp);
        vm.prank(updater);
        registry.updateState(targetA, laneIndex, ts, slotsA);

        vm.prank(targetB);
        (uint32 gotTs, uint256[] memory gotB) = registry.getState(laneIndex, 0, type(uint32).max);
        assertEq(gotTs, 0);
        assertEq(gotB.length, 0);
    }

    /// Property: isUpdater[t][u] tracks the last add/remove call for that pair,
    /// regardless of intervening calls for other (t, u) pairs.
    function testFuzz_isUpdater_arbitrary_sequence(address target, address u, bytes32 seed) public {
        bool expected = false;
        for (uint256 i = 0; i < 16; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r & 1 == 0) {
                vm.prank(target);
                registry.addUpdater(u);
                expected = true;
            } else {
                vm.prank(target);
                registry.removeUpdater(u);
                expected = false;
            }
            assertEq(registry.isUpdater(target, u), expected);
        }
    }

    /// Property: updateState does not mutate the isUpdater mapping for any (t, u) pair.
    function testFuzz_isUpdater_unaffected_by_updateState(
        address target,
        address otherUpdater,
        uint256 laneIndex,
        uint32 fuzzTs,
        uint8 numSlots,
        bytes32 seed
    ) public {
        vm.assume(otherUpdater != updater);
        numSlots = uint8(bound(uint256(numSlots), 1, 255));
        uint32 ts = _boundTs(fuzzTs);

        _addUpdater(target, updater);
        bool otherBefore = registry.isUpdater(target, otherUpdater);

        uint256[] memory slots = _buildSlots(numSlots, seed);
        vm.prank(updater);
        registry.updateState(target, laneIndex, ts, slots);

        assertTrue(registry.isUpdater(target, updater));
        assertEq(registry.isUpdater(target, otherUpdater), otherBefore);
    }

    /// Property: getState(lane, min, max) reverts iff the stored timestamp is outside
    /// `[min, max]`; otherwise it returns the stored timestamp and slots unchanged.
    function testFuzz_getState_bounds(
        address target,
        uint256 laneIndex,
        uint32 fuzzStoredTs,
        uint8 numSlots,
        bytes32 seed,
        uint32 minTimestamp,
        uint32 maxTimestamp
    ) public {
        numSlots = uint8(bound(uint256(numSlots), 1, 255));
        uint32 storedTs = _boundTs(fuzzStoredTs);
        uint256[] memory slots = _buildSlots(numSlots, seed);

        _addUpdater(target, updater);
        vm.prank(updater);
        registry.updateState(target, laneIndex, storedTs, slots);

        bool inRange = storedTs >= minTimestamp && storedTs <= maxTimestamp;
        vm.prank(target);
        if (inRange) {
            (uint32 gotTs, uint256[] memory got) = registry.getState(laneIndex, minTimestamp, maxTimestamp);
            assertEq(gotTs, storedTs);
            _assertSlotsEq(got, slots);
        } else {
            vm.expectRevert(PrioUpdateRegistry.StaleUpdate.selector);
            registry.getState(laneIndex, minTimestamp, maxTimestamp);
        }
    }

    /// Property: For a never-updated lane (stored timestamp 0), getState reverts unless
    /// `minTimestamp == 0`; when it does not revert, it returns (0, []).
    function testFuzz_getState_bounds_never_updated(
        address target,
        uint256 laneIndex,
        uint32 minTimestamp,
        uint32 maxTimestamp
    ) public {
        bool inRange = minTimestamp == 0;
        vm.prank(target);
        if (inRange) {
            (uint32 gotTs, uint256[] memory got) = registry.getState(laneIndex, minTimestamp, maxTimestamp);
            assertEq(gotTs, 0);
            assertEq(got.length, 0);
        } else {
            vm.expectRevert(PrioUpdateRegistry.StaleUpdate.selector);
            registry.getState(laneIndex, minTimestamp, maxTimestamp);
        }
    }

    /// Property: addUpdater for one (target, u) pair never authorizes a different pair.
    function testFuzz_isUpdater_pairwise_independence(
        address targetA,
        address targetB,
        address updaterA,
        address updaterB
    ) public {
        vm.assume(targetA != targetB || updaterA != updaterB);

        vm.prank(targetA);
        registry.addUpdater(updaterA);

        assertTrue(registry.isUpdater(targetA, updaterA));
        assertFalse(registry.isUpdater(targetB, updaterB));
    }
}
