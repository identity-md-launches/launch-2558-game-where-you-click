// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LowestMintGame} from "src/LowestMintGame.sol";
import {MockIMD} from "./helpers/Mocks.sol";
import {LiquiditySeeder} from "./helpers/LiquiditySeeder.sol";
import {ExternalPoolTrader} from "./helpers/ExternalPoolTrader.sol";
import {RealPoolGameHandler} from "./helpers/RealPoolGameHandler.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Independent real-pool accounting under market activity and game lifecycle actions.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract RealPoolInvariantTest is Test {
    LowestMintGame internal game;
    MockIMD internal token;
    IPoolManager internal manager;
    LiquiditySeeder internal seeder;
    ExternalPoolTrader internal trader;
    RealPoolGameHandler internal handler;
    PoolKey internal key;
    uint256 internal initialManagerETH;
    uint256 internal initialManagerTokens;
    uint256 internal initialSupply;
    address internal owner = makeAddr("real invariant owner");

    function setUp() public {
        vm.warp(1_000_000);
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
        trader = new ExternalPoolTrader(manager);
        vm.deal(address(trader), 1000 ether);
        token.mint(address(trader), 1000 ether);
        handler = new RealPoolGameHandler(game, token, trader, key);
        initialManagerETH = address(manager).balance;
        initialManagerTokens = token.balanceOf(address(manager));
        initialSupply = token.totalSupply();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.enter.selector;
        selectors[1] = handler.trade.selector;
        selectors[2] = handler.moveTokens.selector;
        selectors[3] = handler.rejectMint.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.forceSurplus.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_rewardsAndNativeBalancesMatchIndependentCashFlows() public view {
        uint256 entries = handler.entries();
        uint256 rewards = entries * 0.02 ether;
        uint256 paid = handler.paid();
        assertEq(game.totalRewardsPaid(), paid);
        assertEq(game.rewardPool(), handler.closed() ? 0 : rewards);
        assertEq(game.pendingReward(), handler.closed() ? rewards - paid : 0);
        assertEq(address(game).balance, rewards - paid + handler.surplus());
        assertEq(
            int256(address(manager).balance),
            int256(initialManagerETH + entries * 0.08 ether) - handler.traderETHDelta(),
            "pool receives exactly the swap portion plus unrelated market flows"
        );
        assertEq(int256(address(trader).balance), int256(1000 ether) + handler.traderETHDelta());
        uint256 totalETH =
            address(game).balance + address(manager).balance + address(seeder).balance + address(trader).balance;
        for (uint256 i; i < 4; ++i) {
            assertEq(handler.actors(i).balance, handler.expectedETH(i), "payer or prize recipient cash flow");
            totalETH += handler.actors(i).balance;
        }
        assertEq(totalETH, 11_400 ether + handler.surplus(), "global native conservation");
    }

    function invariant_historyMatchesDeliveryEvenAfterTokensMove() public view {
        uint256 entries = handler.entries();
        assertEq(game.minted(), entries);
        assertLe(entries, 100);
        uint256 delivered;
        for (uint256 id = 1; id <= entries; ++id) {
            (address payer, uint256 receipt) = game.mints(id);
            assertEq(payer, handler.actors(handler.payerIndices(id - 1)));
            assertEq(receipt, handler.receipts(id - 1), "historical delivery cannot follow current holdings");
            delivered += receipt;
        }
        (address phantomPayer, uint256 phantomReceipt) = game.mints(entries + 1);
        assertEq(phantomPayer, address(0));
        assertEq(phantomReceipt, 0);
        uint256 accountedSupply =
            token.balanceOf(address(manager)) + token.balanceOf(address(seeder)) + token.balanceOf(address(trader));
        uint256 countedEntries;
        uint256 aggregateReceipts;
        for (uint256 i; i < 4; ++i) {
            address payer = handler.actors(i);
            assertEq(token.balanceOf(payer), handler.expectedTokens(i));
            assertEq(game.totalTokensReceived(payer), handler.lifetimeTokens(i));
            assertEq(game.mintCountOf(payer), handler.entryCounts(i));
            aggregateReceipts += game.totalTokensReceived(payer);
            countedEntries += game.mintCountOf(payer);
            accountedSupply += token.balanceOf(payer);
        }
        assertEq(aggregateReceipts, delivered);
        assertEq(countedEntries, entries);
        assertEq(token.totalSupply(), initialSupply);
        assertEq(accountedSupply, initialSupply);
        assertEq(token.balanceOf(address(game)), 0, "no token custody by game");
        assertEq(
            int256(token.balanceOf(address(manager))),
            int256(initialManagerTokens - delivered) - handler.traderTokenDelta()
        );
        assertEq(int256(token.balanceOf(address(trader))), int256(1000 ether) + handler.traderTokenDelta());
    }

    function invariant_winnerIsTheEarliestMinimumAndFinalizationNeverReopens() public view {
        assertEq(game.finalized(), handler.closed());
        assertEq(game.closesAt(), handler.deadline());
        assertTrue(game.configured());
        assertEq(game.minimumOutput(), 1e12);
        assertEq(game.owner(), owner);
        (Currency currency0, Currency currency1, uint24 fee, int24 spacing, IHooks hooks) = game.poolKey();
        assertEq(keccak256(abi.encode(currency0, currency1, fee, spacing, hooks)), keccak256(abi.encode(key)));
        uint256 entries = handler.entries();
        if (entries == 0) {
            assertEq(game.leader(), address(0));
            assertEq(game.lowestTokens(), 0);
            assertEq(game.winningMintId(), 0);
            return;
        }
        uint256 winnerId = game.winningMintId();
        assertGe(winnerId, 1);
        assertLe(winnerId, entries);
        assertEq(game.leader(), handler.actors(handler.payerIndices(winnerId - 1)));
        assertEq(game.lowestTokens(), handler.receipts(winnerId - 1));
        for (uint256 i; i < entries; ++i) {
            assertLe(game.lowestTokens(), handler.receipts(i), "winner must beat every receipt");
            if (game.lowestTokens() == handler.receipts(i)) assertLe(winnerId, i + 1, "earliest tie wins");
        }
        if (entries == 100) assertTrue(handler.closed());
        if (handler.closed()) assertTrue(entries == 100 || block.timestamp >= handler.deadline());
    }

    function afterInvariant() public {
        handler.finish();
        _assertAll();
        assertEq(game.rewardPool(), 0);
        assertEq(game.pendingReward(), 0);
        assertEq(game.totalRewardsPaid(), handler.entries() * 0.02 ether);
        assertEq(address(game).balance, handler.surplus());
    }

    // Deterministic handler exercises prevent a passing campaign whose difficult
    // paths (sellout, adverse prices, rejected claim) were never actually reached.
    function test_handlerReachesSelloutWithRejectingWinnerAndClaimRetries() public {
        for (uint256 i; i < 5; ++i) {
            handler.enter(3, 20, i % 2 == 0);
        }
        _assertAll();
        assertEq(game.minted(), 100);
        assertEq(game.pendingReward(), 2 ether);
        handler.claim(0, 0); // loser
        handler.claim(3, 3); // recipient rejects ETH
        handler.claim(3, 4); // zero recipient
        handler.claim(3, 5); // game recipient
        _assertAll();
        handler.claim(3, 1);
        handler.claim(3, 1); // no double claim
        handler.enter(0, 1, false);
        handler.settle(false);
        _assertAll();
        assertEq(game.totalRewardsPaid(), 2 ether);
    }

    function test_handlerTradesBothWaysAndKeepsHistoryAfterTransfer() public {
        handler.trade(true, 2 ether);
        handler.enter(0, 1, false);
        uint256 firstReceipt = handler.receipts(0);
        handler.trade(false, 2 ether);
        handler.enter(1, 1, true);
        assertGt(handler.receipts(1), firstReceipt, "external sell reverses decreasing-output trend");
        handler.moveTokens(0, 1, uint128(token.balanceOf(handler.actors(0))));
        assertEq(token.balanceOf(handler.actors(0)), 0);
        assertEq(game.leader(), handler.actors(0), "selling tokens does not forfeit recorded entry");
        for (uint8 mode; mode < 5; ++mode) {
            handler.rejectMint(2, mode, 1);
        }
        _assertAll();
        assertEq(handler.marketTrades(), 2);
        assertEq(handler.tokenMoves(), 1);
        assertEq(handler.rejectedMints(), 5);
        vm.warp(handler.deadline());
        handler.settle(true);
        _assertAll();
        assertEq(game.pendingReward(), 0.04 ether);
        handler.forceSurplus(1 ether);
        handler.claim(0, 2);
        _assertAll();
        assertEq(address(game).balance, 1 ether);
    }

    function _assertAll() internal view {
        invariant_rewardsAndNativeBalancesMatchIndependentCashFlows();
        invariant_historyMatchesDeliveryEvenAfterTokensMove();
        invariant_winnerIsTheEarliestMinimumAndFinalizationNeverReopens();
    }
}
