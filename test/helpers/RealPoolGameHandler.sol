// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LowestMintGame} from "src/LowestMintGame.sol";
import {MockIMD, PlayerWallet} from "./Mocks.sol";
import {ExternalPoolTrader} from "./ExternalPoolTrader.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Ghost receipts come from observed ERC20 balance changes, not the game's
/// return values or its records. All expected failures check their revert data.
contract RealPoolGameHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    LowestMintGame public immutable game;
    IPoolManager public immutable manager;
    MockIMD public immutable token;
    ExternalPoolTrader public immutable trader;
    PoolKey internal key;
    address[4] public actors;
    uint256[4] public expectedETH;
    uint256[4] public expectedTokens;
    uint256[4] public lifetimeTokens;
    uint256[4] public entryCounts;
    uint8[] public payerIndices;
    uint256[] public receipts;
    uint256 public deadline;
    uint256 public paid;
    uint256 public surplus;
    bool public closed;
    int256 public traderETHDelta;
    int256 public traderTokenDelta;
    uint256 public rejectedMints;
    uint256 public marketTrades;
    uint256 public tokenMoves;

    constructor(LowestMintGame game_, MockIMD token_, ExternalPoolTrader trader_, PoolKey memory key_) {
        game = game_;
        manager = game_.poolManager();
        token = token_;
        trader = trader_;
        key = key_;
        actors[0] = makeAddr("real invariant alice");
        actors[1] = makeAddr("real invariant bob");
        actors[2] = makeAddr("real invariant carol");
        PlayerWallet wallet = new PlayerWallet(game_);
        wallet.setReceiveMode(PlayerWallet.ReceiveMode.Reject);
        actors[3] = address(wallet);
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 100 ether);
            token_.mint(actors[i], 1 ether);
            expectedETH[i] = 100 ether;
            expectedTokens[i] = 1 ether;
        }
    }

    function entries() public view returns (uint256) {
        return receipts.length;
    }

    function enter(uint8 actorSeed, uint8 countSeed, bool quoted) public {
        uint8 index = actorSeed % 4;
        uint256 count = bound(countSeed, 1, 20);
        for (uint256 i; i < count; ++i) {
            if (closed || (deadline != 0 && block.timestamp >= deadline)) {
                vm.prank(actors[index]);
                vm.expectRevert(LowestMintGame.GameClosed.selector);
                game.mint{value: 0.1 ether}();
                ++rejectedMints;
                break;
            }
            uint256 beforeTokens = token.balanceOf(actors[index]);
            uint256 beforeManagerETH = address(manager).balance;
            uint256 beforeManagerTokens = token.balanceOf(address(manager));
            vm.prank(actors[index]);
            (uint256 id, uint256 reported) =
                quoted ? game.mint{value: 0.1 ether}(1e12, block.timestamp) : game.mint{value: 0.1 ether}();
            _assertSettled(address(game));
            uint256 received = token.balanceOf(actors[index]) - beforeTokens;
            assertGe(received, 1e12, "configured floor");
            assertEq(reported, received, "return must match delivery");
            assertEq(id, entries() + 1, "contiguous entry IDs");
            assertEq(address(manager).balance - beforeManagerETH, 0.08 ether, "fixed swap debit");
            assertEq(beforeManagerTokens - token.balanceOf(address(manager)), received, "direct delivery");
            if (entries() == 0) deadline = block.timestamp + 30 days;
            receipts.push(received);
            payerIndices.push(index);
            expectedTokens[index] += received;
            lifetimeTokens[index] += received;
            expectedETH[index] -= 0.1 ether;
            ++entryCounts[index];
            if (entries() == 100) _close(false);
        }
    }

    function trade(bool buyIMD, uint96 amountSeed) public {
        // Even at maximum invariant depth, these bounds leave the funded trader
        // solvent and the wide liquidity position active in either direction.
        uint256 amount = bound(amountSeed, 1e12, 2 ether);
        (int128 eth, int128 imd) = trader.trade(key, buyIMD, amount);
        _assertSettled(address(trader));
        if (buyIMD) {
            assertEq(int256(eth), -int256(amount));
            assertGt(int256(imd), 0);
        } else {
            assertEq(int256(imd), -int256(amount));
            assertGt(int256(eth), 0);
        }
        traderETHDelta += eth;
        traderTokenDelta += imd;
        ++marketTrades;
    }

    function moveTokens(uint8 fromSeed, uint8 toSeed, uint128 amountSeed) public {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = bound(amountSeed, 0, expectedTokens[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        expectedTokens[from] -= amount;
        expectedTokens[to] += amount;
        ++tokenMoves;
    }

    function rejectMint(uint8 actorSeed, uint8 modeSeed, uint96 paymentSeed) public {
        uint256 mode = modeSeed % 5;
        uint256 value = 0.1 ether;
        bytes memory data;
        bytes4 errorSelector;
        if (mode == 0) {
            value = bound(paymentSeed, 0, 0.2 ether - 1);
            if (value >= 0.1 ether) ++value;
            data = abi.encodeWithSignature("mint()");
            errorSelector = LowestMintGame.IncorrectPayment.selector;
        } else if (mode == 1) {
            data = abi.encodeWithSignature("mint(uint256,uint256)", 0, block.timestamp);
            errorSelector = LowestMintGame.InvalidMinimumOutput.selector;
        } else {
            bool ended = closed || (deadline != 0 && block.timestamp >= deadline);
            if (mode == 2) {
                data = abi.encodeWithSignature("mint(uint256,uint256)", 1e12, block.timestamp - 1);
                errorSelector = ended ? LowestMintGame.GameClosed.selector : LowestMintGame.DeadlineExpired.selector;
            } else if (mode == 3) {
                data = abi.encodeWithSignature("mint(uint256,uint256)", type(uint256).max, block.timestamp);
                errorSelector = ended ? LowestMintGame.GameClosed.selector : LowestMintGame.TooFewTokens.selector;
            } else {
                token.setMode(MockIMD.TransferMode.Taxed);
                data = abi.encodeWithSignature("mint()");
                errorSelector = ended ? LowestMintGame.GameClosed.selector : LowestMintGame.InexactTokenReceipt.selector;
            }
        }
        bytes32 poolBefore = poolState();
        uint256 beforeManagerETH = address(manager).balance;
        uint256 beforeManagerTokens = token.balanceOf(address(manager));
        vm.prank(actors[actorSeed % 4]);
        (bool success, bytes memory reason) = address(game).call{value: value}(data);
        assertFalse(success, "invalid entry accepted");
        assertEq(bytes4(reason), errorSelector, "unexpected rejection");
        assertEq(poolState(), poolBefore, "failed mint changed price, liquidity or fee growth");
        assertEq(address(manager).balance, beforeManagerETH, "failed mint paid ETH to pool");
        assertEq(token.balanceOf(address(manager)), beforeManagerTokens, "failed mint took pool tokens");
        _assertSettled(address(game));
        token.setMode(MockIMD.TransferMode.Normal);
        ++rejectedMints;
    }

    function advanceTime(uint32 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 4 days));
    }

    function settle(bool lowGas) public {
        if (closed) {
            vm.expectRevert(LowestMintGame.AlreadyFinalized.selector);
            game.finalize();
        } else if (entries() == 0) {
            vm.expectRevert(LowestMintGame.NoEntries.selector);
            game.finalize();
        } else if (block.timestamp < deadline) {
            vm.expectRevert(LowestMintGame.GameStillOpen.selector);
            game.finalize();
        } else {
            if (lowGas) game.finalize{gas: 100_000}();
            else game.finalize();
            _close(lowGas);
        }
    }

    function claim(uint8 callerSeed, uint8 recipientSeed) public {
        uint256 caller = callerSeed % 4;
        uint256 recipientIndex = recipientSeed % 6;
        address recipient =
            recipientIndex < 4 ? actors[recipientIndex] : recipientIndex == 4 ? address(0) : address(game);
        bytes4 expectedError;
        if (!closed) expectedError = LowestMintGame.NotFinalized.selector;
        else if (caller != winnerIndex()) expectedError = LowestMintGame.NotWinner.selector;
        else if (recipientIndex >= 4) expectedError = LowestMintGame.InvalidRecipient.selector;
        else if (paid != 0) expectedError = LowestMintGame.NothingToClaim.selector;
        else if (recipientIndex == 3) expectedError = LowestMintGame.RewardTransferFailed.selector;

        vm.prank(actors[caller]);
        if (expectedError != bytes4(0)) {
            vm.expectRevert(expectedError);
            game.claimRewards(payable(recipient));
        } else {
            game.claimRewards(payable(recipient));
            paid = entries() * 0.02 ether;
            expectedETH[recipientIndex] += paid;
        }
    }

    function forceSurplus(uint96 amountSeed) public {
        uint256 amount = bound(amountSeed, 0, 1 ether);
        // Model forced ETH without adding a SELFDESTRUCT fixture to the launch.
        vm.deal(address(game), address(game).balance + amount);
        surplus += amount;
    }

    function winnerIndex() public view returns (uint256 index) {
        uint256 minimum = type(uint256).max;
        for (uint256 i; i < entries(); ++i) {
            if (receipts[i] < minimum) {
                minimum = receipts[i];
                index = payerIndices[i];
            }
        }
    }

    function poolState() public view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, fee0, fee1, manager.getLiquidity(key.toId())));
    }

    /// @dev End-of-campaign liveness: accrued rewards remain fully withdrawable.
    /// This is called by afterInvariant, and is not a random target selector.
    function finish() external {
        if (entries() == 0) return;
        if (!closed) {
            if (vm.getBlockTimestamp() < deadline) vm.warp(deadline);
            settle(false);
        }
        if (paid == 0) claim(uint8(winnerIndex()), 0);
    }

    function _close(bool lowGas) private {
        closed = true;
        uint256 index = winnerIndex();
        if (!lowGas && index != 3) {
            paid = entries() * 0.02 ether;
            expectedETH[index] += paid;
        }
    }

    function _assertSettled(address account) private view {
        // Inspect within this handler transaction, before transient state is
        // discarded at the top-level boundary by Forge 1.8.
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(account, key.currency0), 0);
        assertEq(manager.currencyDelta(account, key.currency1), 0);
    }
}
