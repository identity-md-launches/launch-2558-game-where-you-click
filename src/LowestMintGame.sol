// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice One finite game: each entry buys IMD, and the smallest individual receipt wins the ETH pot.
/// @dev No NFT, randomness, oracle, administrative withdrawals, or new pool is involved.
contract LowestMintGame is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint256 public constant MINT_PRICE = 0.1 ether;
    uint256 public constant SWAP_AMOUNT = 0.08 ether;
    uint256 public constant REWARD_PER_MINT = MINT_PRICE - SWAP_AMOUNT;
    uint256 public constant MAX_MINTS = 100;
    uint256 public constant GAME_DURATION = 30 days;
    uint256 public constant AUTO_PAYOUT_GAS = 30_000;
    uint256 private constant PAYOUT_GAS_RESERVE = 100_000;

    struct MintRecord {
        address payer;
        uint256 tokensReceived;
    }

    IPoolManager public immutable poolManager;
    PoolKey public poolKey;
    uint256 public minimumOutput;
    bool public configured;

    uint256 public minted;
    uint256 public closesAt;
    mapping(uint256 mintId => MintRecord) public mints;
    mapping(address payer => uint256 count) public mintCountOf;
    mapping(address payer => uint256 amount) public totalTokensReceived;

    address public leader;
    uint256 public lowestTokens;
    uint256 public winningMintId;
    uint256 public rewardPool;
    uint256 public pendingReward;
    uint256 public totalRewardsPaid;
    bool public finalized;

    // A callback is authorized only inside this contract's own guarded mint. It is consumed once.
    address private callbackPayer;
    uint256 private callbackOutput;

    error InvalidManager();
    error NotConfigured();
    error ConfigurationLocked();
    error InvalidPool();
    error DependencyHasNoCode();
    error PoolNotInitialized();
    error InvalidMinimumOutput();
    error IncorrectPayment();
    error GameClosed();
    error DeadlineExpired();
    error UnauthorizedCallback();
    error CallbackNotCompleted();
    error InexactSwapInput(int128 actual);
    error InvalidSwapOutput();
    error InexactSettlement();
    error InexactTokenReceipt();
    error TooFewTokens(uint256 received, uint256 minimum);
    error NoEntries();
    error GameStillOpen();
    error AlreadyFinalized();
    error NotFinalized();
    error NotWinner();
    error NothingToClaim();
    error InvalidRecipient();
    error RewardTransferFailed();
    error DirectPaymentNotAllowed();

    event PoolConfigured(
        bytes32 indexed poolId, address indexed imd, uint24 fee, int24 tickSpacing, address hooks, uint256 minimumOutput
    );
    event GameStarted(uint256 closesAt);
    event Minted(uint256 indexed mintId, address indexed payer, uint256 tokensReceived);
    event LeaderChanged(uint256 indexed mintId, address indexed payer, uint256 tokensReceived);
    event GameFinalized(address indexed winner, uint256 indexed winningMintId, uint256 rewards, bool soldOut);
    event RewardPaid(address indexed winner, address indexed recipient, uint256 amount);
    event RewardDeferred(address indexed winner, uint256 amount);

    /// @param initialOwner The launch owner, explicitly supplied even when a factory deploys this contract.
    /// @param manager The verified Uniswap v4 PoolManager for the deployment chain.
    /// @dev No constructor external calls or code checks: deployment works on an empty chain.
    constructor(address initialOwner, IPoolManager manager) Ownable(initialOwner) {
        if (address(manager) == address(0)) revert InvalidManager();
        poolManager = manager;
    }

    /// @notice Configure the existing native ETH/IMD pool and a positive absolute output floor.
    /// @dev Replaceable only before the first successful mint. Hook data is always empty.
    function configurePool(PoolKey calldata key, uint256 minimumOutput_) external onlyOwner nonReentrant {
        if (minted != 0) revert ConfigurationLocked();
        if (minimumOutput_ == 0 || minimumOutput_ > uint256(uint128(type(int128).max))) {
            revert InvalidMinimumOutput();
        }
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)
                || Currency.unwrap(key.currency1) == address(this) || key.tickSpacing < TickMath.MIN_TICK_SPACING
                || key.tickSpacing > TickMath.MAX_TICK_SPACING
                || (key.fee > LPFeeLibrary.MAX_LP_FEE && key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG)
                || !Hooks.isValidHookAddress(key.hooks, key.fee)
        ) revert InvalidPool();
        if (
            address(poolManager).code.length == 0 || Currency.unwrap(key.currency1).code.length == 0
                || (address(key.hooks) != address(0) && address(key.hooks).code.length == 0)
        ) revert DependencyHasNoCode();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        poolKey = key;
        minimumOutput = minimumOutput_;
        configured = true;
        emit PoolConfigured(
            PoolId.unwrap(key.toId()),
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing,
            address(key.hooks),
            minimumOutput_
        );
    }

    /// @notice Buy an entry using the configured output floor. Send exactly 0.1 ETH.
    /// @dev Wallet integrations should prefer the overload with a quoted minimum and an expiry.
    function mint() external payable nonReentrant returns (uint256 mintId, uint256 tokensReceived) {
        return _mint(minimumOutput, type(uint256).max);
    }

    /// @notice Buy an entry with a tighter minimum and an inclusive transaction deadline.
    /// @dev A caller cannot weaken the configured floor. Amounts are raw IMD token units.
    function mint(uint256 minTokensReceived, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 mintId, uint256 tokensReceived)
    {
        if (minTokensReceived == 0) revert InvalidMinimumOutput();
        return _mint(minTokensReceived, deadline);
    }

    function _mint(uint256 minTokensReceived, uint256 deadline)
        private
        returns (uint256 mintId, uint256 tokensReceived)
    {
        if (!configured) revert NotConfigured();
        if (msg.value != MINT_PRICE) revert IncorrectPayment();
        if (finalized || minted == MAX_MINTS || (closesAt != 0 && block.timestamp >= closesAt)) revert GameClosed();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (minTokensReceived < minimumOutput) minTokensReceived = minimumOutput;

        callbackPayer = msg.sender;
        callbackOutput = 0;
        poolManager.unlock("");
        if (callbackPayer != address(0) || callbackOutput == 0) revert CallbackNotCompleted();
        tokensReceived = callbackOutput;
        callbackOutput = 0;
        if (tokensReceived < minTokensReceived) revert TooFewTokens(tokensReceived, minTokensReceived);

        // All pool/token interactions are complete; the reentrancy guard covered the whole swap.
        mintId = ++minted;
        if (mintId == 1) {
            closesAt = block.timestamp + GAME_DURATION;
            emit GameStarted(closesAt);
        }
        mints[mintId] = MintRecord(msg.sender, tokensReceived);
        ++mintCountOf[msg.sender];
        totalTokensReceived[msg.sender] += tokensReceived;
        rewardPool += REWARD_PER_MINT;
        emit Minted(mintId, msg.sender, tokensReceived);
        if (mintId == 1 || tokensReceived < lowestTokens) {
            leader = msg.sender;
            lowestTokens = tokensReceived;
            winningMintId = mintId;
            emit LeaderChanged(mintId, msg.sender, tokensReceived);
        }
        if (mintId == MAX_MINTS) _finalize();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || callbackPayer == address(0) || !_reentrancyGuardEntered()) {
            revert UnauthorizedCallback();
        }
        address payer = callbackPayer;
        callbackPayer = address(0);
        PoolKey memory key = poolKey;
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        // Reject partial fills and hook deltas that would spend a different amount of ETH.
        if (delta.amount0() != -int128(uint128(SWAP_AMOUNT))) revert InexactSwapInput(delta.amount0());
        if (delta.amount1() <= 0) revert InvalidSwapOutput();
        uint256 output = uint256(uint128(delta.amount1()));

        // A hook may have synced an ERC20; explicitly reset the settlement currency to native ETH.
        poolManager.sync(key.currency0);
        if (poolManager.settle{value: SWAP_AMOUNT}() != SWAP_AMOUNT) revert InexactSettlement();
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 beforeBalance = token.balanceOf(payer);
        poolManager.take(key.currency1, payer, output);
        uint256 afterBalance = token.balanceOf(payer);
        // Exact delivery prevents taxes, rebases or recipient callbacks from manufacturing a low score.
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != output) revert InexactTokenReceipt();
        callbackOutput = afterBalance - beforeBalance;
        return "";
    }

    /// @notice Anyone can close an unsold game at its deadline; the current leader receives its rewards.
    function finalize() external nonReentrant {
        if (finalized) revert AlreadyFinalized();
        if (minted == 0) revert NoEntries();
        if (minted < MAX_MINTS && block.timestamp < closesAt) revert GameStillOpen();
        _finalize();
    }

    function _finalize() private {
        finalized = true;
        uint256 amount = rewardPool;
        rewardPool = 0;
        pendingReward = amount;
        emit GameFinalized(leader, winningMintId, amount, minted == MAX_MINTS);

        // A rejecting or gas-consuming winner must not block the final mint or deadline settlement.
        if (gasleft() >= PAYOUT_GAS_RESERVE) {
            pendingReward = 0;
            (bool paid,) = payable(leader).call{value: amount, gas: AUTO_PAYOUT_GAS}("");
            if (paid) {
                totalRewardsPaid += amount;
                emit RewardPaid(leader, leader, amount);
                return;
            }
            pendingReward = amount;
        }
        emit RewardDeferred(leader, amount);
    }

    /// @notice The winning payer can redirect a deferred prize to an ETH-capable wallet.
    function claimRewards(address payable recipient) external nonReentrant {
        if (!finalized) revert NotFinalized();
        if (msg.sender != leader) revert NotWinner();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        uint256 amount = pendingReward;
        if (amount == 0) revert NothingToClaim();
        pendingReward = 0;
        totalRewardsPaid += amount;
        (bool paid,) = recipient.call{value: amount}("");
        if (!paid) revert RewardTransferFailed();
        emit RewardPaid(leader, recipient, amount);
    }

    receive() external payable {
        revert DirectPaymentNotAllowed();
    }
}
