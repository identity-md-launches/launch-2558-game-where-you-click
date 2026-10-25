// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LowestMintGame} from "../../src/LowestMintGame.sol";

/// @dev Test token only. All amounts in the game are raw units, independent of this token's decimals.
contract MockIMD is ERC20 {
    enum TransferMode {
        Normal,
        ReturnsFalse,
        NoReturn,
        Taxed,
        Bonus,
        Reverts
    }

    TransferMode public mode;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor() ERC20("Test IMD", "tIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(TransferMode mode_) external {
        mode = mode_;
    }

    function setReentry(address target, bytes memory data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(mode != TransferMode.Reverts, "token transfer reverted");
        if (mode == TransferMode.ReturnsFalse) return false;
        _transfer(msg.sender, to, amount);
        if (mode == TransferMode.Taxed) _burn(to, amount / 10);
        if (mode == TransferMode.Bonus) _mint(to, 1);
        if (reentryTarget != address(0)) {
            (reentrySucceeded, reentryResult) = reentryTarget.call(reentryData);
        }
        if (mode == TransferMode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}

/// @dev Controlled unit-test double; real PoolManager integration is covered separately.
contract MockPoolManager {
    int128 public output = 1000;
    int128 public input = 0.08 ether;
    bool public initialized = true;
    bool public skipCallback;
    bool public doubleCallback;
    bool public failSwap;
    bool public wrongSettlement;
    bool public syncedNative;
    uint256 public swapCalls;
    uint256 public settled;
    bytes32 public lastPoolId;
    bool public lastZeroForOne;
    int256 public lastAmountSpecified;
    uint160 public lastPriceLimit;
    uint256 public lastHookDataLength;

    function setOutput(int128 amount) external {
        output = amount;
    }

    function setInput(int128 amount) external {
        input = amount;
    }

    function setInitialized(bool value) external {
        initialized = value;
    }

    function setCallbackMode(bool skip, bool twice) external {
        skipCallback = skip;
        doubleCallback = twice;
    }

    function setFailSwap(bool value) external {
        failSwap = value;
    }

    function setWrongSettlement(bool value) external {
        wrongSettlement = value;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return initialized ? bytes32(uint256(1)) : bytes32(0);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (skipCallback) return "";
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (doubleCallback) IUnlockCallback(msg.sender).unlockCallback(data);
        return result;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        require(!failSwap, "swap failed");
        swapCalls++;
        lastPoolId = keccak256(abi.encode(key));
        lastZeroForOne = params.zeroForOne;
        lastAmountSpecified = params.amountSpecified;
        lastPriceLimit = params.sqrtPriceLimitX96;
        lastHookDataLength = hookData.length;
        return toBalanceDelta(-input, output);
    }

    function sync(Currency currency) external {
        syncedNative = Currency.unwrap(currency) == address(0);
    }

    function settle() external payable returns (uint256) {
        require(syncedNative, "must sync native");
        syncedNative = false;
        settled += msg.value;
        return wrongSettlement ? msg.value - 1 : msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external {
        (bool success, bytes memory data) =
            Currency.unwrap(currency).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "token transfer failed");
    }
}

contract PlayerWallet {
    enum ReceiveMode {
        Accept,
        Reject,
        BurnGas,
        Reenter
    }

    LowestMintGame public game;
    ReceiveMode public receiveMode;
    uint256 public payouts;

    constructor(LowestMintGame game_) {
        game = game_;
    }

    function setReceiveMode(ReceiveMode mode) external {
        receiveMode = mode;
    }

    function enter() external payable {
        game.mint{value: msg.value}();
    }

    function claim(address payable to) external {
        game.claimRewards(to);
    }

    receive() external payable {
        if (receiveMode == ReceiveMode.Reject) revert("no ETH");
        if (receiveMode == ReceiveMode.BurnGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (receiveMode == ReceiveMode.Reenter) {
            (bool success,) = address(game).call(abi.encodeCall(game.claimRewards, (payable(address(this)))));
            require(!success, "reentrant claim succeeded");
        }
        payouts++;
    }
}
