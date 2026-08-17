// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  IPrioUpdateDecoder — the custom-path verify/unpack hook
/// @notice A per-lane hook that verifies and unpacks an arbitrary payload into the words the registry
///         stores. It is reached ONLY via `STATICCALL` ({PrioUpdateRegistryV2.updateStateWithDecoder}),
///         so arbitrary decoder code cannot `SSTORE` / `LOG` / move value / `CREATE` / `SELFDESTRUCT`
///         — the registry performs the only write, into its own storage. This is what preserves
///         write-scoping for a programmable decoder.
interface IPrioUpdateDecoder {
    /// @notice Verify `aux` and return the words to store for `(target, laneIndex)`. Revert to reject.
    /// @dev    MUST be `view` (invoked via `STATICCALL`); a non-view body or any nested write reverts.
    ///         Verification must be `view` and fee-less (a `STATICCALL` cannot pay), e.g. a DON
    ///         `verifyView` or `ecrecover` + trusted-signer check. Freshness: bind the payload to
    ///         `freshnessNow` (the current tick — an includer cannot shift it to another block/tick).
    ///         On a block-number clock that pins the BLOCK but not wall-clock time, so a decoder that
    ///         must bound real-time staleness against an includer who DELAYS inclusion should ALSO
    ///         check `block.timestamp <= deadline` with a maker-signed deadline (see the demo).
    /// @param target      the lane owner (bind the payload to it — one decoder may serve many targets).
    /// @param laneIndex   the lane (bind to it — one decoder may serve many lanes).
    /// @param freshnessNow the registry's current {PrioUpdateRegistryV2.freshnessNow} — the chain
    ///                    clock, NOT the caller's calldata field. Binding `signed == freshnessNow`
    ///                    pins the report to the tick it lands in (closes replay / early-install).
    /// @param aux         the opaque payload to verify + unpack.
    /// @return slots      the words to store, in lane order; length must be in [1, MAX_SLOTS].
    function validateAndUnpack(address target, uint256 laneIndex, uint256 freshnessNow, bytes calldata aux)
        external
        view
        returns (uint256[] memory slots);
}

