// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import "../ERC20Us.sol";
import "../../Common/Ownable.sol";
import "hardhat/console.sol";

contract UsToken is ERC20Us, Ownable {
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }
    constructor (string memory __name, string memory __symbol) public
    ERC20Us(__name, __symbol)
    {
        _mint(msg.sender, 2000000000e18);

    }
}