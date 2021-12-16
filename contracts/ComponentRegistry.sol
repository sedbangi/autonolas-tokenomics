// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ComponentRegistry is ERC721Enumerable, Ownable {
    using Counters for Counters.Counter;

    // Possible differentiation of component types
    enum ComponentType {CTYPE0, CTYPE1}

    struct Component {
        address developer;
        string componentHash; // can be obtained via mapping, consider for optimization
        string description;
        uint256[] dependencies;
        bool active;
        ComponentType componentType;
    }

    string public _BASEURI;
    Counters.Counter private _tokenIds;
    address private _minter;
    mapping (uint256 => Component) private _mapTokenIdComponent;
    mapping (string => uint256) private _mapHashTokenId;
    mapping(uint256 => bool) private _mapDependencies;

    // name = "agent components", symbol = "MECHCOMP"
    constructor(string memory _name, string memory _symbol, string memory _bURI) ERC721(_name, _symbol) {
        _tokenIds.increment();
        _setBaseURI(_bURI);
    }

    // Change the minter
    function changeMinter(address newMinter) public onlyOwner {
        _minter = newMinter;
    }

    // Set the component information
    function _setComponentInfo(uint256 tokenId, address developer, string memory componentHash,
        string memory description, uint256[] memory dependencies)
        private
    {
        Component memory component;
        component.developer = developer;
        component.componentHash = componentHash;
        component.description = description;
        component.dependencies = dependencies;
        component.active = true;
        _mapTokenIdComponent[tokenId] = component;
        _mapHashTokenId[componentHash] = tokenId;
    }

    // Mint component according to developer's address and component parameters
    function createComponent(address owner, address developer, string memory componentHash, string memory description,
        uint256[] memory dependencies)
        external
    {
        // Only the minter has a privilege to create a component
        require(_minter == msg.sender);

        // Check for the existent IPFS hashes
        require(_mapHashTokenId[componentHash] == 0, "The component with this hash already exists!");

        // Check for dependencies validity: must be already allocated, must not repeat
        uint256 iDep = 0;
        while (iDep < dependencies.length) {
            require(dependencies[iDep] <= _tokenIds.current(), "The component with token ID does not exist!");
            if (_mapDependencies[dependencies[iDep]]) {
                dependencies[iDep] = dependencies[dependencies.length - 1];
                delete dependencies[dependencies.length - 1];
            } else {
                _mapDependencies[dependencies[iDep]] = true;
                iDep++;
            }
        }
        for (iDep = 0; iDep < dependencies.length; iDep++) {
            _mapDependencies[dependencies[iDep]] = false;
        }

        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
        _safeMint(owner, newTokenId);
        _setComponentInfo(newTokenId, developer, componentHash, description, dependencies);
    }

    // Externalizing function to check for the token existence from a different contract
    function exists (uint256 _tokenId) external view returns (bool) {
        return _exists(_tokenId);
    }

    function _setBaseURI(string memory _bURI) internal {
        require(bytes(_bURI).length > 0, "Base URI can not be empty");
        _BASEURI = string(abi.encodePacked(_bURI, "/component/"));
    }

    function _baseURI() internal view override returns (string memory) {
        return _BASEURI;
    }

    // In order to burn, the inactive component needs to propagate its state to dependent components
    function _burn(uint256 tokenId) internal view override
    {
        require(ownerOf(tokenId) == msg.sender, "You have no priviledge to burn this token");
        // The functionality will follow in the following revisions
    }
}
