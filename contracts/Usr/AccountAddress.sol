pragma solidity >=0.6.11;

import '../Uniswap/TransferHelper.sol';
import '../ERC20/IERC20.sol';

contract AccountAddress {
    address private owner;
    constructor() public {
        owner = msg.sender;
    }
    modifier _onlyOwner() {
        require(
            msg.sender == owner,
            "Only owner can call this."
        );
        _;
    }
    //    receive() external payable {
    //
    //    }

    function transfer(address token, address to, uint256 amount) external _onlyOwner {
        IERC20(token).approve(msg.sender, amount);
        TransferHelper.safeTransfer(token, to, amount);
    }
}