// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameFixture} from "./helpers/GameFixture.sol";
import {MockPoolManager, PlayerWallet} from "./helpers/Mocks.sol";
import {LowestMintGame} from "../src/LowestMintGame.sol";

contract GameHandler is Test {
    LowestMintGame public immutable game;
    MockPoolManager public immutable manager;
    address[4] public actors;
    uint256[4] public tokenTotals;
    uint256[4] public entryCounts;
    uint256 public entries;
    uint256 public minimum = type(uint256).max;
    address public winner;
    uint256 public winningId;
    uint256 public closesAt;
    bool public closed;
    bool public paid;
    uint256 public failedPayments;
    mapping(uint256 => address) public entryPayer;
    mapping(uint256 => uint256) public entryOutput;

    constructor(LowestMintGame game_, MockPoolManager manager_) {
        game = game_;
        manager = manager_;
        actors[0] = makeAddr("invariant alice");
        actors[1] = makeAddr("invariant bob");
        actors[2] = makeAddr("invariant carol");
        PlayerWallet rejectingWallet = new PlayerWallet(game_);
        rejectingWallet.setReceiveMode(PlayerWallet.ReceiveMode.Reject);
        actors[3] = address(rejectingWallet);
        for (uint256 i; i < 4; ++i) {
            vm.deal(actors[i], 100 ether);
        }
    }

    function enter(uint8 actorSeed, uint128 outputSeed, uint8 countSeed) external {
        uint256 index = actorSeed % 4;
        address payer = actors[index];
        uint256 output = bound(outputSeed, 100, 1e24);
        uint256 count = bound(countSeed, 1, 8);
        manager.setOutput(int128(uint128(output)));
        for (uint256 i; i < count && _isOpen(); ++i) {
            vm.prank(payer);
            (uint256 id, uint256 received) = game.mint{value: 0.1 ether}();
            ++entries;
            assertEq(id, entries);
            assertEq(received, output);
            entryPayer[id] = payer;
            entryOutput[id] = output;
            tokenTotals[index] += output;
            entryCounts[index]++;
            if (entries == 1) closesAt = block.timestamp + 30 days;
            if (output < minimum) {
                minimum = output;
                winner = payer;
                winningId = id;
            }
            if (entries == 100) {
                closed = true;
                paid = winner != actors[3];
            }
        }
    }

    function invalidPayment(uint8 actorSeed) external {
        uint256 beforeBalance = address(game).balance;
        uint256 managerBefore = address(manager).balance;
        address payer = actors[actorSeed % 4];
        vm.prank(payer);
        (bool success,) = address(game).call{value: 0.1 ether + 1}(abi.encodeWithSignature("mint()"));
        assertFalse(success);
        assertEq(address(game).balance, beforeBalance);
        assertEq(address(manager).balance, managerBefore);
        ++failedPayments;
    }

    function advanceTime(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 4 days));
    }

    function settle() external {
        if (entries == 0 || closed || block.timestamp < closesAt) return;
        game.finalize();
        closed = true;
        paid = winner != actors[3];
    }

    function claim(uint8 recipientSeed) external {
        if (!closed || paid) return;
        // Only the rejecting winner has an unpaid prize; it may direct payment to any EOA actor.
        vm.prank(winner);
        game.claimRewards(payable(actors[recipientSeed % 3]));
        paid = true;
    }

    function _isOpen() private view returns (bool) {
        return !closed && entries < 100 && (closesAt == 0 || block.timestamp < closesAt);
    }
}

contract AccountingInvariantTest is GameFixture {
    GameHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GameHandler(game, manager);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.enter.selector;
        selectors[1] = handler.invalidPayment.selector;
        selectors[2] = handler.advanceTime.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ETHIsConservedAndRewardsCannotBeTakenTwice() public view {
        uint256 count = handler.entries();
        uint256 totalRewards = count * REWARD;
        assertEq(address(manager).balance, count * SWAP);
        assertEq(game.rewardPool() + game.pendingReward() + game.totalRewardsPaid(), totalRewards);
        assertEq(address(game).balance, game.rewardPool() + game.pendingReward());
        if (!handler.closed()) {
            assertEq(game.rewardPool(), totalRewards);
            assertEq(game.totalRewardsPaid(), 0);
        } else if (handler.paid()) {
            assertEq(game.totalRewardsPaid(), totalRewards);
            assertEq(address(game).balance, 0);
        } else {
            assertEq(game.pendingReward(), totalRewards);
            assertEq(game.totalRewardsPaid(), 0);
        }
        uint256 totalETH = address(game).balance + address(manager).balance;
        for (uint256 i; i < 4; ++i) {
            totalETH += handler.actors(i).balance;
        }
        assertEq(totalETH, 400 ether);
    }

    function invariant_everyEntryAndPayerAggregateMatchesActualDelivery() public view {
        assertEq(game.minted(), handler.entries());
        assertLe(game.minted(), game.MAX_MINTS());
        for (uint256 i = 1; i <= handler.entries(); ++i) {
            (address payer, uint256 amount) = game.mints(i);
            assertEq(payer, handler.entryPayer(i));
            assertEq(amount, handler.entryOutput(i));
        }
        for (uint256 i; i < 4; ++i) {
            address payer = handler.actors(i);
            assertEq(token.balanceOf(payer), handler.tokenTotals(i));
            assertEq(game.totalTokensReceived(payer), handler.tokenTotals(i));
            assertEq(game.mintCountOf(payer), handler.entryCounts(i));
        }
    }

    function invariant_leaderIsEarliestMinimumAndClosureIsIrreversible() public view {
        assertEq(game.finalized(), handler.closed());
        assertEq(game.closesAt(), handler.closesAt());
        assertEq(game.leader(), handler.winner());
        assertEq(game.winningMintId(), handler.winningId());
        if (handler.entries() != 0) assertEq(game.lowestTokens(), handler.minimum());
    }
}
