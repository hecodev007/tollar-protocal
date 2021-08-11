// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;
pragma experimental ABIEncoderV2;


import "../Common/Context.sol";
import "../ERC20/IERC20.sol";
import "../ERC20/ERC20Custom.sol";
import "../ERC20/ERC20.sol";
import "../Math/SafeMath.sol";
import "../Staking/Owned.sol";
import "../TAR/TAR.sol";
import "./Pools/UsrPool.sol";
import "../Oracle/UniswapPairOracle.sol";
import "../Oracle/ChainlinkETHUSDPriceConsumer.sol";
import "../Governance/AccessControl.sol";
import './UsrIncentive.sol';

contract UsrStablecoin is ERC20Custom, AccessControl, Owned {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    ChainlinkETHUSDPriceConsumer private eth_usd_pricer;
    uint8 private eth_usd_pricer_decimals;
    UniswapPairOracle private tarUsrOracle;
    UniswapPairOracle private usrUsdOracle;
    UniswapPairOracle private tarUsr24HOracle;
    UniswapPairOracle private usrUsd24HOracle;
    string public symbol;
    string public name;
    uint8 public constant decimals = 18;

    address public creator_address;
    address public timelock_address; // Governance timelock address
    address public controller_address; // Controller contract to dynamically adjust system parameters automatically
    address public tar_address;
    address public tar_usr_oracle_address;
    address public usr_usd_oracle_address;
    address public tar_usr_24H_oracle_address;
    address public usr_usd_24H_oracle_address;
    address public weth_address;
    address public eth_usd_consumer_address;

    uint256 public constant genesis_supply = 2000000e18; // 2M Usr (only for testing, genesis supply will be 5k on Mainnet). This is to help with establishing the Uniswap pools, as they need liquidity
    // uint32  private blockTimestampLast;
    // The addresses in this array are added by the oracle and these contracts are able to mint Usr
    address[] public Usr_pools_array;

    // Mapping is also used for faster verification
    mapping(address => bool) public Usr_pools;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;

    uint256 public global_collateral_ratio; // 6 decimals of precision, e.g. 924102 = 0.924102
    uint256 public redemption_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256 public minting_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256 public Usr_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public price_target; // The price of Usr at which the collateral ratio will respond to; this value is only used for the collateral ratio mechanism and not for minting and redeeming which are hardcoded at $1
    uint256 public price_band; // The bound above and below the price target at which the refreshCollateralRatio() will not change the collateral ratio

    address public DEFAULT_ADMIN_ADDRESS;
    bytes32 public constant COLLATERAL_RATIO_PAUSER = keccak256("COLLATERAL_RATIO_PAUSER");
    bool public collateral_ratio_paused = false;

    address private incentive;
    UsrIncentive private usrIncentive;
    bool private isOracleReady = false;
    /* ========== MODIFIERS ========== */


    modifier onlyIncentive() {
        require(incentive == msg.sender, "only Incentive");
        _;
    }
    modifier onlyCollateralRatioPauser() {
        require(hasRole(COLLATERAL_RATIO_PAUSER, msg.sender));
        _;
    }

    modifier onlyPools() {
        require(Usr_pools[msg.sender] == true, "Only Usr pools can call this function");
        _;
    }

    modifier onlyByOwnerGovernanceOrController() {
        require(msg.sender == owner || msg.sender == timelock_address || msg.sender == controller_address, "You are not the owner, controller, or the governance timelock");
        _;
    }

    modifier onlyByOwnerGovernanceOrPool() {
        require(
            msg.sender == owner
            || msg.sender == timelock_address
            || Usr_pools[msg.sender] == true,
            "You are not the owner, the governance timelock, or a pool");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        address _creator_address,
        address _timelock_address
    ) public Owned(_creator_address){
        require(_timelock_address != address(0), "Zero address detected");
        name = _name;
        symbol = _symbol;
        creator_address = _creator_address;
        timelock_address = _timelock_address;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        DEFAULT_ADMIN_ADDRESS = _msgSender();
        _mint(creator_address, genesis_supply);
        grantRole(COLLATERAL_RATIO_PAUSER, creator_address);
        grantRole(COLLATERAL_RATIO_PAUSER, timelock_address);
        Usr_step = 2500;
        // 6 decimals of precision, equal to 0.25%
        global_collateral_ratio = 1000000;
        // Usr system starts off fully collateralized (6 decimals of precision)
        refresh_cooldown = 3600;
        // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 1000000;
        // Collateral ratio will adjust according to the $1 price target at genesis
        price_band = 5000;
        // Collateral ratio will not adjust if between $0.995 and $1.005 at genesis

        // intensiveAddress = createContract("intensiveAddress");
    }


    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        usrIncentive.incentiveTransfer(sender, recipient, amount);
    }

    function superTransfer(
        address sender,
        address recipient,
        uint256 amount) public onlyIncentive {
        super._transfer(sender, recipient, amount);
    }

    function superBalanceOf(
        address account
    ) public view onlyIncentive
    returns (uint256)
    {
        return super.balanceOf(account);
    }

    function usrUsd24HOracleUpdate() public onlyIncentive {
        usrUsd24HOracle.update();
    }

    function usrUsd24HOracleCanUpdate() public view onlyIncentive
    returns (bool){
        return usrUsd24HOracle.canUpdate();
    }

    function tarUsr24HOracleUpdate() public onlyIncentive {
        tarUsr24HOracle.update();
    }

    function tarUsr24HOracleCanUpdate() public view onlyIncentive
    returns (bool){
        return tarUsr24HOracle.canUpdate();
    }


    /* ========== VIEWS ========== */

    function tar_usd_price() public view returns (uint256) {
        //1e6 precision
        uint256 price_tar_usr = uint256(tarUsrOracle.consultRealtime(tar_address, 1e18));
        uint256 price_usr_usd = uint256(usrUsdOracle.consultRealtime(address(this), 1e18));
        return price_tar_usr.mul(price_usr_usd).div(1e18);
    }

    function Usr_price() public view returns (uint256) {
        return uint256(usrUsdOracle.consultRealtime(address(this), 1e18));
    }

    function tar_usd_24H_price() public view returns (uint256) {
        //1e6 precision
        uint256 price_tar_usr_24H = uint256(tarUsr24HOracle.consult(tar_address, PRICE_PRECISION));
        uint256 price_usr_usd_24H = uint256(usrUsd24HOracle.consult(address(this), PRICE_PRECISION));
        return price_tar_usr_24H.mul(price_usr_usd_24H).div(PRICE_PRECISION);
    }


    function eth_usd_price() public view returns (uint256) {
        return uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
    }

    // This is needed to avoid costly repeat calls to different getter functions
    // It is cheaper gas-wise to just dump everything and only use some of the info
    function Usr_info() public view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
        Usr_price(), // Usr_price()
        tar_usd_price(), // TAR_price()
        totalSupply(), // totalSupply()
        global_collateral_ratio, // global_collateral_ratio()
        globalCollateralValue(), // globalCollateralValue
        minting_fee, // minting_fee()
        redemption_fee, // redemption_fee()
        uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals) //eth_usd_price
        );
    }

    // Iterate through all Usr pools and calculate all value of collateral in all pools globally
    function globalCollateralValue() public view returns (uint256) {
        uint256 total_collateral_value_d18 = 0;

        for (uint i = 0; i < Usr_pools_array.length; i++) {
            // Exclude null addresses
            if (Usr_pools_array[i] != address(0)) {
                total_collateral_value_d18 = total_collateral_value_d18.add(UsrPool(Usr_pools_array[i]).collatDollarBalance());
            }

        }
        return total_collateral_value_d18;
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called
    function refreshCollateralRatio() public {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 Usr_price_cur = Usr_price();
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        // Step increments are 0.25% (upon genesis, changable by setUsrStep())

        if (Usr_price_cur > price_target.add(price_band)) {//decrease collateral ratio
            if (global_collateral_ratio <= Usr_step) {//if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(Usr_step);
            }
        } else if (Usr_price_cur < price_target.sub(price_band)) {//increase collateral ratio
            if (global_collateral_ratio.add(Usr_step) >= 1000000) {
                global_collateral_ratio = 1000000;
                // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio.add(Usr_step);
            }
        }

        last_call_time = block.timestamp;
        // Set the time of the last expansion

        emit CollateralRatioRefreshed(global_collateral_ratio);
    }

    function GetMintFractionalUSROutMin(uint256 collateral_amount,address pool) public view returns (uint256, uint256) {
        uint256 tar_price = tar_usd_price();
        uint256 global_collateral_ratio = global_collateral_ratio;

        uint256 collateral_amount_d18 = collateral_amount * (10 ** UsrPool(pool).missing_decimals);

        uint256 c_dollar_value_d18 = collateral_amount_d18.mul(UsrPool(pool).getCollateralPrice()).div(1e6);
        uint calculated_tar_dollar_value_d18 =
        (c_dollar_value_d18.mul(1e6).div(global_collateral_ratio))
        .sub(c_dollar_value_d18);
        uint tar_needed = calculated_tar_dollar_value_d18.mul(1e6).div(tar_price);
        uint256 mint_amount = c_dollar_value_d18.add(calculated_tar_dollar_value_d18);
        mint_amount = (mint_amount.mul(uint(1e6).sub(minting_fee))).div(1e6);
        return (mint_amount, tar_needed);
    }


    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount) public onlyPools {
        super._burnFrom(b_address, b_amount);
        emit UsrBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other Usr pools will call to mint new Usr
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit UsrMinted(msg.sender, m_address, m_amount);
    }

    // Adds collateral addresses supported, such as tether and busd, must be ERC20
    function addPool(address pool_address) public onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");

        require(Usr_pools[pool_address] == false, "address already exists");
        Usr_pools[pool_address] = true;
        Usr_pools_array.push(pool_address);

        emit PoolAdded(pool_address);
    }

    function setIncentive(address _incentive) public onlyByOwnerGovernanceOrController {
        incentive = _incentive;
        usrIncentive = UsrIncentive(_incentive);
    }

    function setGlobalCollateralRatioForTest(uint256 ratio) public onlyByOwnerGovernanceOrController {
        global_collateral_ratio = ratio;
    }
    // Remove a pool
    function removePool(address pool_address) public onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");

        require(Usr_pools[pool_address] == true, "address doesn't exist already");

        // Delete from the mapping
        delete Usr_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < Usr_pools_array.length; i++) {
            if (Usr_pools_array[i] == pool_address) {
                Usr_pools_array[i] = address(0);
                // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        emit PoolRemoved(pool_address);
    }

    function setRedemptionFee(uint256 red_fee) public onlyByOwnerGovernanceOrController {
        redemption_fee = red_fee;

        emit RedemptionFeeSet(red_fee);
    }

    function setMintingFee(uint256 min_fee) public onlyByOwnerGovernanceOrController {
        minting_fee = min_fee;

        emit MintingFeeSet(min_fee);
    }

    function setUsrStep(uint256 _new_step) public onlyByOwnerGovernanceOrController {
        Usr_step = _new_step;

        emit UsrStepSet(_new_step);
    }

    function setPriceTarget(uint256 _new_price_target) public onlyByOwnerGovernanceOrController {
        price_target = _new_price_target;

        emit PriceTargetSet(_new_price_target);
    }

    function setRefreshCooldown(uint256 _new_cooldown) public onlyByOwnerGovernanceOrController {
        refresh_cooldown = _new_cooldown;

        emit RefreshCooldownSet(_new_cooldown);
    }

    function setTarAddress(address _tar_address) public onlyByOwnerGovernanceOrController {
        require(_tar_address != address(0), "Zero address detected");

        tar_address = _tar_address;

        emit TARAddressSet(_tar_address);
    }

    //0x8A753747A1Fa494EC906cE90E9f37563A8AF630e
    function setETHUSDOracle(address _eth_usd_consumer_address) public onlyByOwnerGovernanceOrController {
        require(_eth_usd_consumer_address != address(0), "Zero address detected");

        eth_usd_consumer_address = _eth_usd_consumer_address;
        eth_usd_pricer = ChainlinkETHUSDPriceConsumer(eth_usd_consumer_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();

        emit ETHUSDOracleSet(_eth_usd_consumer_address);
    }

    function setTimelock(address new_timelock) external onlyByOwnerGovernanceOrController {
        require(new_timelock != address(0), "Zero address detected");

        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    function setController(address _controller_address) external onlyByOwnerGovernanceOrController {
        require(_controller_address != address(0), "Zero address detected");

        controller_address = _controller_address;

        emit ControllerSet(_controller_address);
    }

    function setPriceBand(uint256 _price_band) external onlyByOwnerGovernanceOrController {
        price_band = _price_band;

        emit PriceBandSet(_price_band);
    }

    function setOracleAddress(address _tar_usr_oracle_address, address _usr_usd_oracle_address, address _tar_usr_24H_oracle_address, address _usr_usd_24H_oracle_address) public onlyByOwnerGovernanceOrController {
        require((_tar_usr_oracle_address != address(0)) && (_usr_usd_oracle_address != address(0)) && (_tar_usr_24H_oracle_address != address(0)) && (_usr_usd_24H_oracle_address != address(0)), "Zero address detected");

        tar_usr_oracle_address = _tar_usr_oracle_address;
        tarUsrOracle = UniswapPairOracle(_tar_usr_oracle_address);
        usr_usd_oracle_address = _usr_usd_oracle_address;
        usrUsdOracle = UniswapPairOracle(_usr_usd_oracle_address);
        tar_usr_24H_oracle_address = _tar_usr_24H_oracle_address;
        tarUsr24HOracle = UniswapPairOracle(_tar_usr_24H_oracle_address);
        usr_usd_24H_oracle_address = _usr_usd_24H_oracle_address;
        usrUsd24HOracle = UniswapPairOracle(_usr_usd_24H_oracle_address);
        isOracleReady = true;
    }

    function IsOracleReady() public view returns (bool){
        return isOracleReady == true;
    }

    function toggleCollateralRatio() public onlyCollateralRatioPauser {
        collateral_ratio_paused = !collateral_ratio_paused;

        emit CollateralRatioToggled(collateral_ratio_paused);
    }

    /* ========== EVENTS ========== */

    // Track Usr burned
    event UsrBurned(address indexed from, address indexed to, uint256 amount);

    // Track Usr minted
    event UsrMinted(address indexed from, address indexed to, uint256 amount);

    event CollateralRatioRefreshed(uint256 global_collateral_ratio);
    event PoolAdded(address pool_address);
    event PoolRemoved(address pool_address);
    event RedemptionFeeSet(uint256 red_fee);
    event MintingFeeSet(uint256 min_fee);
    event UsrStepSet(uint256 new_step);
    event PriceTargetSet(uint256 new_price_target);
    event RefreshCooldownSet(uint256 new_cooldown);
    event TARAddressSet(address _tar_address);
    event ETHUSDOracleSet(address eth_usd_consumer_address);
    event TimelockSet(address new_timelock);
    event ControllerSet(address controller_address);
    event PriceBandSet(uint256 price_band);
    event CollateralRatioToggled(bool collateral_ratio_paused);

}
