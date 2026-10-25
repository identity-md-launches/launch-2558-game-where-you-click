// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LowestMintGame} from "../../src/LowestMintGame.sol";
import {MockIMD, MockPoolManager} from "./Mocks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

abstract contract GameFixture is Test {
    LowestMintGame internal game;
    MockIMD internal token;
    MockPoolManager internal manager;
    PoolKey internal key;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    uint256 internal constant PRICE = 0.1 ether;
    uint256 internal constant SWAP = 0.08 ether;
    uint256 internal constant REWARD = 0.02 ether;

    function setUp() public virtual {
        vm.warp(1_000_000);
        manager = new MockPoolManager();
        token = new MockIMD();
        game = new LowestMintGame(owner, IPoolManager(address(manager)));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        token.mint(address(manager), 1e36);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(address(this), 100 ether);
        vm.prank(owner);
        game.configurePool(key, 100);
    }

    function _mint(address payer, int128 output) internal returns (uint256 id, uint256 amount) {
        manager.setOutput(output);
        vm.prank(payer);
        return game.mint{value: PRICE}();
    }

    function _fill(address payer, int128 output) internal {
        manager.setOutput(output);
        while (game.minted() < game.MAX_MINTS()) {
            vm.prank(payer);
            game.mint{value: PRICE}();
        }
    }

    function _assertEmpty() internal view {
        assertEq(game.minted(), 0);
        assertEq(game.rewardPool(), 0);
        assertEq(game.pendingReward(), 0);
        assertEq(game.closesAt(), 0);
        assertEq(game.leader(), address(0));
        assertEq(address(game).balance, 0);
        assertEq(address(manager).balance, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(game.mintCountOf(alice), 0);
        assertEq(manager.swapCalls(), 0);
        assertEq(alice.balance, 100 ether);
    }
}
