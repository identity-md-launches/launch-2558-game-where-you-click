// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LowestMintGame} from "../src/LowestMintGame.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract LaunchCompatibilityTest is Test {
    function test_emptyChainDeploymentHasBoundedRuntimeAndNoEscapeOpcodes() public {
        address owner = makeAddr("explicit launch owner");
        // The real mainnet dependency has no code in this empty-chain test.
        IPoolManager manager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertEq(address(manager).code.length, 0);
        LowestMintGame game = new LowestMintGame(owner, manager);
        assertEq(game.owner(), owner);
        bytes memory code = address(game).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        assertLe(type(LowestMintGame).creationCode.length + 64, 49_152);
        // Mirrors the supplied protected runtime floor, without environment variables.
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
