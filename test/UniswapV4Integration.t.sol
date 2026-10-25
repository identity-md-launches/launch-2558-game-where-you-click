// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LowestMintGame} from "../src/LowestMintGame.sol";
import {MockIMD} from "./helpers/Mocks.sol";
import {LiquiditySeeder} from "./helpers/LiquiditySeeder.sol";
import {SwapHook} from "./helpers/SwapHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UniswapV4IntegrationTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal manager;
    MockIMD internal token;
    LowestMintGame internal game;
    LiquiditySeeder internal seeder;
    PoolKey internal key;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(owner)));
        token = new MockIMD();
        game = new LowestMintGame(owner, manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        seeder = new LiquiditySeeder(manager);
        vm.deal(address(seeder), 10_000 ether);
        token.mint(address(seeder), 10_000 ether);
        seeder.add(key, -60000, 60000, 1000 ether);
        vm.prank(owner);
        game.configurePool(key, 1e12);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_realPoolSwapPaysNativeDebtAndTransfersIMDDirectly() public {
        uint256 managerETH = address(manager).balance;
        uint256 managerTokens = token.balanceOf(address(manager));
        token.mint(alice, 100 ether);
        vm.prank(alice);
        (uint256 id, uint256 received) = game.mint{value: 0.1 ether}();
        assertEq(id, 1);
        assertGt(received, 0.079 ether);
        assertLt(received, 0.08 ether);
        assertEq(token.balanceOf(alice), 100 ether + received);
        assertEq(token.balanceOf(address(manager)), managerTokens - received);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(address(manager).balance - managerETH, 0.08 ether);
        assertEq(address(game).balance, 0.02 ether);
        assertEq(manager.currencyDelta(address(game), key.currency0), 0);
        assertEq(manager.currencyDelta(address(game), key.currency1), 0);
        (address payer, uint256 recorded) = game.mints(1);
        assertEq(payer, alice);
        assertEq(recorded, received);
    }

    function test_realPriceMovementChangesLeaderAndSelloutPaysFinalMint() public {
        uint256 managerETH = address(manager).balance;
        uint256 previous = type(uint256).max;
        for (uint256 i; i < 100; ++i) {
            address payer = i % 2 == 0 ? alice : bob;
            vm.prank(payer);
            (, uint256 received) = game.mint{value: 0.1 ether}();
            assertLt(received, previous);
            assertEq(game.lowestTokens(), received);
            assertEq(game.winningMintId(), i + 1);
            previous = received;
        }
        assertTrue(game.finalized());
        assertEq(game.leader(), bob);
        assertEq(alice.balance, 95 ether);
        assertEq(bob.balance, 97 ether);
        assertEq(address(game).balance, 0);
        assertEq(address(manager).balance - managerETH, 8 ether);
        assertEq(game.totalRewardsPaid(), 2 ether);
        assertEq(token.balanceOf(alice), game.totalTokensReceived(alice));
        assertEq(token.balanceOf(bob), game.totalTokensReceived(bob));
    }

    function test_realSlippageRevertRestoresPoolPriceBalancesAndEntryState() public {
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        uint256 managerETH = address(manager).balance;
        uint256 managerTokens = token.balanceOf(address(manager));
        vm.prank(alice);
        vm.expectPartialRevert(LowestMintGame.TooFewTokens.selector);
        game.mint{value: 0.1 ether}(0.08 ether, block.timestamp);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(address(manager).balance, managerETH);
        assertEq(token.balanceOf(address(manager)), managerTokens);
        assertEq(token.balanceOf(alice), 0);
        assertEq(alice.balance, 100 ether);
        assertEq(game.minted(), 0);
        assertEq(address(game).balance, 0);
    }

    function test_realPoolWithNoLiquidityCannotCreateAnEntry() public {
        PoolKey memory empty = key;
        empty.fee = 500;
        manager.initialize(empty, uint160(1 << 96));
        vm.prank(owner);
        game.configurePool(empty, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.InexactSwapInput.selector, int128(0)));
        game.mint{value: 0.1 ether}();
        assertEq(game.minted(), 0);
        assertEq(alice.balance, 100 ether);
    }

    function test_realExhaustedLiquidityRejectsPartialFill() public {
        PoolKey memory small = key;
        small.fee = 500;
        manager.initialize(small, uint160(1 << 96));
        seeder.add(small, -60, 60, 0.01 ether);
        vm.prank(owner);
        game.configurePool(small, 100);
        uint256 managerETH = address(manager).balance;
        vm.prank(alice);
        vm.expectPartialRevert(LowestMintGame.InexactSwapInput.selector);
        game.mint{value: 0.1 ether}();
        assertEq(game.minted(), 0);
        assertEq(alice.balance, 100 ether);
        assertEq(address(manager).balance, managerETH);
    }

    function test_realPoolTokenTransferFailureRevertsAllState() public {
        token.setMode(MockIMD.TransferMode.ReturnsFalse);
        uint256 managerETH = address(manager).balance;
        vm.prank(alice);
        vm.expectRevert(); // v4 wraps the ERC20 transfer failure with currency context.
        game.mint{value: 0.1 ether}();
        assertEq(game.minted(), 0);
        assertEq(address(manager).balance, managerETH);
        assertEq(alice.balance, 100 ether);
    }

    function test_realPoolNoReturnTokenIsSupported() public {
        token.setMode(MockIMD.TransferMode.NoReturn);
        vm.prank(alice);
        (, uint256 received) = game.mint{value: 0.1 ether}();
        assertEq(received, token.balanceOf(alice));
    }

    function test_realPoolTaxedTokenCannotChangeWinningScore() public {
        token.setMode(MockIMD.TransferMode.Taxed);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.InexactTokenReceipt.selector);
        game.mint{value: 0.1 ether}();
        assertEq(game.minted(), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_timeoutSettlementDoesNotNeedLivePoolOrToken() public {
        vm.prank(alice);
        game.mint{value: 0.1 ether}();
        vm.etch(address(manager), hex"");
        vm.etch(address(token), hex"");
        vm.warp(game.closesAt());
        game.finalize();
        assertEq(alice.balance, 99.92 ether);
        assertEq(game.totalRewardsPaid(), 0.02 ether);
        assertTrue(game.finalized());
    }

    function test_realHookCannotPoisonSettlementCurrencyOrReenterMint() public {
        SwapHook hook = _configureHookPool(3000);
        uint256 managerETH = address(manager).balance;
        vm.prank(alice);
        (, uint256 received) = game.mint{value: 0.1 ether}();
        assertEq(token.balanceOf(alice), received);
        assertEq(address(manager).balance - managerETH, 0.08 ether);
        assertEq(hook.observedSender(), address(game));
        assertEq(hook.hookDataLength(), 0);
        assertFalse(hook.reentrySucceeded());
        assertEq(hook.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_realDynamicFeeHookAndOutputFeeAreAccountedBeforeScoring() public {
        SwapHook hook = _configureHookPool(0x800000);
        hook.setFeeOverride(0x400000 | 10_000); // A one-percent dynamic LP fee.
        hook.setOutputFee(0.001 ether);
        uint256 managerETH = address(manager).balance;
        vm.prank(alice);
        (, uint256 received) = game.mint{value: 0.1 ether}();
        assertLt(received, 0.0782 ether);
        assertGt(received, 0.078 ether);
        assertEq(token.balanceOf(alice), received);
        assertEq(game.lowestTokens(), received);
        assertEq(token.balanceOf(address(hook)), 0.001 ether);
        assertEq(address(manager).balance - managerETH, 0.08 ether);
        assertEq(address(game).balance, 0.02 ether);
    }

    function test_rejectingRealHookRollsBackEntry() public {
        SwapHook hook = _configureHookPool(3000);
        hook.setReject(true);
        uint256 managerETH = address(manager).balance;
        vm.prank(alice);
        vm.expectRevert(); // v4 wraps the original hook revert.
        game.mint{value: 0.1 ether}();
        assertEq(game.minted(), 0);
        assertEq(address(manager).balance, managerETH);
        assertEq(alice.balance, 100 ether);
    }

    function testFuzz_realPoolReceiptsMatchTokenBalanceDeltas(uint8 entryCount) public {
        uint256 count = bound(entryCount, 1, 100);
        uint256 managerETH = address(manager).balance;
        uint256 tokensReceived;
        for (uint256 i; i < count; ++i) {
            uint256 beforeBalance = token.balanceOf(alice);
            vm.prank(alice);
            (, uint256 received) = game.mint{value: 0.1 ether}(1e12, block.timestamp);
            assertEq(received, token.balanceOf(alice) - beforeBalance);
            tokensReceived += received;
        }
        assertEq(game.totalTokensReceived(alice), tokensReceived);
        assertEq(address(manager).balance - managerETH, count * 0.08 ether);
        assertEq(game.rewardPool() + game.pendingReward() + game.totalRewardsPaid(), count * 0.02 ether);
    }

    function _configureHookPool(uint24 fee) private returns (SwapHook hook) {
        address hookAddress =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        SwapHook implementation = new SwapHook(manager);
        vm.etch(hookAddress, address(implementation).code);
        hook = SwapHook(hookAddress);
        key.hooks = IHooks(hookAddress);
        key.fee = fee;
        manager.initialize(key, uint160(1 << 96));
        seeder.add(key, -60000, 60000, 1000 ether);
        vm.prank(owner);
        game.configurePool(key, 1e12);
    }
}
