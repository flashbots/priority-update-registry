// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrioUpdateRegistryV2, IPrioUpdateDecoder} from "../src/PrioUpdateRegistryV2.sol";
import {
    IPrioUpdateRegistryV2,
    SimplePricePropAMM,
    SignedReportDecoder,
    OracleReportPropAMM
} from "../src/demo/DemoPropAMMs.sol";

contract PrioUpdateRegistryV2Test is Test {
    PrioUpdateRegistryV2 internal reg;

    uint256 internal constant AGE = 5; // ticks behind allowed
    uint256 internal constant LEAD = 1; // ticks ahead allowed
    uint256 internal constant MAX_SLOTS = 255; // mirrors the contract constant
    uint256 internal constant FUTURE = 1000; // seconds of deadline headroom for happy-path reports

    address internal pusher = makeAddr("pusher");
    address internal relayer = makeAddr("relayer");
    address internal rando = makeAddr("rando");

    function setUp() public {
        reg = new PrioUpdateRegistryV2(AGE, LEAD);
        vm.roll(1000); // a non-trivial height
        vm.warp(1_700_000_000); // a realistic wall clock for deadlines
    }

    /*//////////////////////////////////////////////////////////////
                          LOW-GAS PATH (updateState)
    //////////////////////////////////////////////////////////////*/

    function test_lowGas_writeReadFresh() public {
        SimplePricePropAMM amm = new SimplePricePropAMM(IPrioUpdateRegistryV2(address(reg)));
        amm.authorizePusher(pusher);
        uint256 lane = amm.LANE();

        uint256 price = 2_000e18;
        uint256[] memory slots = new uint256[](2);
        slots[0] = block.timestamp; // maker's own freshness field
        slots[1] = price;

        vm.prank(pusher);
        reg.updateState(address(amm), lane, block.timestamp, slots);

        assertEq(amm.currentPrice(), price);
        assertEq(amm.quote(1e18), price); // 1 * price / 1e18
    }

    function test_lowGas_staleReverts() public {
        SimplePricePropAMM amm = new SimplePricePropAMM(IPrioUpdateRegistryV2(address(reg)));
        amm.authorizePusher(pusher);
        uint256 lane = amm.LANE();

        uint256[] memory slots = new uint256[](2);
        slots[0] = block.timestamp;
        slots[1] = 1e18;
        vm.prank(pusher);
        reg.updateState(address(amm), lane, block.timestamp, slots);

        vm.warp(block.timestamp + 1); // no fresh update landed this tick
        vm.expectRevert(
            abi.encodeWithSelector(SimplePricePropAMM.StaleQuote.selector, block.timestamp - 1, block.timestamp)
        );
        amm.currentPrice();
    }

    function test_lowGas_unauthorizedReverts() public {
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;
        vm.prank(rando);
        vm.expectRevert(PrioUpdateRegistryV2.NotAuthorized.selector);
        reg.updateState(address(this), 0, block.timestamp, slots);
    }

    function test_lowGas_emptySlotsReverts() public {
        reg.addUpdater(pusher); // address(this) is the target
        uint256[] memory slots = new uint256[](0);
        vm.prank(pusher);
        vm.expectRevert(PrioUpdateRegistryV2.EmptySlots.selector);
        reg.updateState(address(this), 0, block.timestamp, slots);
    }

    function test_lowGas_tooManySlotsReverts() public {
        reg.addUpdater(pusher);
        uint256[] memory slots = new uint256[](MAX_SLOTS + 1);
        vm.prank(pusher);
        vm.expectRevert(PrioUpdateRegistryV2.TooManySlots.selector);
        reg.updateState(address(this), 0, block.timestamp, slots);
    }

    /*//////////////////////////////////////////////////////////////
                          FRESHNESS WINDOW VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_window_tooOldReverts() public {
        reg.addUpdater(pusher);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;
        uint256 tooOld = block.timestamp - AGE - 1;
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(PrioUpdateRegistryV2.FreshnessTooOld.selector, tooOld, block.timestamp));
        reg.updateState(address(this), 0, tooOld, slots);
    }

    function test_window_tooFarAheadReverts() public {
        reg.addUpdater(pusher);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;
        uint256 tooAhead = block.timestamp + LEAD + 1;
        vm.prank(pusher);
        vm.expectRevert(
            abi.encodeWithSelector(PrioUpdateRegistryV2.FreshnessTooFarAhead.selector, tooAhead, block.timestamp)
        );
        reg.updateState(address(this), 0, tooAhead, slots);
    }

    function test_window_edgesAccepted() public {
        reg.addUpdater(pusher);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;
        // exactly AGE behind and exactly LEAD ahead both pass
        vm.prank(pusher);
        reg.updateState(address(this), 0, block.timestamp - AGE, slots);
        vm.prank(pusher);
        reg.updateState(address(this), 1, block.timestamp + LEAD, slots);
    }

    /*//////////////////////////////////////////////////////////////
                       CUSTOM PATH (decoder / staticcall)
    //////////////////////////////////////////////////////////////*/

    function _signAux(
        uint256 pk,
        address decoder,
        address target,
        uint256 lane,
        uint256 fresh,
        uint256 deadline,
        uint256 price
    ) internal view returns (bytes memory aux) {
        bytes32 digest = keccak256(abi.encode(decoder, block.chainid, target, lane, fresh, deadline, price));
        bytes32 ethDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethDigest);
        aux = abi.encode(fresh, deadline, price, abi.encodePacked(r, s, v));
    }

    function test_custom_writeReadFresh() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        SignedReportDecoder decoder = new SignedReportDecoder(signer);
        OracleReportPropAMM amm = new OracleReportPropAMM(IPrioUpdateRegistryV2(address(reg)), address(decoder));
        uint256 lane = amm.LANE();

        uint256 price = 3_500e18;
        bytes memory aux =
            _signAux(pk, address(decoder), address(amm), lane, block.timestamp, block.timestamp + FUTURE, price);

        // permissionless relay: an arbitrary address may submit a validly-signed report
        vm.prank(relayer);
        reg.updateStateWithDecoder(address(amm), lane, block.timestamp, aux);

        assertEq(amm.currentPrice(), price);
    }

    function test_custom_badSignatureReverts() public {
        (address signer,) = makeAddrAndKey("signer");
        (, uint256 wrongPk) = makeAddrAndKey("attacker");
        SignedReportDecoder decoder = new SignedReportDecoder(signer);
        OracleReportPropAMM amm = new OracleReportPropAMM(IPrioUpdateRegistryV2(address(reg)), address(decoder));
        uint256 lane = amm.LANE();

        bytes memory aux =
            _signAux(wrongPk, address(decoder), address(amm), lane, block.timestamp, block.timestamp + FUTURE, 1e18);

        vm.prank(relayer);
        vm.expectRevert(); // UntrustedSigner (recovered != signer)
        reg.updateStateWithDecoder(address(amm), lane, block.timestamp, aux);
    }

    /// @dev An OLD signed report (tick N) relayed at N+1 with a calldata `freshness=N` that still
    ///      passes the registry window must be rejected by the decoder, because it pins to the TRUE
    ///      clock value (N+1), not the calldata field.
    function test_custom_inWindowReplayReverts() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        SignedReportDecoder decoder = new SignedReportDecoder(signer);
        OracleReportPropAMM amm = new OracleReportPropAMM(IPrioUpdateRegistryV2(address(reg)), address(decoder));
        uint256 lane = amm.LANE();

        uint256 signedFresh = block.timestamp; // report signed for tick N
        bytes memory aux =
            _signAux(pk, address(decoder), address(amm), lane, signedFresh, block.timestamp + FUTURE, 1e18);

        vm.warp(block.timestamp + 1); // now at N+1; freshness=N is still within AGE
        vm.prank(relayer);
        vm.expectRevert(); // NotCurrentTick(signedFresh=N, freshnessNow=N+1)
        reg.updateStateWithDecoder(address(amm), lane, signedFresh, aux);
    }

    /// @dev A report pinned to the current tick but whose wall-clock deadline has passed (an includer
    ///      delayed inclusion) must be rejected — the tick pin alone can't catch a same-tick delay.
    function test_custom_expiredDeadlineReverts() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        SignedReportDecoder decoder = new SignedReportDecoder(signer);
        OracleReportPropAMM amm = new OracleReportPropAMM(IPrioUpdateRegistryV2(address(reg)), address(decoder));
        uint256 lane = amm.LANE();

        // signed for the current tick, but with a deadline already in the past
        bytes memory aux =
            _signAux(pk, address(decoder), address(amm), lane, block.timestamp, block.timestamp - 1, 1e18);

        vm.prank(relayer);
        vm.expectRevert(); // Expired(block.timestamp, deadline)
        reg.updateStateWithDecoder(address(amm), lane, block.timestamp, aux);
    }

    /*//////////////////////////////////////////////////////////////
                      PATH ISOLATION / DECODER BINDING
    //////////////////////////////////////////////////////////////*/

    function test_setDecoder_immutableOnceSet() public {
        reg.setDecoder(0, address(reg)); // any code-bearing address for the binding test
        vm.expectRevert(PrioUpdateRegistryV2.DecoderAlreadySet.selector);
        reg.setDecoder(0, address(this));
    }

    function test_setDecoder_zeroReverts() public {
        vm.expectRevert(PrioUpdateRegistryV2.ZeroDecoder.selector);
        reg.setDecoder(0, address(0));
    }

    function test_setDecoder_noCodeReverts() public {
        vm.expectRevert(PrioUpdateRegistryV2.DecoderHasNoCode.selector);
        reg.setDecoder(0, makeAddr("eoa")); // an EOA has no code
    }

    function test_lowGasOnDecoderLaneReverts() public {
        // address(this) is the target: authorize a pusher AND bind a decoder to lane 0
        reg.addUpdater(pusher);
        reg.setDecoder(0, address(reg)); // code-bearing; never actually called on this path
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;
        vm.prank(pusher);
        vm.expectRevert(PrioUpdateRegistryV2.DecoderBoundLane.selector);
        reg.updateState(address(this), 0, block.timestamp, slots);
    }

    function test_decoderPathOnPlainLaneReverts() public {
        vm.prank(relayer);
        vm.expectRevert(PrioUpdateRegistryV2.DecoderNotSet.selector);
        reg.updateStateWithDecoder(address(this), 7, block.timestamp, hex"00");
    }

    /*//////////////////////////////////////////////////////////////
                       STORAGE-COLLISION HARDENING
    //////////////////////////////////////////////////////////////*/

    /// @dev Without domain separation, `_laneBase(attacker, keccak256(abi.encode(victim, 0)))` equals
    ///      the storage slot of `isUpdater[victim][attacker]`, letting an attacker set that bit by
    ///      writing to its OWN lane and then seize the victim's lanes. Prove the namespaced lane base
    ///      no longer aliases the mapping.
    function test_namespaceCollision_cannotForgeUpdater() public {
        address victim = makeAddr("victim");
        address attacker = makeAddr("attacker");

        uint256 craftedLane = uint256(keccak256(abi.encode(victim, uint256(0))));

        vm.prank(attacker);
        reg.addUpdater(attacker);
        uint256[] memory slots = new uint256[](1);
        slots[0] = 1;
        vm.prank(attacker);
        reg.updateState(attacker, craftedLane, block.timestamp, slots);

        // the victim's updater bit was NOT forged
        assertFalse(reg.isUpdater(victim, attacker));

        // and the attacker still cannot write the victim's lanes
        vm.prank(attacker);
        vm.expectRevert(PrioUpdateRegistryV2.NotAuthorized.selector);
        reg.updateState(victim, 0, block.timestamp, slots);
    }

    /*//////////////////////////////////////////////////////////////
                            SELF-SCOPED READS
    //////////////////////////////////////////////////////////////*/

    function test_reads_areSelfScoped() public {
        reg.addUpdater(address(this)); // this contract authorizes itself as its own updater
        uint256[] memory slots = new uint256[](2);
        slots[0] = block.timestamp;
        slots[1] = 42;
        reg.updateState(address(this), 0, block.timestamp, slots); // target == this

        uint256[] memory mine = reg.getState(0, 2);
        assertEq(mine[1], 42);
        assertEq(reg.getSlot(0, 1), 42);

        // a DIFFERENT reader reads its OWN (empty) lane, not this contract's
        Reader other = new Reader(reg);
        assertEq(other.readSlot(0, 1), 0);
    }

    function test_getSlot_outOfRangeReverts() public {
        vm.expectRevert(PrioUpdateRegistryV2.SlotIndexOutOfRange.selector);
        reg.getSlot(0, MAX_SLOTS); // slotIndex must be < MAX_SLOTS
    }

    function test_getState_countTooLargeReverts() public {
        vm.expectRevert(PrioUpdateRegistryV2.SlotIndexOutOfRange.selector);
        reg.getState(0, MAX_SLOTS + 1);
    }
}

/// @dev A distinct contract to prove reads are scoped to `msg.sender`.
contract Reader {
    PrioUpdateRegistryV2 internal immutable reg;

    constructor(PrioUpdateRegistryV2 _reg) {
        reg = _reg;
    }

    function readSlot(uint256 lane, uint256 i) external view returns (uint256) {
        return reg.getSlot(lane, i);
    }
}
