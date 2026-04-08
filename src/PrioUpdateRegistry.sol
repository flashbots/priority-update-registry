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
    error Slot0Exceeds28Bytes();
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
        uint256 s = _updaterSlot(target);
        uint256 val = uint256(uint160(updater));
        assembly {
            sstore(s, val)
        }
    }

    /*
     * State
     */

    /*
     * Returns the current block's state for `msg.sender` at the given `laneIndex`.
     * `numSlots` must be at least 1. Slot 0 freshness is checked via the packed timestamp.
     * Additional requested slots are returned as-is from storage, so callers must use the target's
     * configured fixed width. Shorter writes do not clear previously written tail slots.
     */
    function getState(uint256 laneIndex, uint256 numSlots) external view returns (uint256[] memory) {
        uint256 base = _laneSlot0Index(msg.sender, laneIndex);
        uint256 first;
        assembly {
            first := sload(base)
        }
        if (uint32(first >> 224) != uint32(block.timestamp)) revert StateNotUpdated();

        uint256[] memory result = new uint256[](numSlots);
        result[0] = uint224(first);
        for (uint256 i = 1; i < numSlots; i++) {
            assembly {
                mstore(add(add(result, 32), mul(i, 32)), sload(add(base, i)))
            }
        }
        return result;
    }

    /* Returns the authorized updater for `target`. */
    function getUpdater(address target) external view returns (address) {
        uint256 s = _updaterSlot(target);
        uint256 v;
        assembly {
            v := sload(s)
        }
        return address(uint160(v));
    }

    function _updaterSlot(address target) internal pure returns (uint256) {
        return (uint256(0x02) << 248) | uint256(uint160(target));
    }

    function _laneSlot0Index(address target, uint256 laneIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(target, laneIndex)));
    }

    function _writeState(
        address target,
        address updater,
        uint256 laneIndex,
        uint256 blockTimestamp,
        uint256 chainId,
        uint256[] calldata slots
    ) internal {
        if (blockTimestamp != block.timestamp) revert WrongTimestamp();
        if (chainId != block.chainid) revert WrongChainId();
        if (slots.length == 0) revert EmptySlots();
        if (slots[0] >> 224 != 0) revert Slot0Exceeds28Bytes();

        uint256 s = _updaterSlot(target);
        uint256 storedUpdater;
        assembly {
            storedUpdater := sload(s)
        }
        if (updater != address(uint160(storedUpdater))) revert NotAuthorized();

        uint256 base = _laneSlot0Index(target, laneIndex);
        uint256 first = (uint256(uint32(blockTimestamp)) << 224) | slots[0];
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
     * Writes a state update for `target` at `laneIndex` using `msg.sender` as the updater.
     */
    function updateState(address target, uint256 laneIndex, uint256 blockTimestamp, uint256[] calldata slots) external {
        _writeState(target, msg.sender, laneIndex, blockTimestamp, block.chainid, slots);
    }

    /*
     * Signed Update
     */

    bytes32 public constant UPDATE_TYPEHASH = keccak256(
        "UpdateState(address target,uint256 laneIndex,uint256 blockTimestamp,uint256 chainId,uint256[] slots)"
    );

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
        uint256 laneIndex;
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
                abi.encode(
                    UPDATE_TYPEHASH,
                    u.target,
                    u.laneIndex,
                    u.blockTimestamp,
                    u.chainId,
                    keccak256(abi.encodePacked(u.slots))
                )
            );
            address signer = ECDSA.recover(_hashTypedData(structHash), u.signature);
            _writeState(u.target, signer, u.laneIndex, u.blockTimestamp, u.chainId, u.slots);
        }
    }
}
