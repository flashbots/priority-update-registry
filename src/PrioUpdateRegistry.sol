// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

contract PrioUpdateRegistry is EIP712 {
    error NotAdmin();
    error NotAuthorized();
    error WrongTimestamp();
    error WrongChainId();
    error EmptySlots();
    error Slot0Exceeds8Bytes();
    error StateNotUpdated();

    /*
     * Admin methods
     */
    /* Admin that can assign updaters and transfer admin rights. */
    address public admin;

    constructor() {
        admin = msg.sender;
    }

    /* Transfers admin rights to `newAdmin`. */
    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert NotAdmin();
        admin = newAdmin;
    }

    /*
     * Sets the authorized updater for `target`.
     */
    function setUpdater(address target, address updater) external {
        if (msg.sender != admin) revert NotAdmin();
        uint256 s = _slot(target, 0);
        uint256 val = uint256(uint160(updater)) << 64;
        assembly {
            sstore(s, val)
        }
    }

    /*
     * State
     */

    /*
     * Returns the current block's state for `msg.sender`.
     * `numSlots` must be at least 1. Slot 0 freshness is checked via the packed timestamp.
     * Additional requested slots are returned as-is from storage, so callers must use the target's
     * configured fixed width. Shorter writes do not clear previously written tail slots.
     */
    function getState(uint256 numSlots) external view returns (uint256[] memory) {
        uint256 base = _slot(msg.sender, 0);
        uint256 first;
        assembly {
            first := sload(base)
        }
        if (uint32(first >> 224) != uint32(block.timestamp)) revert StateNotUpdated();

        uint256[] memory result = new uint256[](numSlots);
        result[0] = uint64(first);
        for (uint256 i = 1; i < numSlots; i++) {
            assembly {
                mstore(add(add(result, 32), mul(i, 32)), sload(add(base, i)))
            }
        }
        return result;
    }

    /* Returns the authorized updater for `target`. */
    function getUpdater(address target) external view returns (address) {
        uint256 s = _slot(target, 0);
        uint256 v;
        assembly {
            v := sload(s)
        }
        return address(uint160(v >> 64));
    }

    function _slot(address target, uint256 index) internal pure returns (uint256) {
        return (uint256(0xcc) << 248) | (uint256(uint160(target)) << 88) | index;
    }

    function _writeState(
        address target,
        address updater,
        uint256 blockTimestamp,
        uint256 chainId,
        uint256[] calldata slots
    ) internal {
        if (blockTimestamp != block.timestamp) revert WrongTimestamp();
        if (chainId != block.chainid) revert WrongChainId();
        if (slots.length == 0) revert EmptySlots();
        if (slots[0] >> 64 != 0) revert Slot0Exceeds8Bytes();

        uint256 base = _slot(target, 0);
        uint256 first;
        assembly {
            first := sload(base)
        }
        if (updater != address(uint160(first >> 64))) revert NotAuthorized();

        first = (uint256(uint32(blockTimestamp)) << 224) | (uint256(uint160(updater)) << 64) | slots[0];
        assembly {
            sstore(base, first)
        }
        for (uint256 i = 1; i < slots.length; i++) {
            assembly {
                sstore(add(base, i), calldataload(add(slots.offset, mul(i, 32))))
            }
        }
    }

    /*
     * Writes a state update for `target` using `msg.sender` as the updater.
     */
    function updateState(address target, uint256 blockTimestamp, uint256[] calldata slots) external {
        _writeState(target, msg.sender, blockTimestamp, block.chainid, slots);
    }

    /*
     * Signed Update
     */

    bytes32 public constant UPDATE_TYPEHASH =
        keccak256("UpdateState(address target,uint256 blockTimestamp,uint256 chainId,uint256[] slots)");

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "PrioUpdateRegistry";
        version = "1";
    }

    /* Returns the EIP-712 domain separator for signed updates. */
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    struct SignedUpdate {
        address target;
        uint256 blockTimestamp;
        uint256 chainId;
        uint256[] slots;
        bytes signature;
    }

    /*
     * Applies a batch of signed updates.
     * Anyone may relay the batch. Each update is validated independently and the whole call
     * reverts on the first invalid signature or invalid input.
     */
    function batchUpdateStateWithSignature(SignedUpdate[] calldata updates) external {
        for (uint256 i = 0; i < updates.length; i++) {
            SignedUpdate calldata u = updates[i];
            bytes32 structHash = keccak256(
                abi.encode(UPDATE_TYPEHASH, u.target, u.blockTimestamp, u.chainId, keccak256(abi.encodePacked(u.slots)))
            );
            address signer = ECDSA.recover(_hashTypedData(structHash), u.signature);
            _writeState(u.target, signer, u.blockTimestamp, u.chainId, u.slots);
        }
    }
}
