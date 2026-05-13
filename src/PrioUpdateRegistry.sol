// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

contract PrioUpdateRegistry is EIP712 {
    error NotAuthorized();
    error WrongTimestamp();
    error EmptySlots();
    error Slot0Exceeds27Bytes();
    error TooManySlots();
    error StateNotUpdated();

    event UpdaterAdded(address indexed target, address indexed updater);
    event UpdaterRemoved(address indexed target, address indexed updater);

    /* Authorized updaters per target. The target itself manages its updaters. */
    mapping(address target => mapping(address updater => bool)) public isUpdater;

    /*
     * Authorizes `updater` to write state for `msg.sender`.
     */
    function addUpdater(address updater) external {
        if (isUpdater[msg.sender][updater]) return;
        isUpdater[msg.sender][updater] = true;
        emit UpdaterAdded(msg.sender, updater);
    }

    /*
     * Revokes authorization for `updater` to write state for `msg.sender`.
     */
    function removeUpdater(address updater) external {
        if (!isUpdater[msg.sender][updater]) return;
        isUpdater[msg.sender][updater] = false;
        emit UpdaterRemoved(msg.sender, updater);
    }

    /*
     * State
     */

    /*
     * Returns the current block's state for `msg.sender` at the given `laneIndex`.
     * Slot 0 freshness is checked via the packed timestamp.
     * The number of slots returned matches the number that were written.
     */
    function getState(uint256 laneIndex) external view returns (uint256[] memory) {
        uint256 base = _laneSlot0Index(msg.sender, laneIndex);
        uint256 first;
        assembly {
            first := sload(base)
        }
        if (uint32(first >> 224) != uint32(block.timestamp)) revert StateNotUpdated();

        uint256 numSlots = uint8(first >> 216);
        uint256[] memory result = new uint256[](numSlots);
        result[0] = uint216(first);
        for (uint256 i = 1; i < numSlots; i++) {
            assembly {
                mstore(add(add(result, 32), mul(i, 32)), sload(add(base, i)))
            }
        }
        return result;
    }

    function _laneSlot0Index(address target, uint256 laneIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(target, laneIndex)));
    }

    function _writeState(
        address target,
        address updater,
        uint256 laneIndex,
        uint256 blockTimestamp,
        uint256[] calldata slots
    ) internal {
        if (blockTimestamp != block.timestamp) revert WrongTimestamp();
        if (slots.length == 0) revert EmptySlots();
        if (slots.length > 255) revert TooManySlots();
        if (slots[0] >> 216 != 0) revert Slot0Exceeds27Bytes();

        if (!isUpdater[target][updater]) revert NotAuthorized();

        uint256 base = _laneSlot0Index(target, laneIndex);
        uint256 first = (uint256(uint32(blockTimestamp)) << 224) | (slots.length << 216) | slots[0];
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
        _writeState(target, msg.sender, laneIndex, blockTimestamp, slots);
    }

    /*
     * Signed Update
     */

    bytes32 public constant UPDATE_TYPEHASH = keccak256(
        "UpdateState(address target,uint256 laneIndex,uint256 blockTimestamp,uint256[] slots)"
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
                    keccak256(abi.encodePacked(u.slots))
                )
            );
            address signer = ECDSA.recover(_hashTypedData(structHash), u.signature);
            _writeState(u.target, signer, u.laneIndex, u.blockTimestamp, u.slots);
        }
    }
}
