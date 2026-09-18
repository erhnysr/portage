// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/arena/ReputationNFT.sol";

contract ReputationNFTTest is Test {
    ReputationNFT internal repNFT;
    address internal owner = address(0x1);
    address internal factory = address(0x2);
    address internal testArena = address(0x3); // authorized arena used for mint tests
    address internal winner = address(0x4);
    address internal unauthorizedCaller = address(0x9);

    function setUp() public {
        vm.prank(owner);
        repNFT = new ReputationNFT(owner);

        vm.prank(owner);
        repNFT.setFactory(factory);

        // Authorize testArena to mint (simulates ArenaFactory.createArena)
        vm.prank(factory);
        repNFT.authorizeArena(testArena);
    }

    // ── setFactory ────────────────────────────────────────────────

    function test_setFactory_onlyOwner() public {
        ReputationNFT fresh = new ReputationNFT(owner);
        // test contract is not owner, so this should revert
        vm.expectRevert();
        fresh.setFactory(factory);
    }

    function test_setFactory_cannotSetTwice() public {
        vm.prank(owner);
        vm.expectRevert("ReputationNFT: factory already set");
        repNFT.setFactory(address(0x99));
    }

    // ── authorizeArena ────────────────────────────────────────────

    function test_authorizeArena_onlyFactory() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert("ReputationNFT: caller is not factory");
        repNFT.authorizeArena(address(0xAB));
    }

    function test_authorizeArena_zeroAddress() public {
        vm.prank(factory);
        vm.expectRevert("ReputationNFT: zero arena");
        repNFT.authorizeArena(address(0));
    }

    function test_authorizeArena_setsMapping() public {
        address newArena = address(0xAB);
        vm.prank(factory);
        repNFT.authorizeArena(newArena);
        assertTrue(repNFT.authorizedArenas(newArena));
    }

    // ── mint ──────────────────────────────────────────────────────

    function test_mint_onlyAuthorizedArena() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert("ReputationNFT: caller is not authorized arena");
        repNFT.mint(winner, testArena, "Best Meme", 1);
    }

    function test_mint_success() public {
        vm.prank(testArena);
        uint256 tokenId = repNFT.mint(winner, testArena, "Best Meme", 1);

        assertEq(repNFT.ownerOf(tokenId), winner);
        (address a, string memory cat, uint8 rank, ) = repNFT.winRecords(tokenId);
        assertEq(a, testArena);
        assertEq(cat, "Best Meme");
        assertEq(rank, 1);
    }

    function test_mint_allRanks() public {
        address[3] memory winners_ = [address(0x10), address(0x11), address(0x12)];
        for (uint8 i = 1; i <= 3; i++) {
            vm.prank(testArena);
            repNFT.mint(winners_[i - 1], testArena, "Test", i);
        }
        assertEq(repNFT.balanceOf(winners_[0]), 1);
        assertEq(repNFT.balanceOf(winners_[1]), 1);
        assertEq(repNFT.balanceOf(winners_[2]), 1);
    }

    function test_mint_invalidRank() public {
        vm.prank(testArena);
        vm.expectRevert("ReputationNFT: invalid rank");
        repNFT.mint(winner, testArena, "Test", 0);

        vm.prank(testArena);
        vm.expectRevert("ReputationNFT: invalid rank");
        repNFT.mint(winner, testArena, "Test", 4);
    }

    function test_mint_zeroAddress() public {
        vm.prank(testArena);
        vm.expectRevert("ReputationNFT: mint to zero address");
        repNFT.mint(address(0), testArena, "Test", 1);
    }

    // ── soulbound ─────────────────────────────────────────────────

    function test_transfer_reverts() public {
        vm.prank(testArena);
        uint256 tokenId = repNFT.mint(winner, testArena, "Best Meme", 1);

        vm.prank(winner);
        vm.expectRevert("ReputationNFT: soulbound, non-transferable");
        repNFT.transferFrom(winner, address(0x99), tokenId);
    }

    function test_safeTransfer_reverts() public {
        vm.prank(testArena);
        uint256 tokenId = repNFT.mint(winner, testArena, "Best Meme", 1);

        vm.prank(winner);
        vm.expectRevert("ReputationNFT: soulbound, non-transferable");
        repNFT.safeTransferFrom(winner, address(0x99), tokenId);
    }

    // ── getWinRecords ─────────────────────────────────────────────

    function test_getWinRecords_multiple() public {
        address arena2 = address(0x5);
        vm.prank(factory);
        repNFT.authorizeArena(arena2);

        vm.prank(testArena);
        repNFT.mint(winner, testArena, "Meme", 1);
        vm.prank(arena2);
        repNFT.mint(winner, arena2, "Joke", 2);

        ReputationNFT.WinRecord[] memory records = repNFT.getWinRecords(winner);
        assertEq(records.length, 2);
        assertEq(records[0].rank, 1);
        assertEq(records[1].rank, 2);
    }

    // ── tokenURI ──────────────────────────────────────────────────

    function test_tokenURI_returns_dataURI() public {
        vm.prank(testArena);
        uint256 tokenId = repNFT.mint(winner, testArena, "Best Meme", 1);

        string memory uri = repNFT.tokenURI(tokenId);
        // Starts with "data:application/json"
        assertEq(bytes(uri)[0], bytes("d")[0]);
        assertTrue(bytes(uri).length > 50);
    }
}
