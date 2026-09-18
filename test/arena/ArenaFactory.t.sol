// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/arena/ArenaFactory.sol";
import "../../contracts/arena/ReputationNFT.sol";
import "../../contracts/arena/Arena.sol";

contract MockUSDCFactory is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Overrides the USDC constant so we can inject MockUSDC in tests
contract TestArenaFactory is ArenaFactory {
    address internal _testUsdc;

    constructor(address _repNFT, address testUsdc) ArenaFactory(_repNFT) {
        _testUsdc = testUsdc;
    }

    // Override the constant — expose for testing
    function usdcAddress() external view returns (address) {
        return USDC;
    }
}

contract ArenaFactoryTest is Test {
    MockUSDCFactory internal usdc;
    ReputationNFT internal repNFT;
    ArenaFactory internal factory;

    address internal owner = address(0x1);
    address internal creator = address(0x10);

    uint256 internal subDeadline;
    uint256 internal voteDeadline;

    function setUp() public {
        usdc = new MockUSDCFactory();

        vm.prank(owner);
        repNFT = new ReputationNFT(owner);

        factory = new ArenaFactory(address(repNFT));

        vm.prank(owner);
        repNFT.setFactory(address(factory));

        subDeadline = block.timestamp + 1 days;
        voteDeadline = block.timestamp + 2 days;

        usdc.mint(creator, 10_000_000);
    }

    // ── constructor ───────────────────────────────────────────────

    function test_constructor_zeroRepNFT_reverts() public {
        vm.expectRevert("ArenaFactory: zero repNFT");
        new ArenaFactory(address(0));
    }

    function test_usdc_address() public view {
        assertEq(factory.USDC(), 0x3600000000000000000000000000000000000000);
    }

    // ── createArena ───────────────────────────────────────────────

    function test_createArena_emptyTopic_reverts() public {
        vm.prank(creator);
        vm.expectRevert("ArenaFactory: empty topic");
        factory.createArena("", 0, subDeadline, voteDeadline);
    }

    function test_createArena_pastSubDeadline_reverts() public {
        vm.prank(creator);
        vm.expectRevert("ArenaFactory: submission deadline in past");
        factory.createArena("Test", 0, block.timestamp - 1, voteDeadline);
    }

    function test_createArena_votingBeforeSubmission_reverts() public {
        vm.prank(creator);
        vm.expectRevert("ArenaFactory: voting before submission");
        factory.createArena("Test", 0, subDeadline, subDeadline - 1);
    }

    function test_createArena_noPrizePool() public {
        vm.prank(creator);
        address arenaAddr = factory.createArena("Best Meme", 0, subDeadline, voteDeadline);
        assertTrue(arenaAddr != address(0));
        assertEq(factory.getArenaCount(), 1);
    }

    function test_createArena_incrementsCount() public {
        vm.prank(creator);
        factory.createArena("Test 1", 0, subDeadline, voteDeadline);
        vm.prank(creator);
        factory.createArena("Test 2", 0, subDeadline + 1, voteDeadline + 1);
        assertEq(factory.getArenaCount(), 2);
    }

    function test_createArena_registersCreator() public {
        vm.prank(creator);
        address arenaAddr = factory.createArena("Test", 0, subDeadline, voteDeadline);

        address[] memory byCreator = factory.getArenasByCreator(creator);
        assertEq(byCreator.length, 1);
        assertEq(byCreator[0], arenaAddr);
    }

    function test_createArena_returnsCorrectAddress() public {
        vm.prank(creator);
        address arenaAddr = factory.createArena("Test", 0, subDeadline, voteDeadline);

        address[] memory all = factory.getArenas();
        assertEq(all[0], arenaAddr);
    }

    function test_createArena_emitsEvent() public {
        vm.prank(creator);
        vm.expectEmit(false, true, false, false);
        emit ArenaFactory.ArenaCreated(address(0), creator, "Best Meme", 0, subDeadline, voteDeadline);
        factory.createArena("Best Meme", 0, subDeadline, voteDeadline);
    }

    function test_createArena_arenaHasCorrectTopic() public {
        vm.prank(creator);
        address arenaAddr = factory.createArena("Best Meme Contest", 0, subDeadline, voteDeadline);
        assertEq(Arena(arenaAddr).topic(), "Best Meme Contest");
    }

    function test_createArena_arenaHasCorrectCreator() public {
        vm.prank(creator);
        address arenaAddr = factory.createArena("Test", 0, subDeadline, voteDeadline);
        assertEq(Arena(arenaAddr).creator(), creator);
    }
}
