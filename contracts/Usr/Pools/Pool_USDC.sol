// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import "./UsrPool.sol";

contract Pool_USDC is UsrPool {
    address public USDC_address;
    uint256 private constant _pool_ceiling = 5e24;
    constructor(
        address _usr_contract_address,
        address _tar_contract_address,
        address _collateral_address,
        address _creator_address,
        address _timelock_address
    ) 
    UsrPool(_usr_contract_address, _tar_contract_address, _collateral_address, _creator_address, _timelock_address, _pool_ceiling)
    public {
        require(_collateral_address != address(0), "Zero address detected");

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        USDC_address = _collateral_address;
    }
}
