// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPrioUpdateDecoder} from "../PrioUpdateRegistryV2.sol";

/// @title  Demo consumers of PrioUpdateRegistryV2 — one per write path
/// @notice Minimal, self-contained illustrations of how an actively-managed on-chain curve
///         ("propAMM") uses the two v2 write paths. NOT production code — the AMM math is a trivial
///         `price * amountIn` so the focus stays on the registry integration: how state is written,
///         how a same-tick freshness lock is enforced on read, and how the two paths differ.
///
///         Read-side pattern (the crux of the v2 design): the registry does NOT store the freshness
///         field, so a consumer records freshness in its OWN slot data and checks it on read. Here
///         each writer stores `[fresh, price]` and each swap requires `fresh == registry.freshnessNow()`
///         — a fresh update must have landed in the CURRENT tick (block or timestamp, per the
///         deployment's clock) or the swap reverts. That defends against an includer that DROPS the
///         fresh update and leaves a stale one. The custom decoder below adds the complementary
///         defence — a wall-clock `deadline` — against an includer that DELAYS inclusion.

/// @dev The subset of the registry ABI these demos use.
interface IPrioUpdateRegistryV2 {
    function addUpdater(address updater) external;
    function setDecoder(uint256 laneIndex, address decoder) external;
    function updateState(address target, uint256 laneIndex, uint256 freshness, uint256[] calldata slots) external;
    function updateStateWithDecoder(address target, uint256 laneIndex, uint256 freshness, bytes calldata aux) external;
    function getState(uint256 laneIndex, uint256 count) external view returns (uint256[] memory slots);
    function freshnessNow() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
        DEMO 1 — LOW-GAS PATH (maker computes its own quote)
//////////////////////////////////////////////////////////////*/

/// @notice A propAMM whose operator computes the quote off-chain and pushes it verbatim each tick
///         through the registry's LOW-GAS path (`updateState`, no external call). This is the ~99%
///         case: the maker trusts its own pusher, so no on-chain verification is needed. The pusher
///         submits live, so a delayed/missed tick just means it recomputes and re-pushes next tick.
///
///         Lifecycle:
///           1. deploy this contract (it is the lane TARGET — it owns lane {LANE}).
///           2. `authorizePusher(pusherEOA)` → the contract calls `registry.addUpdater(pusher)`.
///           3. each tick the pusher (off-chain) calls
///                 `registry.updateState(address(this), LANE, now, [now, price])`
///              where `now == registry.freshnessNow()`. The registry range-checks it and stores the
///              two words verbatim; it does not store the freshness itself — the maker mirrors it into
///              slot 0 as its own freshness field.
///           4. a swap calls {quote}; it reads the lane (self-scoped) and enforces the same-tick lock.
contract SimplePricePropAMM {
    IPrioUpdateRegistryV2 public immutable registry;

    /// @dev This demo uses a single lane and a fixed 2-word layout: slot0 = fresh, slot1 = price.
    uint256 public constant LANE = 0;
    uint256 internal constant SLOTS = 2;

    address public immutable owner;

    error NotOwner();
    error StaleQuote(uint256 fresh, uint256 nowRef);

    constructor(IPrioUpdateRegistryV2 _registry) {
        registry = _registry;
        owner = msg.sender;
    }

    /// @notice Authorize the off-chain price pusher on the registry's low-gas path.
    /// @dev    Calls `registry.addUpdater` with `msg.sender == address(this)`, i.e. this contract is
    ///         the target authorizing its own updater.
    function authorizePusher(address pusher) external {
        if (msg.sender != owner) revert NotOwner();
        registry.addUpdater(pusher);
    }

    /// @notice The current, same-tick-fresh price. Reverts unless the stored freshness equals the
    ///         current clock tick. On the low-gas path the (trusted) pusher stamps it, so this proves
    ///         the pusher marked the quote for THIS tick — as good as landed-this-tick given the pusher
    ///         is trusted. (Deploy with lead 0 so the pusher cannot pre-stamp a future tick.)
    /// @dev    Self-scoped read: `registry.getState` is called with `msg.sender == address(this)`.
    function currentPrice() public view returns (uint256 price) {
        uint256[] memory s = registry.getState(LANE, SLOTS);
        uint256 fresh = s[0];
        uint256 nowRef = registry.freshnessNow();
        if (fresh != nowRef) revert StaleQuote(fresh, nowRef);
        return s[1];
    }

    /// @notice Trivial swap quote using the fresh price (demo math only).
    function quote(uint256 amountIn) external view returns (uint256 amountOut) {
        return (amountIn * currentPrice()) / 1e18;
    }
}

/*//////////////////////////////////////////////////////////////
     DEMO 2 — CUSTOM PATH (maker ingests SIGNED price reports)
//////////////////////////////////////////////////////////////*/

/// @notice A `view` decoder that verifies a signed price report and unpacks it into lane slots — the
///         generic shape of a signed-oracle consumer. It applies BOTH freshness defences against an
///         adversarial includer (builder/sequencer) that wants a stale price to land:
///           - PIN to the current tick: require `signed == freshnessNow`, so the report cannot be
///             replayed into a different tick or pre-installed early (defends against reorder/replay).
///           - WALL-CLOCK deadline: require `block.timestamp <= deadline`, so the report is void once
///             its real-time deadline passes (defends against an includer that DELAYS inclusion — the
///             tick pin alone can't catch this, because on a block-number clock the block count is
///             unchanged by a delayed block, while `block.timestamp` grows with the delay).
///         Reached ONLY via the registry's `STATICCALL`, so it cannot write, log, or move value.
///
///         Same-tick note: within one tick, identical reports are a no-op (last write wins with the
///         same value). But if the signer emits MULTIPLE distinct reports for the SAME tick, a relayer
///         chooses which one lands — add a signed nonce / monotonic sequence to the digest if
///         intra-tick ordering must be enforced.
///
///         A production decoder would swap the `ecrecover` below for a DON `verifyView` (gasless,
///         `view`) or a signed-feed contract's `isValidSigner` — both `view`, both staticcall-safe.
///         Only fee-less, `view` verification fits here (a `STATICCALL` cannot pay a billed verify).
contract SignedReportDecoder is IPrioUpdateDecoder {
    /// @notice The trusted report signer (stands in for an oracle DON / feed signing key).
    address public immutable signer;

    error ZeroSigner();
    error BadSignatureLength();
    error UntrustedSigner(address recovered);
    error NotCurrentTick(uint256 signedFreshness, uint256 freshnessNow);
    error Expired(uint256 timestamp, uint256 deadline);

    constructor(address _signer) {
        if (_signer == address(0)) revert ZeroSigner(); // else a malformed sig recovering 0 would pass
        signer = _signer;
    }

    /// @param target       lane owner (bound into the signed digest).
    /// @param laneIndex    lane (bound into the signed digest).
    /// @param freshnessNow the registry's current clock value. We require the SIGNED freshness to
    ///                     equal it, pinning the report to the tick it lands in.
    /// @param aux          `abi.encode(uint256 signedFreshness, uint256 deadline, uint256 price, bytes signature)`.
    /// @return slots       `[signedFreshness, price]` — the 2-word layout the demo AMM reads.
    function validateAndUnpack(address target, uint256 laneIndex, uint256 freshnessNow, bytes calldata aux)
        external
        view
        override
        returns (uint256[] memory slots)
    {
        (uint256 signedFreshness, uint256 deadline, uint256 price, bytes memory sig) =
            abi.decode(aux, (uint256, uint256, uint256, bytes));

        // Bind the report to (this decoder, chainid, target, lane, freshness, deadline, price): a
        // signature for one lane, chain, tick, or price cannot be relayed onto another.
        bytes32 digest =
            keccak256(abi.encode(address(this), block.chainid, target, laneIndex, signedFreshness, deadline, price));
        bytes32 ethDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        address recovered = _recover(ethDigest, sig);
        if (recovered != signer) revert UntrustedSigner(recovered);

        // Defence 1: pin to the actual landing tick (the true clock value, not the calldata field).
        if (signedFreshness != freshnessNow) revert NotCurrentTick(signedFreshness, freshnessNow);
        // Defence 2: wall-clock cap — reject a report an includer delayed past its real-time deadline.
        if (block.timestamp > deadline) revert Expired(block.timestamp, deadline);

        slots = new uint256[](2);
        slots[0] = signedFreshness;
        slots[1] = price;
    }

    /// @dev Minimal ECDSA recovery (demo). `ecrecover` is a precompile — `view`/staticcall-safe.
    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) revert BadSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return ecrecover(digest, v, r, s);
    }
}