/// @title  Priority Update Registry (v2)
/// @author Flashbots
/// @notice A shared singleton for *priority updates*: small per-block state an off-chain updater
///         refreshes top-of-block so later transactions in the same block read fresh values (e.g. an
///         actively-managed on-chain curve re-quoting once per block before it is traded against).
///
///         WRITE-SCOPING (the load-bearing property): a tx whose `to` is this registry can only ever
///         write THIS registry's storage, knowable from the destination address ALONE without
///         simulation — which is what lets builders place these updates top-of-block. The only
///         external interaction is the read-only `STATICCALL` to a decoder; nothing here writes
///         foreign storage, moves value, `CREATE`s, or `SELFDESTRUCT`s.
///
///         Changes from v1 (full rationale in the PR):
///          1. Freshness is validated against an OVERRIDABLE chain-native clock {freshnessNow}
///             (default `block.timestamp` — the L1 answer) rather than a fixed clock. The right clock
///             is chain-dependent; override it per deployment (see {freshnessNow} for the threat
///             model and the per-chain criterion). `uint256`, calldata-only, never stored.
///          2. The freshness field is CALLDATA-ONLY and NOT stored: range-checked on write (builder-
///             legible ordering + a staleness band) then discarded. Read-side staleness is the
///             consumer's own policy, held in its data — matching how signed-oracle consumers gate.
///          3. Storage is RAW: just the caller's words, full 32-byte slots, no header, in a
///             domain-separated {_laneBase} region bounded to {MAX_SLOTS} (v1 stole 5 bytes of slot0).
///          4. Two write paths: {updateState} (lean, verbatim, no external call — the ~99% case) and
///             {updateStateWithDecoder} (STATICCALLs a registered decoder; only this path pays it).
///          5. {getSlot} — single-word read alongside whole-lane {getState}.
contract PrioUpdateRegistryV2 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `target` authorized `updater` for its low-gas ({updateState}) path.
    event UpdaterAdded(address indexed target, address indexed updater);
    /// @notice `target` revoked `updater` from its low-gas path.
    event UpdaterRemoved(address indexed target, address indexed updater);
    /// @notice `target` bound `decoder` to `laneIndex` (immutable once set — see {setDecoder}).
    event DecoderSet(address indexed target, uint256 indexed laneIndex, address indexed decoder);

    // Writes emit no event (v1 behaviour, keeps the hot path cheap); an optional inclusion-signal
    // event for custom lanes is left to the proposal discussion.

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `msg.sender` is not an authorized updater of `target`.
    error NotAuthorized();
    /// @notice A write supplied zero slots.
    error EmptySlots();
    /// @notice A write / decoder return exceeded {MAX_SLOTS} words.
    error TooManySlots();
    /// @notice A read requested a slot at or beyond {MAX_SLOTS} (out of any lane's range).
    error SlotIndexOutOfRange();
    /// @notice The decoder returned no slots.
    error DecoderReturnedNoSlots();
    /// @notice A decoder is already bound to this lane (immutable-once-set).
    error DecoderAlreadySet();
    /// @notice No decoder is bound to this lane; the custom path requires one.
    error DecoderNotSet();
    /// @notice The low-gas path was used on a decoder-bound lane — use the custom path.
    error DecoderBoundLane();
    /// @notice A zero decoder address was supplied to {setDecoder}.
    error ZeroDecoder();
    /// @notice The decoder has no code — binding it would brick the lane (staticcall to an EOA returns
    ///         empty data, so every update would revert on decode).
    error DecoderHasNoCode();
    /// @notice `freshness` is older than {freshnessNow} by more than {MAX_AGE} (in the clock's units).
    error FreshnessTooOld(uint256 freshness, uint256 nowRef);
    /// @notice `freshness` is further ahead of {freshnessNow} than {MAX_LEAD} (in the clock's units).
    error FreshnessTooFarAhead(uint256 freshness, uint256 nowRef);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Max words a lane may hold / a read may request. Bounds each lane to `[base, base+255)`;
    ///         with the domain-separated {_laneBase} this is what keeps reads/writes inside a lane's
    ///         own region — an unbounded offset would otherwise address any storage slot. 255 = v1 cap.
    uint256 internal constant MAX_SLOTS = 255;

    /// @dev Domain tag in every lane base. Mapping value slots are `keccak256(key ‖ slot)` (2 words);
    ///      lane bases are `keccak256(tag ‖ target ‖ laneIndex)` (3 words), so a lane base cannot equal
    ///      a mapping slot (preimage lengths differ), and landing within {MAX_SLOTS} of one needs a
    ///      keccak grind. Without the tag, `keccak256(target ‖ laneIndex)` collides with
    ///      `isUpdater[victim][attacker]` at `laneIndex = keccak256(abi.encode(victim, 0))`.
    bytes32 private constant LANE_NAMESPACE = keccak256("PrioUpdateRegistryV2.lane.v1");

    /*//////////////////////////////////////////////////////////////
                            FRESHNESS WINDOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Max the `freshness` field may lag {freshnessNow} and still be accepted, in the clock's
    ///         units (0 = must be the current tick or newer).
    /// @dev    Per-deployment. The WRITE-side band on the calldata field: bounds how far a write's
    ///         claimed freshness can trail reality (builder-legibility + a staleness cap). It is NOT
    ///         the custom path's replay/deadline defence — that is the decoder. Units follow the
    ///         chosen {freshnessNow} clock (seconds by default; blocks if overridden); pick per chain.
    // slither-disable-next-line naming-convention
    uint256 public immutable MAX_AGE;

    /// @notice Max the `freshness` field may lead {freshnessNow} (0 = may not be ahead).
    /// @dev    A lead gives a pusher slack (submit for tick N while N-1 lands). A >0 lead lets the
    ///         (trusted) updater pre-stamp a future tick, so strict "landed this tick" needs lead 0.
    ///         CANONICAL deployment = lead 0; a non-zero lead is a per-lane opt-in.
    // slither-disable-next-line naming-convention
    uint256 public immutable MAX_LEAD;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice target => updater => allowed. Low-gas path only; each target manages its own set. The
    ///         custom path is authorized by its decoder instead.
    mapping(address target => mapping(address updater => bool)) public isUpdater;

    /// @notice target => laneIndex => decoder. A non-zero entry marks a CUSTOM lane (low-gas writes are
    ///         refused; use {updateStateWithDecoder}). Immutable once set (see {setDecoder}).
    mapping(address target => mapping(uint256 laneIndex => address decoder)) public laneDecoder;

    // Lane data is not in a mapping: each lane's words live at `_laneBase(target, laneIndex) + i`, a
    // keccak region provably disjoint from the mappings above ({LANE_NAMESPACE}). Raw — no header.

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param maxAge  {MAX_AGE} (chain-specific, in {freshnessNow} units — seconds by default).
    /// @param maxLead {MAX_LEAD} (chain-specific; canonical 0).
    constructor(uint256 maxAge, uint256 maxLead) {
        MAX_AGE = maxAge;
        MAX_LEAD = maxLead;
    }

    /*//////////////////////////////////////////////////////////////
                       AUTHORIZATION / REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorize `updater` for the caller's low-gas writes. Caller is the target. Idempotent.
    function addUpdater(address updater) external {
        isUpdater[msg.sender][updater] = true;
        emit UpdaterAdded(msg.sender, updater);
    }

    /// @notice Revoke `updater` from the caller's low-gas writes. Caller is the target. Idempotent.
    function removeUpdater(address updater) external {
        isUpdater[msg.sender][updater] = false;
        emit UpdaterRemoved(msg.sender, updater);
    }

    /// @notice Bind `decoder` to the caller's `laneIndex`, making it a custom lane. Caller is the target.
    /// @dev    IMMUTABLE-ONCE-SET so readers can rely on a vetted lane's verification (deploy a new lane
    ///         to change it). Requires code (an EOA would brick the lane); note this cannot stop a
    ///         PROXY decoder from changing behaviour, so a consumer relying on immutability should vet
    ///         that the bound decoder's logic is itself immutable.
    function setDecoder(uint256 laneIndex, address decoder) external {
        if (decoder == address(0)) revert ZeroDecoder();
        if (decoder.code.length == 0) revert DecoderHasNoCode();
        if (laneDecoder[msg.sender][laneIndex] != address(0)) revert DecoderAlreadySet();
        laneDecoder[msg.sender][laneIndex] = decoder;
        emit DecoderSet(msg.sender, laneIndex, decoder);
    }

    /*//////////////////////////////////////////////////////////////
                          WRITE PATH 1 — LOW GAS
    //////////////////////////////////////////////////////////////*/

    /// @notice LOW-GAS write: store `slots` verbatim for `(target, laneIndex)`. No external call.
    /// @dev    Caller must be an authorized updater of `target`, and the lane must not be decoder-bound
    ///         (else a verbatim write would bypass that lane's verification — hence the second SLOAD).
    ///         `freshness` is range-checked against {freshnessNow} then discarded (calldata-only).
    /// @param slots the words to store, slot 0..n-1 (1 <= n <= MAX_SLOTS).
    function updateState(address target, uint256 laneIndex, uint256 freshness, uint256[] calldata slots) external {
        if (!isUpdater[target][msg.sender]) revert NotAuthorized();
        if (laneDecoder[target][laneIndex] != address(0)) revert DecoderBoundLane();
        _checkFreshness(freshness);
        _writeSlotsCalldata(target, laneIndex, slots);
    }

    /*//////////////////////////////////////////////////////////////
                        WRITE PATH 2 — CUSTOM DECODER
    //////////////////////////////////////////////////////////////*/

    /// @notice CUSTOM write: `STATICCALL` the lane's decoder to verify + unpack `aux`, store its slots.
    /// @dev    PERMISSIONLESS — the decoder is the authorization (it verifies `aux` and reverts on
    ///         anything it rejects), so anyone may relay a validly-signed report. The decoder is handed
    ///         {freshnessNow} so it can pin the report to the tick it lands in — the `freshness` window
    ///         alone does not stop replay of an old-but-in-window report under permissionless relay.
    ///         Runs under `STATICCALL`, so write-scoping holds; a buggy decoder's blast radius is the
    ///         target's own lane and it cannot be repointed (immutable binding).
    /// @param freshness caller-supplied freshness; range-checked, not stored (builder field).
    /// @param aux       the payload the decoder verifies + unpacks.
    function updateStateWithDecoder(address target, uint256 laneIndex, uint256 freshness, bytes calldata aux) external {
        address decoder = laneDecoder[target][laneIndex];
        if (decoder == address(0)) revert DecoderNotSet();
        uint256 nowRef = _checkFreshness(freshness);

        // STATICCALL (solc lowers a `view` external call to it): the decoder cannot write / log / move
        // value / create / selfdestruct. It gets the true clock value (not the calldata field) to pin
        // freshness. The registry does the only write, below.
        uint256[] memory slots = IPrioUpdateDecoder(decoder).validateAndUnpack(target, laneIndex, nowRef, aux);

        _writeSlotsMemory(target, laneIndex, slots);
    }

    /*//////////////////////////////////////////////////////////////
                                 READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Read word `slotIndex` of the CALLER's lane `laneIndex` (0 if never written).
    /// @dev    SELF-SCOPED to `msg.sender`. The EVM has no cross-contract `SLOAD`, so this plus the
    ///         {MAX_SLOTS} bound (keeping `base + slotIndex` in the caller's own region) means a lane is
    ///         only readable on-chain by its owner. A gated feed fronts its lane with its own contract
    ///         (the owner) and exposes what it chooses; a self-consuming maker reads from its swap path.
    ///         (Off-chain callers read storage directly — this scoping is an on-chain property.)
    function getSlot(uint256 laneIndex, uint256 slotIndex) external view returns (uint256 value) {
        if (slotIndex >= MAX_SLOTS) revert SlotIndexOutOfRange();
        uint256 slot = _laneBase(msg.sender, laneIndex) + slotIndex;
        assembly {
            value := sload(slot)
        }
    }

    /// @notice Read the first `count` words of the CALLER's lane `laneIndex`.
    /// @dev    SELF-SCOPED (see {getSlot}); `count` is bounded by {MAX_SLOTS}. RAW-STORAGE CAVEAT: lane
    ///         length is not stored, so the reader supplies `count` (a fixed-shape feed passes its known
    ///         length). A shorter write does not clear words left by a longer earlier one, so a
    ///         variable-length feed must encode its own length; this is the one bookkeeping cost of
    ///         header-free slots.
    function getState(uint256 laneIndex, uint256 count) external view returns (uint256[] memory slots) {
        if (count > MAX_SLOTS) revert SlotIndexOutOfRange();
        uint256 base = _laneBase(msg.sender, laneIndex);
        slots = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            uint256 slot = base + i;
            uint256 v;
            assembly {
                v := sload(slot)
            }
            slots[i] = v;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          FRESHNESS CLOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice The chain-native clock the `freshness` field is validated against and that a decoder
    ///         binds to. Defaults to `block.timestamp` (the L1 answer); OVERRIDE PER DEPLOYMENT to the
    ///         local clock that fits the chain. Consumers gate their read-side staleness against this
    ///         SAME value.
    /// @dev    Threat model: a malicious builder / sequencer chooses which update to include and can
    ///         influence timing (delay production, reorder). Its move is to include the OLDEST update
    ///         that still passes {_checkFreshness}, so swaps execute against a stale price. The clock
    ///         must therefore be the local value that includer can inflate LEAST, judged against how
    ///         fast the market moves:
    ///          - a clock's per-tick gameability ≈ the block time: an includer that delays a block by
    ///            one slot adds that much hidden wall-clock staleness while the block COUNT is
    ///            unchanged. On ~12s L1 that is up to a full slot; on a sub-second chain it is a
    ///            fraction of a second — relatively small, though not negligible for latency-sensitive
    ///            flow.
    ///          - `block.timestamp` grows with real delay (so it caps wall-clock staleness) but its
    ///            resolution is seconds — too coarse to distinguish sub-second blocks.
    ///         => use the FINEST local clock whose per-tick gameability is small relative to market
    ///            speed. This registry DEFAULTS to `block.timestamp` — right on ~12s L1, where
    ///            block-number age is inflatable a full slot per missed slot. Override to `block.number`
    ///            on sub-second chains (e.g. BSC, where a seconds timestamp cannot even separate blocks),
    ///            and to `ArbSys(0x64).arbBlockNumber()` on Arbitrum/Orbit (where `block.number` is the
    ///            coarse ~L1 number; ~2.6k-gas precompile).
    ///         MUST read only LOCAL / precompile values (`block.number`, `block.timestamp`, a chain
    ///         precompile) — never external contract state, or a builder can no longer tell an update
    ///         is valid from the `to` address alone without simulation (the write-scoping premise).
    ///         Residual limit: where the includer also controls the clock (a centralized-sequencer L2
    ///         sets both block production and `block.timestamp` within L1-anchoring bounds), no
    ///         on-chain clock fully constrains it; the bound shrinks to the clock-slack consensus
    ///         permits. A stable cross-chain address (CREATE3) despite the override is a deployment
    ///         concern, out of scope here.
    function freshnessNow() public view virtual returns (uint256) {
        return block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Require `freshness` in [now - MAX_AGE, now + MAX_LEAD] where now = {freshnessNow}; return
    ///      now (computed once). Subtraction only (never `now + LEAD`) so a large band cannot overflow.
    ///      VIRTUAL: a deployment may override for non-window semantics (e.g. a combined block-number +
    ///      `block.timestamp`-deadline check). Must stay `view` and read only local/precompile values
    ///      (see {freshnessNow}).
    function _checkFreshness(uint256 freshness) internal view virtual returns (uint256 nowRef) {
        nowRef = freshnessNow();
        if (freshness < nowRef) {
            if (nowRef - freshness > MAX_AGE) revert FreshnessTooOld(freshness, nowRef);
        } else if (freshness > nowRef) {
            if (freshness - nowRef > MAX_LEAD) revert FreshnessTooFarAhead(freshness, nowRef);
        }
    }

    /// @dev Base storage slot of `(target, laneIndex)`, domain-separated so its 3-word preimage cannot
    ///      alias a 2-word mapping slot ({LANE_NAMESPACE}). Words are at base + i, 0 <= i < MAX_SLOTS.
    function _laneBase(address target, uint256 laneIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(LANE_NAMESPACE, target, laneIndex)));
    }

    /// @dev Store calldata `slots` verbatim at the lane base. Reverts on empty / over-length.
    function _writeSlotsCalldata(address target, uint256 laneIndex, uint256[] calldata slots) internal {
        uint256 n = slots.length;
        if (n == 0) revert EmptySlots();
        if (n > MAX_SLOTS) revert TooManySlots();
        uint256 base = _laneBase(target, laneIndex);
        assembly {
            let off := slots.offset
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                sstore(add(base, i), calldataload(add(off, mul(i, 0x20))))
            }
        }
    }

    /// @dev Store memory `slots` (from a decoder) verbatim at the lane base. Reverts on empty (a decoder
    ///      returning nothing is a rejection) / over-length.
    function _writeSlotsMemory(address target, uint256 laneIndex, uint256[] memory slots) internal {
        uint256 n = slots.length;
        if (n == 0) revert DecoderReturnedNoSlots();
        if (n > MAX_SLOTS) revert TooManySlots();
        uint256 base = _laneBase(target, laneIndex);
        for (uint256 i; i < n; ++i) {
            uint256 v = slots[i];
            uint256 slot = base + i;
            assembly {
                sstore(slot, v)
            }
        }
    }
}
