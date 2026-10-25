// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Test-only hook installed with vm.etch at a permission-bearing address.
contract SwapHook {
    IPoolManager public immutable manager;
    bool public reentrySucceeded;
    bytes public reentryError;
    address public observedSender;
    uint256 public hookDataLength;
    bool public rejectSwap;
    uint24 public feeOverride;
    uint128 public outputFee;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function setReject(bool reject) external {
        rejectSwap = reject;
    }

    function setFeeOverride(uint24 fee) external {
        feeOverride = fee;
    }

    function setOutputFee(uint128 fee) external {
        outputFee = fee;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager), "not manager");
        require(!rejectSwap, "hook refused swap");
        observedSender = sender;
        hookDataLength = hookData.length;
        // This transient sync state must not poison the game's subsequent native settlement.
        manager.sync(key.currency1);
        (reentrySucceeded, reentryError) = sender.call(abi.encodeWithSignature("mint()"));
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), feeOverride);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(manager), "not manager");
        if (outputFee != 0) manager.take(key.currency1, address(this), outputFee);
        return (IHooks.afterSwap.selector, int128(outputFee));
    }
}
