// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

contract OrderSettler {
    struct Call {
        address target;
        uint256 value;
        bytes callData;
    }

    function initiateSettle(address _poolHook, bytes32 _orderId, Call[] calldata calls) external {
        (bool success,) =
            _poolHook.call(abi.encodeWithSignature("settleOrder(bytes32,bytes)", _orderId, abi.encode(calls)));
        require(success);
    }

    function settleCallback(address, address tokenOut, bytes calldata _extraData) external {
        Call[] memory calls = abi.decode(_extraData, (Call[]));
        uint256 length = calls.length;

        // settle order via call execution
        for (uint256 i = 0; i < length;) {
            Call memory calli = calls[i];
            (bool success,) = calli.target.call(calli.callData);

            // Gas Optimized via Multicall3
            assembly {
                // Revert if the call fails and failure is not allowed
                // `allowFailure := calldataload(add(calli, 0x20))` and `success := mload(result)`
                if iszero(or(calldataload(add(calli, 0x20)), mload(success))) {
                    // set "Error(string)" signature: bytes32(bytes4(keccak256("Error(string)")))
                    mstore(0x00, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    // set data offset
                    mstore(0x04, 0x0000000000000000000000000000000000000000000000000000000000000020)
                    // set length of revert string
                    mstore(0x24, 0x0000000000000000000000000000000000000000000000000000000000000017)
                    // set revert string: bytes32(abi.encodePacked("Multicall3: call failed"))
                    mstore(0x44, 0x4d756c746963616c6c333a2063616c6c206661696c6564000000000000000000)
                    revert(0x00, 0x64)
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
