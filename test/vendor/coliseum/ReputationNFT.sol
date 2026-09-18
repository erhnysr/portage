// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Soulbound ERC-721 minted to Arena winners. Non-transferable after mint.
contract ReputationNFT is ERC721, Ownable {
    struct WinRecord {
        address arena;
        string category;
        uint8 rank; // 1, 2, or 3
        uint256 timestamp;
    }

    // ArenaFactory address — only factory can authorize arenas
    address public factory;

    // Per-arena authorization: set by factory when arena is deployed
    mapping(address => bool) public authorizedArenas;

    uint256 private _nextTokenId;

    mapping(uint256 => WinRecord) public winRecords;
    mapping(address => uint256[]) private _tokensByOwner;

    event WinnerMinted(address indexed to, uint256 indexed tokenId, address arena, uint8 rank);
    event ArenaAuthorized(address indexed arena);

    modifier onlyFactory() {
        require(msg.sender == factory, "ReputationNFT: caller is not factory");
        _;
    }

    modifier onlyArena() {
        require(authorizedArenas[msg.sender], "ReputationNFT: caller is not authorized arena");
        _;
    }

    constructor(address initialOwner) ERC721("Coliseum Reputation", "CREP") Ownable(initialOwner) {}

    /// @notice Called once by owner after ArenaFactory is deployed
    function setFactory(address _factory) external onlyOwner {
        require(factory == address(0), "ReputationNFT: factory already set");
        require(_factory != address(0), "ReputationNFT: zero address");
        factory = _factory;
    }

    /// @notice Called by ArenaFactory when a new Arena is deployed
    function authorizeArena(address arena) external onlyFactory {
        require(arena != address(0), "ReputationNFT: zero arena");
        authorizedArenas[arena] = true;
        emit ArenaAuthorized(arena);
    }

    /// @notice Mint a soulbound win badge. Called directly by Arena after finalize().
    function mint(
        address to,
        address arena,
        string calldata category,
        uint8 rank
    ) external onlyArena returns (uint256 tokenId) {
        require(to != address(0), "ReputationNFT: mint to zero address");
        require(rank >= 1 && rank <= 3, "ReputationNFT: invalid rank");

        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);

        winRecords[tokenId] = WinRecord({
            arena: arena,
            category: category,
            rank: rank,
            timestamp: block.timestamp
        });
        _tokensByOwner[to].push(tokenId);

        emit WinnerMinted(to, tokenId, arena, rank);
    }

    /// @notice Returns all win records for a given owner.
    function getWinRecords(address owner) external view returns (WinRecord[] memory records) {
        uint256[] storage ids = _tokensByOwner[owner];
        records = new WinRecord[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            records[i] = winRecords[ids[i]];
        }
    }

    function getTokensByOwner(address owner) external view returns (uint256[] memory) {
        return _tokensByOwner[owner];
    }

    // ────────────────────────────────────────────────────────────────
    // Soulbound: block all transfers after mint
    // OZ 5.x uses _update hook for all token movements
    // ────────────────────────────────────────────────────────────────
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        // from == address(0) means this is a mint — allow it
        require(from == address(0), "ReputationNFT: soulbound, non-transferable");
    }

    /// @notice On-chain token URI with minimal SVG encoding rank + category.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        WinRecord memory rec = winRecords[tokenId];

        string memory rankStr = rec.rank == 1 ? "1st" : rec.rank == 2 ? "2nd" : "3rd";
        string memory color = rec.rank == 1 ? "#FFD700" : rec.rank == 2 ? "#C0C0C0" : "#CD7F32";

        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300">',
            '<rect width="300" height="300" fill="#0a0a0a"/>',
            '<text x="150" y="80" font-size="48" text-anchor="middle" fill="',
            color,
            '">',
            rankStr,
            "</text>",
            '<text x="150" y="150" font-size="14" text-anchor="middle" fill="#ffffff">',
            rec.category,
            "</text>",
            '<text x="150" y="200" font-size="11" text-anchor="middle" fill="#888888">Coliseum</text>',
            "</svg>"
        );

        string memory json = string.concat(
            '{"name":"Coliseum ',
            rankStr,
            ' - ',
            rec.category,
            '","description":"Soulbound win badge from Coliseum arena.","image":"data:image/svg+xml;utf8,',
            svg,
            '"}'
        );

        return string.concat("data:application/json;utf8,", json);
    }
}
