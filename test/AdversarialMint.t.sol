// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture} from "./helpers/GameFixture.sol";
import {MockIMD, PlayerWallet} from "./helpers/Mocks.sol";
import {LowestMintGame} from "src/LowestMintGame.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Regression properties for nonempty games, complete input boundaries,
/// caller identity and recovery after external dependency failures.
contract AdversarialMintTest is GameFixture {
    function test_eachDependencyFailurePreservesExistingRewardsAndAllowsNextMint() public {
        _mint(alice, 500);
        _mint(bob, 400);
        _mint(alice, 300);
        uint256 originalDeadline = game.closesAt();
        for (uint8 fault; fault < 13; ++fault) {
            bytes memory expectedError = _setFault(fault);
            bytes32 beforeState = _stateDigest();
            uint256 nextId = game.minted() + 1;
            vm.prank(bob);
            vm.expectRevert(expectedError);
            game.mint{value: PRICE}();
            assertEq(_stateDigest(), beforeState, "failed entry corrupted previous state");
            _resetDependencies();
            (uint256 id, uint256 received) = _mint(carol, 250);
            assertEq(id, nextId, "failure consumed an entry ID");
            assertEq(received, 250);
            assertEq(game.closesAt(), originalDeadline, "failure/retry changed expiry");
        }
        assertEq(game.minted(), 16);
        assertEq(game.rewardPool(), 16 * REWARD);
        assertEq(game.totalTokensReceived(alice), 800);
        assertEq(game.totalTokensReceived(bob), 400);
        assertEq(game.mintCountOf(carol), 13);
    }

    function test_wrongPaymentBoundariesRevertThroughBothOverloadsWithExistingPot() public {
        _mint(alice, 500);
        uint256[5] memory invalid = [uint256(0), 1, PRICE - 1, PRICE + 1, 2 * PRICE];
        bytes32 beforeState = _stateDigest();
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(bob);
            vm.expectRevert(LowestMintGame.IncorrectPayment.selector);
            game.mint{value: invalid[i]}();
            vm.prank(bob);
            vm.expectRevert(LowestMintGame.IncorrectPayment.selector);
            game.mint{value: invalid[i]}(100, block.timestamp);
            assertEq(_stateDigest(), beforeState);
        }
    }

    function test_maximumPaymentIsRejectedWithoutCreatingAnEntry() public {
        vm.deal(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(LowestMintGame.IncorrectPayment.selector);
        game.mint{value: type(uint256).max}();
        assertEq(alice.balance, type(uint256).max);
        assertEq(game.minted(), 0);
        assertEq(address(game).balance, 0);
        assertEq(manager.swapCalls(), 0);
    }

    function test_oneRawTokenIsAValidReceiptAndEarliestTieWins() public {
        vm.prank(owner);
        game.configurePool(key, 1);
        _mint(alice, 1);
        _mint(bob, 1);
        assertEq(game.lowestTokens(), 1);
        assertEq(game.leader(), alice);
        assertEq(game.winningMintId(), 1);
        assertEq(game.totalTokensReceived(alice), 1);
        vm.warp(game.closesAt());
        game.finalize();
        assertEq(alice.balance, 100 ether - PRICE + 2 * REWARD);
    }

    function test_nativeCreditPartialDebitOrFullMintPriceCannotConsumePriorRewards() public {
        _mint(alice, 500);
        int128[3] memory inputs = [int128(-int256(SWAP)), int128(1), int128(uint128(PRICE))];
        for (uint256 i; i < inputs.length; ++i) {
            manager.setInput(inputs[i]);
            bytes32 beforeState = _stateDigest();
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(LowestMintGame.InexactSwapInput.selector, -inputs[i]));
            game.mint{value: PRICE}();
            assertEq(_stateDigest(), beforeState);
        }
        manager.setInput(int128(uint128(SWAP)));
        (uint256 id,) = _mint(bob, 400);
        assertEq(id, 2);
        assertEq(game.rewardPool(), 2 * REWARD);
    }

    function test_minimumSignedOutputCannotWrapIntoAHugeReceipt() public {
        _mint(alice, 500);
        manager.setOutput(type(int128).min);
        bytes32 beforeState = _stateDigest();
        vm.prank(bob);
        vm.expectRevert(LowestMintGame.InvalidSwapOutput.selector);
        game.mint{value: PRICE}();
        assertEq(_stateDigest(), beforeState);
        (uint256 id, uint256 received) = _mint(bob, 100);
        assertEq(id, 2);
        assertEq(received, 100);
        assertEq(game.leader(), bob);
    }

    function test_maximumSignedReceiptAndAggregateAboveUint128AreNotTruncated() public {
        uint256 maximum = uint256(uint128(type(int128).max));
        token.mint(address(manager), maximum * 3);
        vm.prank(owner);
        game.configurePool(key, maximum);
        for (uint256 i; i < 3; ++i) {
            (uint256 id, uint256 received) = _mint(alice, type(int128).max);
            assertEq(id, i + 1);
            assertEq(received, maximum);
        }
        assertGt(3 * maximum, type(uint128).max);
        assertEq(game.totalTokensReceived(alice), maximum * 3);
        assertEq(token.balanceOf(alice), maximum * 3);
        assertEq(game.lowestTokens(), maximum);
        assertEq(game.winningMintId(), 1);
        assertEq(game.rewardPool(), 3 * REWARD);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_fullPositiveInt128FloorIsInclusive(uint128 floorSeed) public {
        uint256 floor = bound(floorSeed, 1, uint256(uint128(type(int128).max)));
        token.mint(address(manager), floor * 2);
        vm.prank(owner);
        game.configurePool(key, floor);
        manager.setOutput(int128(uint128(floor - 1)));
        bytes32 beforeState = _stateDigest();
        vm.prank(alice);
        if (floor == 1) vm.expectRevert(LowestMintGame.InvalidSwapOutput.selector);
        else vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, floor - 1, floor));
        // A user minimum of one cannot bypass the configured floor.
        game.mint{value: PRICE}(1, block.timestamp);
        assertEq(_stateDigest(), beforeState);
        manager.setOutput(int128(uint128(floor)));
        vm.prank(alice);
        (uint256 id, uint256 received) = game.mint{value: PRICE}(1, block.timestamp);
        assertEq(id, 1);
        assertEq(received, floor);
        assertEq(token.balanceOf(alice), floor);
        beforeState = _stateDigest();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, floor, floor + 1));
        game.mint{value: PRICE}(floor + 1, block.timestamp);
        assertEq(_stateDigest(), beforeState);
    }

    function test_maximumUserMinimumRevertsWithoutTruncationAndCanRetry() public {
        _mint(alice, 1000);
        bytes32 beforeState = _stateDigest();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 1000, type(uint256).max));
        game.mint{value: PRICE}(type(uint256).max, type(uint256).max);
        assertEq(_stateDigest(), beforeState);
        vm.prank(bob);
        (uint256 id,) = game.mint{value: PRICE}(1000, type(uint256).max);
        assertEq(id, 2);
    }

    function test_failedFirstMintDoesNotStartTimerOrFreezeConfiguration() public {
        manager.setOutput(99);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 99, 100));
        game.mint{value: PRICE}();
        uint256 later = vm.getBlockTimestamp() + 45 days;
        vm.warp(later);
        vm.prank(owner);
        game.configurePool(key, 99);
        (uint256 id,) = _mint(bob, 99);
        assertEq(id, 1);
        assertEq(game.closesAt(), later + 30 days);
        assertEq(game.leader(), bob);
        assertEq(alice.balance, 100 ether);
    }

    function test_paymentForwarderIsPayerAndOriginCannotClaimItsPrize() public {
        PlayerWallet wallet = new PlayerWallet(game);
        wallet.setReceiveMode(PlayerWallet.ReceiveMode.Reject);
        manager.setOutput(100);
        vm.prank(alice, alice);
        wallet.enter{value: PRICE}();
        (address payer, uint256 received) = game.mints(1);
        assertEq(payer, address(wallet));
        assertEq(received, 100);
        assertEq(token.balanceOf(address(wallet)), 100);
        assertEq(token.balanceOf(alice), 0);
        assertEq(game.mintCountOf(alice), 0);
        assertEq(game.totalTokensReceived(alice), 0);
        assertEq(game.leader(), address(wallet));
        vm.warp(game.closesAt());
        game.finalize();
        vm.prank(alice, alice);
        vm.expectRevert(LowestMintGame.NotWinner.selector);
        game.claimRewards(payable(alice));
        wallet.claim(payable(bob));
        assertEq(bob.balance, 100 ether + REWARD);
        assertEq(game.totalRewardsPaid(), REWARD);
    }

    function test_tokenGiftsAndTransfersDoNotRewriteReceiptsOrWinner() public {
        token.mint(alice, 10_000);
        _mint(alice, 200);
        _mint(bob, 300);
        uint256 aliceTokens = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, aliceTokens);
        assertEq(token.balanceOf(alice), 0);
        _mint(alice, 500);
        assertEq(token.balanceOf(alice), 500);
        assertEq(game.totalTokensReceived(alice), 700);
        assertEq(game.totalTokensReceived(bob), 300);
        assertEq(game.leader(), alice);
        assertEq(game.lowestTokens(), 200);
        assertEq(game.winningMintId(), 1);
        (address payer, uint256 received) = game.mints(1);
        assertEq(payer, alice);
        assertEq(received, 200);
    }

    function test_configurationAndSettlementCannotReenterDuringTokenDelivery() public {
        // Give the token real owner authority so the configuration attempt reaches
        // the reentrancy guard rather than merely failing onlyOwner.
        vm.prank(owner);
        game.transferOwnership(address(token));
        vm.prank(address(token));
        game.acceptOwnership();
        bytes[3] memory calls = [
            abi.encodeCall(game.configurePool, (key, 200)),
            abi.encodeCall(game.finalize, ()),
            abi.encodeCall(game.claimRewards, (payable(address(token))))
        ];
        for (uint256 i; i < calls.length; ++i) {
            token.setReentry(address(game), calls[i]);
            _mint(alice, 500);
            assertFalse(token.reentrySucceeded());
            assertEq(
                token.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(game.minimumOutput(), 100);
            assertFalse(game.finalized());
        }
        assertEq(game.minted(), 3);
        assertEq(game.rewardPool(), 3 * REWARD);
    }

    function test_ownershipTransferAndRenunciationDoNotMovePrizeRights() public {
        PlayerWallet wallet = new PlayerWallet(game);
        wallet.setReceiveMode(PlayerWallet.ReceiveMode.Reject);
        manager.setOutput(100);
        wallet.enter{value: PRICE}();
        _mint(bob, 500);
        vm.prank(owner);
        game.transferOwnership(carol);
        vm.prank(carol);
        game.acceptOwnership();
        vm.prank(carol);
        vm.expectRevert(LowestMintGame.ConfigurationLocked.selector);
        game.configurePool(key, 1);
        vm.warp(game.closesAt());
        vm.prank(alice);
        game.finalize();
        vm.prank(carol);
        vm.expectRevert(LowestMintGame.NotWinner.selector);
        game.claimRewards(payable(carol));
        vm.prank(carol);
        game.renounceOwnership();
        assertEq(game.owner(), address(0));
        wallet.claim(payable(alice));
        assertEq(alice.balance, 100 ether + 2 * REWARD);
        assertEq(game.totalRewardsPaid(), 2 * REWARD);
        assertEq(game.leader(), address(wallet));
    }

    function test_failedReconfigurationLeavesLastValidConfigurationUsable() public {
        vm.prank(owner);
        game.configurePool(key, 200);
        manager.setInitialized(false);
        vm.prank(owner);
        vm.expectRevert(LowestMintGame.PoolNotInitialized.selector);
        game.configurePool(key, 300);
        manager.setInitialized(true);
        assertEq(game.minimumOutput(), 200);
        assertTrue(game.configured());
        _mint(alice, 200);
        assertEq(game.lowestTokens(), 200);
    }

    function test_finalizationEventsIncludeLastContributionAndDeferredClaimRecipient() public {
        PlayerWallet wallet = new PlayerWallet(game);
        wallet.setReceiveMode(PlayerWallet.ReceiveMode.Reject);
        manager.setOutput(100);
        wallet.enter{value: PRICE}();
        for (uint256 i; i < 98; ++i) {
            _mint(bob, 500);
        }
        vm.expectEmit(true, true, false, true, address(game));
        emit LowestMintGame.GameFinalized(address(wallet), 1, 2 ether, true);
        vm.expectEmit(true, false, false, true, address(game));
        emit LowestMintGame.RewardDeferred(address(wallet), 2 ether);
        vm.prank(carol);
        game.mint{value: PRICE}();
        assertEq(game.minted(), 100);
        assertEq(game.pendingReward(), 2 ether);
        vm.expectEmit(true, true, false, true, address(game));
        emit LowestMintGame.RewardPaid(address(wallet), alice, 2 ether);
        wallet.claim(payable(alice));
        assertEq(alice.balance, 102 ether);
    }

    function test_timeoutFinalizationEventDistinguishesUnsoldGame() public {
        _mint(alice, 500);
        _mint(bob, 400);
        vm.warp(game.closesAt());
        vm.expectEmit(true, true, false, true, address(game));
        emit LowestMintGame.GameFinalized(bob, 2, 2 * REWARD, false);
        vm.expectEmit(true, true, false, true, address(game));
        emit LowestMintGame.RewardPaid(bob, bob, 2 * REWARD);
        game.finalize();
        assertEq(bob.balance, 100 ether - PRICE + 2 * REWARD);
    }

    function _setFault(uint8 fault) private returns (bytes memory expected) {
        if (fault == 0) {
            manager.setCallbackMode(true, false);
            return abi.encodeWithSelector(LowestMintGame.CallbackNotCompleted.selector);
        }
        if (fault == 1) {
            manager.setCallbackMode(false, true);
            return abi.encodeWithSelector(LowestMintGame.UnauthorizedCallback.selector);
        }
        if (fault == 2) {
            manager.setFailSwap(true);
            return abi.encodeWithSignature("Error(string)", "swap failed");
        }
        if (fault == 3) {
            manager.setWrongSettlement(true);
            return abi.encodeWithSelector(LowestMintGame.InexactSettlement.selector);
        }
        if (fault == 4 || fault == 5) {
            int128 input = fault == 4 ? int128(0) : int128(uint128(SWAP + 1));
            manager.setInput(input);
            return abi.encodeWithSelector(LowestMintGame.InexactSwapInput.selector, -input);
        }
        if (fault == 6 || fault == 7) {
            manager.setOutput(fault == 6 ? int128(0) : int128(-1));
            return abi.encodeWithSelector(LowestMintGame.InvalidSwapOutput.selector);
        }
        if (fault == 8 || fault == 9) {
            token.setMode(fault == 8 ? MockIMD.TransferMode.Taxed : MockIMD.TransferMode.Bonus);
            return abi.encodeWithSelector(LowestMintGame.InexactTokenReceipt.selector);
        }
        if (fault == 10 || fault == 11) {
            token.setMode(fault == 10 ? MockIMD.TransferMode.ReturnsFalse : MockIMD.TransferMode.Reverts);
            return abi.encodeWithSignature("Error(string)", "token transfer failed");
        }
        manager.setOutput(99);
        return abi.encodeWithSelector(LowestMintGame.TooFewTokens.selector, 99, 100);
    }

    function _resetDependencies() private {
        manager.setCallbackMode(false, false);
        manager.setFailSwap(false);
        manager.setWrongSettlement(false);
        manager.setInput(int128(uint128(SWAP)));
        token.setMode(MockIMD.TransferMode.Normal);
    }

    function _stateDigest() private view returns (bytes32 state) {
        state = keccak256(
            abi.encode(game.minted(), game.closesAt(), game.leader(), game.lowestTokens(), game.winningMintId())
        );
        state = keccak256(
            abi.encode(state, game.rewardPool(), game.pendingReward(), game.totalRewardsPaid(), game.finalized())
        );
        state = keccak256(abi.encode(state, game.minimumOutput(), game.configured(), game.owner(), game.pendingOwner()));
        state = keccak256(
            abi.encode(
                state,
                address(game).balance,
                address(manager).balance,
                token.balanceOf(address(manager)),
                token.totalSupply()
            )
        );
        state = keccak256(abi.encode(state, manager.swapCalls(), manager.settled(), manager.syncedNative()));
        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < players.length; ++i) {
            address payer = players[i];
            state = keccak256(
                abi.encode(
                    state,
                    payer.balance,
                    token.balanceOf(payer),
                    game.mintCountOf(payer),
                    game.totalTokensReceived(payer)
                )
            );
        }
        // Include the first unused ID to detect a failed call leaving a phantom receipt.
        for (uint256 i; i <= game.minted() + 1; ++i) {
            (address payer, uint256 amount) = game.mints(i);
            state = keccak256(abi.encode(state, payer, amount));
        }
    }
}
