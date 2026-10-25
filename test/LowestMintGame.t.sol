// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture} from "./helpers/GameFixture.sol";
import {LowestMintGame} from "../src/LowestMintGame.sol";
import {MockIMD, PlayerWallet} from "./helpers/Mocks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LowestMintGameTest is GameFixture {
    function test_factoryDeploymentAssignsExplicitOwnerWithoutDependencyCode() public {
        address emptyManager = makeAddr("empty manager");
        vm.prank(makeAddr("factory"), makeAddr("launch wallet"));
        LowestMintGame deployed = new LowestMintGame(owner, IPoolManager(emptyManager));
        assertEq(deployed.owner(), owner);
        assertEq(address(deployed.poolManager()), emptyManager);
        assertFalse(deployed.configured());
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.DependencyHasNoCode.selector);
        deployed.configurePool(key, 100);
    }

    function test_constructorRejectsZeroOwnerAndManager() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LowestMintGame(address(0), IPoolManager(address(manager)));
        vm.expectRevert(LowestMintGame.InvalidManager.selector);
        new LowestMintGame(owner, IPoolManager(address(0)));
    }

    function test_mintFailsUntilConfigured() public {
        LowestMintGame unconfigured = new LowestMintGame(owner, IPoolManager(address(manager)));
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.NotConfigured.selector);
        unconfigured.mint{value: PRICE}();
        vm.prank(owner);
        unconfigured.configurePool(key, 100);
        vm.prank(alice);
        unconfigured.mint{value: PRICE}();
        assertEq(unconfigured.minted(), 1);
    }

    function test_configurationRequiresOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        game.configurePool(key, 100);
    }

    function test_configurationCanBeCorrectedBeforeFirstMintAndLocksAfterward() public {
        vm.prank(owner);
        game.configurePool(key, 200);
        assertEq(game.minimumOutput(), 200);
        _mint(alice, 1000);
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.ConfigurationLocked.selector);
        game.configurePool(key, 100);
    }

    function test_configurationRejectsZeroOrUnreachableFloor() public {
        vm.startPrank(owner);
        vm.expectRevert(LowestMintGame.InvalidMinimumOutput.selector);
        game.configurePool(key, 0);
        vm.expectRevert(LowestMintGame.InvalidMinimumOutput.selector);
        game.configurePool(key, uint256(uint128(type(int128).max)) + 1);
        vm.stopPrank();
    }

    function test_configurationRejectsWrongCurrenciesAndSpacing() public {
        PoolKey memory wrong = key;
        wrong.currency0 = Currency.wrap(address(token));
        _expectBadPool(wrong);
        wrong = key;
        wrong.currency1 = Currency.wrap(address(0));
        _expectBadPool(wrong);
        wrong = key;
        wrong.currency1 = Currency.wrap(address(game));
        _expectBadPool(wrong);
        wrong = key;
        wrong.tickSpacing = 0;
        _expectBadPool(wrong);
        wrong.tickSpacing = -1;
        _expectBadPool(wrong);
        wrong.tickSpacing = 32768;
        _expectBadPool(wrong);
    }

    function test_configurationRejectsInvalidFeeAndHooks() public {
        PoolKey memory wrong = key;
        wrong.fee = 1_000_001;
        _expectBadPool(wrong);
        wrong.fee = 0x800001;
        _expectBadPool(wrong);
        wrong.fee = 0x800000; // Dynamic fees require a hook.
        _expectBadPool(wrong);
        wrong = key;
        wrong.hooks = IHooks(address(0x4000)); // Nonzero hook with no permission bits.
        _expectBadPool(wrong);
    }

    function test_configurationRejectsCodeLessTokenOrHook() public {
        PoolKey memory wrong = key;
        wrong.currency1 = Currency.wrap(makeAddr("no token"));
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.DependencyHasNoCode.selector);
        game.configurePool(wrong, 100);
        wrong = key;
        wrong.hooks = IHooks(address(0x80));
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.DependencyHasNoCode.selector);
        game.configurePool(wrong, 100);
    }

    function test_configurationRequiresInitializedPool() public {
        manager.setInitialized(false);
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.PoolNotInitialized.selector);
        game.configurePool(key, 100);
    }

    function test_twoStepOwnershipDoesNotGivePendingOwnerControl() public {
        vm.prank(owner);
        game.transferOwnership(alice);
        assertEq(game.owner(), owner);
        assertEq(game.pendingOwner(), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        game.configurePool(key, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        game.acceptOwnership();
        vm.prank(alice);
        game.acceptOwnership();
        assertEq(game.owner(), alice);
        assertEq(game.pendingOwner(), address(0));
        vm.prank(alice);
        game.configurePool(key, 150);
    }

    function test_mintBuysWithExactSplitAndRecordsPayerAndActualReceipt() public {
        token.mint(alice, 77);
        manager.setOutput(1234);
        vm.expectEmit(true, true, false, true, address(game));
        emit LowestMintGame.Minted(1, alice, 1234);
        vm.prank(alice);
        (uint256 id, uint256 amount) = game.mint{value: PRICE}();
        assertEq(id, 1);
        assertEq(amount, 1234);
        (address payer, uint256 received) = game.mints(id);
        assertEq(payer, alice);
        assertEq(received, 1234);
        assertEq(token.balanceOf(alice), 1311);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(alice.balance, 100 ether - PRICE);
        assertEq(address(manager).balance, SWAP);
        assertEq(address(game).balance, REWARD);
        assertEq(game.rewardPool(), REWARD);
        assertEq(game.leader(), alice);
        assertEq(game.lowestTokens(), 1234);
        assertEq(game.winningMintId(), 1);
        assertEq(game.mintCountOf(alice), 1);
        assertEq(game.totalTokensReceived(alice), 1234);
        assertEq(game.closesAt(), block.timestamp + game.GAME_DURATION());
        assertEq(manager.lastPoolId(), keccak256(abi.encode(key)));
        assertTrue(manager.lastZeroForOne());
        assertEq(manager.lastAmountSpecified(), -int256(SWAP));
        assertEq(manager.lastPriceLimit(), TickMath.MIN_SQRT_PRICE + 1);
        assertEq(manager.lastHookDataLength(), 0);
    }

    function test_multipleEntriesTrackIndividualMinimumAndAggregateReceipts() public {
        _mint(alice, 500);
        _mint(bob, 400);
        uint256 deadline = game.closesAt();
        vm.warp(block.timestamp + 1 days);
        _mint(alice, 300);
        assertEq(game.minted(), 3);
        assertEq(game.leader(), alice);
        assertEq(game.lowestTokens(), 300);
        assertEq(game.winningMintId(), 3);
        assertEq(game.mintCountOf(alice), 2);
        assertEq(game.totalTokensReceived(alice), 800);
        assertEq(game.totalTokensReceived(bob), 400);
        assertEq(game.closesAt(), deadline);
    }

    function test_tiesBelongToEarliestMint() public {
        _mint(alice, 200);
        _mint(bob, 200);
        _mint(carol, 300);
        assertEq(game.leader(), alice);
        assertEq(game.winningMintId(), 1);
    }

    function testFuzz_wrongPaymentRevertsAtomically(uint96 payment) public {
        vm.assume(payment != PRICE);
        vm.deal(alice, uint256(payment) + 100 ether);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.IncorrectPayment.selector);
        game.mint{value: payment}();
        assertEq(game.minted(), 0);
        assertEq(address(game).balance, 0);
        assertEq(manager.swapCalls(), 0);
    }

    function test_slippageFailureRollsBackSwapTransferAndEntry() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 1000, 1001));
        game.mint{value: PRICE}(1001, block.timestamp);
        _assertEmpty();
    }

    function test_callerCannotWeakenConfiguredMinimum() public {
        manager.setOutput(99);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 99, 100));
        game.mint{value: PRICE}(1, block.timestamp);
        _assertEmpty();
    }

    function test_defaultMintUsesConfiguredFloorAndInclusiveMinimum() public {
        manager.setOutput(99);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 99, 100));
        game.mint{value: PRICE}();
        _mint(alice, 100);
        assertEq(game.lowestTokens(), 100);
    }

    function test_explicitMintRejectsZeroFloorAndExpiredDeadline() public {
        vm.startPrank(alice);
        vm.expectRevert(LowestMintGame.InvalidMinimumOutput.selector);
        game.mint{value: PRICE}(0, block.timestamp);
        vm.expectRevert(LowestMintGame.DeadlineExpired.selector);
        game.mint{value: PRICE}(100, block.timestamp - 1);
        vm.stopPrank();
        _assertEmpty();
    }

    function test_poolBoundMintRejectsConfigurationReplacedAfterTheQuote() public {
        MockIMD other = new MockIMD();
        other.mint(address(manager), 1e36);
        PoolKey memory otherKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 3000, 60, IHooks(address(0)));
        bytes32 quotedPool = game.poolId();
        assertEq(quotedPool, PoolId.unwrap(key.toId()));

        // The owner may still replace the pool while no entry exists; a quote-bound entry then fails closed.
        vm.prank(owner);
        game.configurePool(otherKey, 1);
        bytes32 replacedPool = game.poolId();
        assertNotEq(replacedPool, quotedPool);
        manager.setOutput(1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.PoolMismatch.selector, quotedPool, replacedPool));
        game.mint{value: PRICE}(quotedPool, 0.079e18, block.timestamp);
        assertEq(game.minted(), 0);
        assertEq(other.balanceOf(alice), 0);
        assertEq(alice.balance, 100 ether);

        // Once the quoted pool is back, the same bound entry executes and freezes that configuration.
        vm.prank(owner);
        game.configurePool(key, 100);
        vm.prank(alice);
        (uint256 id, uint256 received) = game.mint{value: PRICE}(quotedPool, 0.079e18, block.timestamp);
        assertEq(id, 1);
        assertEq(received, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(other.balanceOf(alice), 0);
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.ConfigurationLocked.selector);
        game.configurePool(otherKey, 1);
    }

    function test_poolBoundMintKeepsFloorDeadlineAndConfigurationChecks() public {
        bytes32 id = game.poolId();
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.InvalidMinimumOutput.selector);
        game.mint{value: PRICE}(id, 0, block.timestamp);
        LowestMintGame unconfigured = new LowestMintGame(owner, IPoolManager(address(manager)));
        assertEq(unconfigured.poolId(), bytes32(0));
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.NotConfigured.selector);
        unconfigured.mint{value: PRICE}(bytes32(0), 100, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.DeadlineExpired.selector);
        game.mint{value: PRICE}(id, 100, block.timestamp - 1);
        manager.setOutput(150);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 150, 200));
        game.mint{value: PRICE}(id, 200, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 150, 151));
        game.mint{value: PRICE}(id, 151, block.timestamp);
        vm.prank(alice);
        game.mint{value: PRICE}(id, 150, block.timestamp);
        assertEq(game.minted(), 1);
        assertEq(game.lowestTokens(), 150);
    }

    function test_exactDeadlineIsAllowed() public {
        vm.prank(alice);
        game.mint{value: PRICE}(1000, block.timestamp);
        assertEq(game.minted(), 1);
    }

    function test_failedPoolSwapRollsBackPayment() public {
        manager.setFailSwap(true);
        vm.prank(alice);
        vm.expectRevert("swap failed");
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function testFuzz_inexactInputCannotSpendRewardsOrCreatePartialEntry(uint64 input) public {
        vm.assume(input != SWAP);
        manager.setInput(int128(uint128(input)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.InexactSwapInput.selector, -int128(uint128(input))));
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function test_zeroAndNegativeOutputAreRejected() public {
        manager.setOutput(0);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.InvalidSwapOutput.selector);
        game.mint{value: PRICE}();
        manager.setOutput(-1);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.InvalidSwapOutput.selector);
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function test_wrongSettlementReverts() public {
        manager.setWrongSettlement(true);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.InexactSettlement.selector);
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function test_callbackCannotBeForgedOrInvokedOutsideAMint() public {
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.UnauthorizedCallback.selector);
        game.unlockCallback(abi.encode(alice));
        vm.prank(address(manager));
        vm.expectRevert(LowestMintGame.UnauthorizedCallback.selector);
        game.unlockCallback("");
    }

    function test_missingCallbackAndDuplicateCallbackFail() public {
        manager.setCallbackMode(true, false);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.CallbackNotCompleted.selector);
        game.mint{value: PRICE}();
        manager.setCallbackMode(false, true);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.UnauthorizedCallback.selector);
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function test_falseReturningTokenRollsBackSwap() public {
        token.setMode(MockIMD.TransferMode.ReturnsFalse);
        vm.prank(alice);
        vm.expectRevert("token transfer failed");
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function test_revertingTokenRollsBackSwap() public {
        token.setMode(MockIMD.TransferMode.Reverts);
        vm.prank(alice);
        vm.expectRevert("token transfer failed");
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function test_noReturnTokenCanBeReceivedExactly() public {
        token.setMode(MockIMD.TransferMode.NoReturn);
        _mint(alice, 1000);
        assertEq(token.balanceOf(alice), 1000);
    }

    function test_taxedOrBonusTokenCannotManufactureScore() public {
        token.setMode(MockIMD.TransferMode.Taxed);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.InexactTokenReceipt.selector);
        game.mint{value: PRICE}();
        token.setMode(MockIMD.TransferMode.Bonus);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.InexactTokenReceipt.selector);
        game.mint{value: PRICE}();
        _assertEmpty();
    }

    function test_tokenCallbackCannotReenterMint() public {
        token.setReentry(address(game), abi.encodeWithSignature("mint()"));
        _mint(alice, 1000);
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(game.minted(), 1);
    }

    function test_tokenCallbackCannotReenterUnlockCallback() public {
        token.setReentry(address(game), abi.encodeCall(game.unlockCallback, ("")));
        _mint(alice, 1000);
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryResult(), abi.encodeWithSelector(LowestMintGame.UnauthorizedCallback.selector));
    }

    function test_soldOutAutomaticallyPaysAllRewardsAndPreventsLateMint() public {
        _mint(alice, 100);
        _fill(bob, 200);
        assertTrue(game.finalized());
        assertEq(game.minted(), 100);
        assertEq(game.leader(), alice);
        assertEq(game.winningMintId(), 1);
        assertEq(alice.balance, 100 ether - PRICE + 2 ether);
        assertEq(bob.balance, 100 ether - 99 * PRICE);
        assertEq(address(manager).balance, 8 ether);
        assertEq(address(game).balance, 0);
        assertEq(game.rewardPool(), 0);
        assertEq(game.pendingReward(), 0);
        assertEq(game.totalRewardsPaid(), 2 ether);
        vm.prank(carol);
        vm.expectRevert(LowestMintGame.GameClosed.selector);
        game.mint{value: PRICE}();
    }

    function test_finalMintCanBecomeWinnerAndItsRewardIsIncluded() public {
        for (uint256 i; i < 99; ++i) {
            _mint(alice, 500);
        }
        _mint(bob, 100);
        assertEq(game.leader(), bob);
        assertEq(game.winningMintId(), 100);
        assertEq(bob.balance, 100 ether - PRICE + 2 ether);
        assertEq(game.totalRewardsPaid(), 100 * REWARD);
    }

    function test_failedFinalMintLeavesGameOpenAndPriorAccountingIntact() public {
        for (uint256 i; i < 99; ++i) {
            _mint(alice, 500);
        }
        manager.setOutput(99);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 99, 100));
        game.mint{value: PRICE}();
        assertEq(game.minted(), 99);
        assertFalse(game.finalized());
        assertEq(game.rewardPool(), 99 * REWARD);
        assertEq(address(game).balance, 99 * REWARD);
        assertEq(game.leader(), alice);
        _mint(bob, 100);
        assertTrue(game.finalized());
    }

    function test_timeoutBoundaryRejectsMintAndAllowsAnyoneToSettle() public {
        _mint(alice, 500);
        vm.warp(game.closesAt() - 1);
        _mint(bob, 400);
        vm.expectRevert(LowestMintGame.GameStillOpen.selector);
        game.finalize();
        vm.warp(game.closesAt());
        vm.prank(carol);
        vm.expectRevert(LowestMintGame.GameClosed.selector);
        game.mint{value: PRICE}();
        vm.prank(carol);
        game.finalize();
        assertTrue(game.finalized());
        assertEq(game.leader(), bob);
        assertEq(bob.balance, 100 ether - PRICE + 2 * REWARD);
        assertEq(game.totalRewardsPaid(), 2 * REWARD);
    }

    function test_settlementRejectsEmptyGameEarlyAndDuplicateActions() public {
        vm.expectRevert(LowestMintGame.NoEntries.selector);
        game.finalize();
        _mint(alice, 500);
        vm.expectRevert(LowestMintGame.GameStillOpen.selector);
        game.finalize();
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.NotFinalized.selector);
        game.claimRewards(payable(alice));
        vm.warp(game.closesAt());
        game.finalize();
        vm.expectRevert(LowestMintGame.AlreadyFinalized.selector);
        game.finalize();
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.NothingToClaim.selector);
        game.claimRewards(payable(alice));
    }

    function test_rejectingWinnerCannotBlockSelloutAndCanRedirectClaim() public {
        PlayerWallet wallet = _walletLeader(PlayerWallet.ReceiveMode.Reject);
        _fill(bob, 500);
        assertTrue(game.finalized());
        assertEq(game.pendingReward(), 2 ether);
        assertEq(address(game).balance, 2 ether);
        assertEq(game.totalRewardsPaid(), 0);
        vm.prank(bob);
        vm.expectRevert(LowestMintGame.NotWinner.selector);
        game.claimRewards(payable(bob));
        vm.expectRevert(LowestMintGame.RewardTransferFailed.selector);
        wallet.claim(payable(address(wallet)));
        assertEq(game.pendingReward(), 2 ether);
        assertEq(game.totalRewardsPaid(), 0);
        wallet.claim(payable(carol));
        assertEq(carol.balance, 102 ether);
        assertEq(game.pendingReward(), 0);
        assertEq(address(game).balance, 0);
        assertEq(game.totalRewardsPaid(), 2 ether);
        vm.expectRevert(LowestMintGame.NothingToClaim.selector);
        wallet.claim(payable(carol));
    }

    function test_gasConsumingWinnerCannotBlockTimeoutSettlement() public {
        PlayerWallet wallet = _walletLeader(PlayerWallet.ReceiveMode.BurnGas);
        vm.warp(game.closesAt());
        game.finalize();
        assertTrue(game.finalized());
        assertEq(game.pendingReward(), REWARD);
        wallet.claim(payable(carol));
        assertEq(carol.balance, 100 ether + REWARD);
    }

    function test_lowGasSettlementRevertsInsteadOfDeferringThePrize() public {
        _mint(alice, 500);
        vm.warp(game.closesAt());
        (bool success, bytes memory result) = address(game).call{gas: 100_000}(abi.encodeCall(game.finalize, ()));
        assertFalse(success);
        assertEq(bytes4(result), LowestMintGame.InsufficientGasForPayout.selector);
        assertFalse(game.finalized());
        assertEq(game.rewardPool(), REWARD);
        assertEq(game.pendingReward(), 0);
        game.finalize();
        assertTrue(game.finalized());
        assertEq(game.pendingReward(), 0);
        assertEq(game.totalRewardsPaid(), REWARD);
        assertEq(alice.balance, 100 ether - PRICE + REWARD);
    }

    function test_finalMintGasLimitCannotForceDeferralForCooperativeWinner() public {
        _mint(alice, 100);
        manager.setOutput(200);
        for (uint256 i; i < 98; ++i) {
            vm.prank(bob);
            game.mint{value: PRICE}();
        }
        assertEq(game.minted(), 99);
        // Whatever gas limit the competing final minter chooses, the outcome is either a clean revert
        // that leaves the game open or a settlement that pays the EOA winner in full. Never a deferral.
        bool settled;
        for (uint256 gasLimit = 120_000; gasLimit <= 800_000 && !settled; gasLimit += 1_000) {
            vm.prank(bob);
            (settled,) = address(game).call{value: PRICE, gas: gasLimit}(abi.encodeWithSignature("mint()"));
            if (!settled) {
                assertEq(game.minted(), 99);
                assertFalse(game.finalized());
                assertEq(game.rewardPool(), 99 * REWARD);
                assertEq(game.pendingReward(), 0);
            }
        }
        assertTrue(settled, "final mint never fit the gas range");
        assertTrue(game.finalized());
        assertEq(game.pendingReward(), 0);
        assertEq(game.totalRewardsPaid(), 2 ether);
        assertEq(alice.balance, 100 ether - PRICE + 2 ether);
        assertEq(bob.balance, 100 ether - 99 * PRICE);
    }

    function test_returnBombingWinnerCannotRaiseSettlementGasAboveTheReserve() public {
        _mint(alice, 100);
        vm.warp(game.closesAt());
        uint256 eoaGas = _minimumFinalizeGas(game);
        assertEq(game.totalRewardsPaid(), REWARD);

        LowestMintGame bombed = new LowestMintGame(owner, IPoolManager(address(manager)));
        vm.prank(owner);
        bombed.configurePool(key, 100);
        PlayerWallet bomber = new PlayerWallet(bombed);
        bomber.setReceiveMode(PlayerWallet.ReceiveMode.ReturnBomb);
        manager.setOutput(100);
        bomber.enter{value: PRICE}();
        assertEq(bombed.leader(), address(bomber));
        vm.warp(bombed.closesAt());
        // The same gas that settles an EOA winner settles a winner returning 100 KB: the game never
        // copies return data, so the winner's behaviour costs the settler nothing beyond the allowance.
        (bool success,) = address(bombed).call{gas: eoaGas}(abi.encodeCall(bombed.finalize, ()));
        assertTrue(success, "return bomb raised the settlement gas requirement");
        assertTrue(bombed.finalized());
        assertEq(bombed.totalRewardsPaid(), REWARD);
        assertEq(bombed.pendingReward(), 0);
        assertEq(address(bomber).balance, REWARD);
    }

    function test_autoPayoutAndClaimReentrancyCannotDoublePay() public {
        PlayerWallet wallet = _walletLeader(PlayerWallet.ReceiveMode.Reenter);
        vm.warp(game.closesAt());
        game.finalize();
        if (game.pendingReward() != 0) wallet.claim(payable(address(wallet)));
        assertEq(address(wallet).balance, REWARD);
        assertEq(wallet.payouts(), 1);
        assertEq(game.totalRewardsPaid(), REWARD);
        assertEq(game.pendingReward(), 0);
    }

    function test_deferredClaimReentrancyCannotDoublePay() public {
        PlayerWallet wallet = _walletLeader(PlayerWallet.ReceiveMode.Reject);
        vm.warp(game.closesAt());
        game.finalize();
        wallet.setReceiveMode(PlayerWallet.ReceiveMode.Reenter);
        wallet.claim(payable(address(wallet)));
        assertEq(address(wallet).balance, REWARD);
        assertEq(wallet.payouts(), 1);
        assertEq(game.totalRewardsPaid(), REWARD);
    }

    function test_claimCannotBurnPrizeOrSendItBackToGame() public {
        PlayerWallet wallet = _walletLeader(PlayerWallet.ReceiveMode.Reject);
        vm.warp(game.closesAt());
        game.finalize();
        vm.expectRevert(LowestMintGame.InvalidRecipient.selector);
        wallet.claim(payable(address(0)));
        vm.expectRevert(LowestMintGame.InvalidRecipient.selector);
        wallet.claim(payable(address(game)));
        assertEq(game.pendingReward(), REWARD);
    }

    function test_directETHIsRejectedAndForcedSurplusIsNotAnEntryOrReward() public {
        vm.expectRevert(LowestMintGame.DirectPaymentNotAllowed.selector);
        payable(address(game)).transfer(1 ether);
        // Cheatcode represents an unsolicited balance increase without using SELFDESTRUCT.
        vm.deal(address(game), 1 ether);
        _mint(alice, 500);
        assertEq(game.rewardPool(), REWARD);
        vm.warp(game.closesAt());
        game.finalize();
        assertEq(game.totalRewardsPaid(), REWARD);
        assertEq(address(game).balance, 1 ether);
    }

    function testFuzz_scoreAndConservationForSequence(uint128[12] memory outputs) public {
        uint256 minimum = type(uint256).max;
        address expectedWinner;
        uint256 expectedId;
        uint256 aliceTotal;
        uint256 bobTotal;
        for (uint256 i; i < outputs.length; ++i) {
            uint256 amount = bound(outputs[i], 100, 1e24);
            address payer = i % 2 == 0 ? alice : bob;
            _mint(payer, int128(uint128(amount)));
            if (amount < minimum) {
                minimum = amount;
                expectedWinner = payer;
                expectedId = i + 1;
            }
            if (payer == alice) aliceTotal += amount;
            else bobTotal += amount;
        }
        assertEq(game.lowestTokens(), minimum);
        assertEq(game.leader(), expectedWinner);
        assertEq(game.winningMintId(), expectedId);
        assertEq(game.totalTokensReceived(alice), aliceTotal);
        assertEq(game.totalTokensReceived(bob), bobTotal);
        assertEq(token.balanceOf(alice), aliceTotal);
        assertEq(token.balanceOf(bob), bobTotal);
        assertEq(address(game).balance, outputs.length * REWARD);
        assertEq(address(manager).balance, outputs.length * SWAP);
        uint256 beforeReward = expectedWinner.balance;
        vm.warp(game.closesAt());
        game.finalize();
        assertEq(expectedWinner.balance - beforeReward, outputs.length * REWARD);
    }

    function _expectBadPool(PoolKey memory wrong) private {
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.InvalidPool.selector);
        game.configurePool(wrong, 100);
    }

    /// @dev Smallest gas limit, in 500-gas steps, at which `finalize()` on an open-at-deadline game succeeds.
    function _minimumFinalizeGas(LowestMintGame target) private returns (uint256 gasLimit) {
        for (gasLimit = 60_000; gasLimit <= 600_000; gasLimit += 500) {
            (bool success,) = address(target).call{gas: gasLimit}(abi.encodeCall(target.finalize, ()));
            if (success) return gasLimit;
            assertFalse(target.finalized());
        }
        revert("finalize never fit the gas range");
    }

    function _walletLeader(PlayerWallet.ReceiveMode mode) private returns (PlayerWallet wallet) {
        wallet = new PlayerWallet(game);
        wallet.setReceiveMode(mode);
        manager.setOutput(100);
        wallet.enter{value: PRICE}();
        assertEq(game.leader(), address(wallet));
    }
}