/// @notice A propAMM that consumes SIGNED oracle reports through the registry's CUSTOM path. It binds
///         a {SignedReportDecoder} to its lane; thereafter ANYONE may relay a validly-signed report
///         (the decoder is the authorization — an unsigned/stale/future/expired report cannot get in),
///         and the registry writes the decoded slots. Read side is identical to the low-gas demo.
///
///         Lifecycle:
///           1. deploy a {SignedReportDecoder} with the trusted signer.
///           2. deploy this contract with (registry, decoder) — the constructor binds the decoder to
///              {LANE} (immutable-once-set).
///           3. each tick a relayer (permissionless) calls
///                 `registry.updateStateWithDecoder(address(this), LANE, now,
///                      abi.encode(now, deadline, price, signature))`,
///              signed for the CURRENT tick with a wall-clock `deadline`. The registry range-checks
///              the field, STATICCALLs the decoder (which pins the tick AND enforces the deadline),
///              and stores `[now, price]`.
///           4. a swap calls {quote}; same same-tick lock as the low-gas demo.
contract OracleReportPropAMM {
    IPrioUpdateRegistryV2 public immutable registry;

    uint256 public constant LANE = 0;
    uint256 internal constant SLOTS = 2;

    error StaleQuote(uint256 fresh, uint256 nowRef);

    constructor(IPrioUpdateRegistryV2 _registry, address decoder) {
        registry = _registry;
        // This contract is the target; it binds its own verify/unpack decoder for LANE.
        registry.setDecoder(LANE, decoder);
    }

    /// @notice The current, same-tick-fresh price. Reverts unless a fresh update landed this tick. On
    ///         the custom path the decoder pinned it to the clock value AND enforced the wall-clock
    ///         deadline at write time, so this read proves the update was verified, current-tick, and
    ///         not delayed past its deadline.
    function currentPrice() public view returns (uint256 price) {
        uint256[] memory s = registry.getState(LANE, SLOTS);
        uint256 fresh = s[0];
        uint256 nowRef = registry.freshnessNow();
        if (fresh != nowRef) revert StaleQuote(fresh, nowRef);
        return s[1];
    }

    /// @notice Trivial swap quote using the fresh price (demo math only).
    function quote(uint256 amountIn) external view returns (uint256 amountOut) {
        return (amountIn * currentPrice()) / 1e18;
    }
}
