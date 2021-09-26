// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;


import "hardhat/console.sol";
import "../Common/Context.sol";
import "../ERC20/ERC20CustomV1.sol";
import "../ERC20/IERC20.sol";
import "../Usr/Usr.sol";
import "../Staking/Owned.sol";
import "../Math/SafeMath.sol";
import "../Governance/AccessControl.sol";
import '../Uniswap/TransferHelper.sol';

contract Tollar is ERC20CustomV1, AccessControl, Owned {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public USRStableCoinAddr;
    address public team_address;
    address public intensiveAddress;
    uint256 public constant genesis_supply = 100000000e18; // 100M is printed upon genesis

    address public timelock_address; // Governance timelock address
    UsrStablecoin private USR;

    bool public trackingVotes = true; // Tracking votes (only change if need to disable votes)
    struct BalanceInfo {
        uint256 balance;
        uint256 total;
        uint256 startTime;
        uint256 lockTime;
    }

    struct RoundInfo {
        uint256 balance;
        uint256 total;
        uint32 nTimes;
    }

    mapping(uint32 => mapping(address => BalanceInfo)) public Rounds;

    mapping(uint32 => mapping(address => RoundInfo)) public RoundsInfo;//round->addr->RoundInfo
    mapping(uint32 => mapping(uint32 => mapping(address => BalanceInfo))) public RoundMintDetail; //round->n times->addr->info
    uint32  public curRoundIndex = 0;
    uint256 private addWhiteListTime = 0;
    uint256 private lastAddWhiteListTime = 0;
    // A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint96 votes;
    }

    mapping(address => uint256) public lastMint;
    mapping(address => uint256) mintBalance;
    mapping(address => uint256) mintWithDraw;

    // A record of votes checkpoints for each account, by index
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;

    // The number of checkpoints for each account
    mapping(address => uint32) public numCheckpoints;

    uint256 public tar_supply = 0;

    /* ========== MODIFIERS ========== */

    modifier onlyPools() {
        require(USR.Usr_pools(msg.sender) == true, "Only usr pools can mint new USR");
        _;
    }

    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == owner || msg.sender == timelock_address, "You are not an owner or the governance timelock");
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

        timelock_address = _timelock_address;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _mint(_creator_address, genesis_supply);

        // Do a checkpoint for the owner
        _writeCheckpoint(_creator_address, 0, 0, uint96(genesis_supply));
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        super._transfer(sender, recipient, amount);
        emit BalanceChanged(sender, super.balanceOf(sender), recipient, super.balanceOf(recipient));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function currentBlockTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }

    function AddWhitelist(address[] memory whiteList, uint256[]  memory balances, bool isFinished) public onlyByOwnerOrGovernance {
        // 24 * 60 * 60
        uint32 dayTime = 10;
        if (curRoundIndex >= 1) {
            require(lastAddWhiteListTime + 30 * dayTime <= currentBlockTimestamp(), "interval of each round should be more than 1 month");
        }
        for (uint256 i = 0; i < whiteList.length; i++) {
            RoundsInfo[curRoundIndex][whiteList[i]] = RoundInfo(balances[i], balances[i], 0);
        }
        if (isFinished) {
            curRoundIndex = curRoundIndex + 1;
            //   addWhiteListTime = 0;
            lastAddWhiteListTime = currentBlockTimestamp();
        }
        console.log("AddWhitelist", curRoundIndex);
    }
    //    function AddWhitelist(address[] memory whiteList, uint256[]  memory balances, bool isFinished) public onlyByOwnerOrGovernance {
    //        if (curRoundIndex >= 1) {
    //            require(lastAddWhiteListTime + 30 * 24 * 60 * 60 <= currentBlockTimestamp(), "interval of each round should be more than 1 month");
    //        }
    //
    //        if (addWhiteListTime == 0) {
    //            addWhiteListTime = currentBlockTimestamp() + 1 hours;
    //        }
    //        for (uint256 i = 0; i < whiteList.length; i++) {
    //            Rounds[curRoundIndex][whiteList[i]] = BalanceInfo(balances[i], balances[i], addWhiteListTime, (curRoundIndex + 12) * 30);
    //        }
    //        if (isFinished) {
    //            curRoundIndex++;
    //            addWhiteListTime = 0;
    //            lastAddWhiteListTime = currentBlockTimestamp();
    //        }
    //        console.log("AddWhitelist", curRoundIndex);
    //    }

    function RoundMintInfo(address account) view public returns (uint256 total, uint256 mintedAmount, uint256 balance){
        uint256 _totalAmount;
        uint256 _mintedAmount;
        uint256 _balance;
        for (uint32 i = 0; i < curRoundIndex; i++) {
            uint256 total = RoundsInfo[i][account].total;
            uint256 balance = RoundsInfo[i][account].balance;
            uint256 nTimes = RoundsInfo[i][account].nTimes;
            _totalAmount = _totalAmount.add(total);
            if (nTimes < 10) {
                _balance = _balance.add(balance);
            }
            _mintedAmount = _mintedAmount.add(total.sub(balance));

        }
        return (_totalAmount, _mintedAmount, _balance);
    }

    //    function RoundMintAmount(address account) view public returns (uint256 total){
    //        // uint32 dayTime = 24 * 3600;
    //        uint32 dayTime = 60;
    //        for (uint32 i = 0; i < curRoundIndex; i++) {
    //            uint32 start = Rounds[i][account].startTime;
    //            uint32 curTime = currentBlockTimestamp();
    //            if (start == 0 || curTime < start + dayTime) {
    //                continue;
    //            }
    //            uint32 endTime = start + (i + 12) * 30 * dayTime;
    //            if (curTime > endTime) {
    //                curTime = endTime;
    //            }
    //            uint32 elapsedDay = (curTime - start) / dayTime;
    //            uint256 totalAmount = Rounds[i][account].total;
    //            uint256 mintAmount = totalAmount.mul(uint256(elapsedDay)).div(uint256((i + 12) * 30));
    //            uint256 mintedAmount = totalAmount.sub(Rounds[i][account].balance);
    //            if (mintAmount > mintedAmount) {
    //                total = total.add(mintAmount.sub(mintedAmount));
    //            }
    //        }
    //        total = total.add(mintBalance[msg.sender]);
    //    }

    function CanDrawAmount(address account) public view returns (uint256 total){
        uint256 total;
        uint256 dayTime = 10;
        uint256 curTime = currentBlockTimestamp();
        for (uint32 i = 0; i < curRoundIndex; i++) {
            uint32 nTimes = RoundsInfo[i][account].nTimes;
            if (nTimes == 0) {
                continue;
            }
            for (uint32 j = 1; j <= nTimes; j++) {
                BalanceInfo memory bl = RoundMintDetail[i][j][account];
                if (bl.startTime == 0 || curTime < bl.startTime + dayTime || bl.balance == 0) {
                    continue;
                }
                uint256 endTime = bl.startTime + (i + 12) * 30 * dayTime;
                if (curTime > endTime) {
                    curTime = endTime;
                }
                uint256 elapsedDay = (curTime - bl.startTime) / dayTime;
                uint256 drawAmount = bl.total.mul(elapsedDay).div(uint256((i + 12) * 30));
                uint256 drawedAmount = bl.total.sub(bl.balance);
                if (drawAmount > drawedAmount) {
                    total = total.add(drawAmount.sub(drawedAmount));
                    //change balance
                    // RoundMintDetail[i][j][account].balance = bl.total.sub(drawAmount);
                }
            }
        }
        return total;
    }

    function UnlockAmount(address account) internal returns (uint256 total){
        uint256 total;
        uint256 dayTime = 10;
        uint256 curTime = currentBlockTimestamp();
        for (uint32 i = 0; i < curRoundIndex; i++) {
            uint32 nTimes = RoundsInfo[i][account].nTimes;
            console.log("nTimes:",nTimes);
            if (nTimes == 0) {
                continue;
            }
            for (uint32 j = 1; j <= nTimes; j++) {
                BalanceInfo memory bl = RoundMintDetail[i][j][account];
                if (bl.startTime == 0 || curTime < bl.startTime + dayTime || bl.balance == 0) {
                    continue;
                }
                uint256 endTime = bl.startTime + (i + 12) * 30 * dayTime;
                if (curTime > endTime) {
                    curTime = endTime;
                }
                uint256 elapsedDay = (curTime - bl.startTime) / dayTime;
                uint256 drawAmount = bl.total.mul(elapsedDay).div(uint256((i + 12) * 30));
                total = total.add(drawAmount);
            }
        }
        return total;
    }

    function _CanDrawAmount(address account) internal returns (uint256 total){
        uint256 total;
        uint256 dayTime = 10;
        uint256 curTime = currentBlockTimestamp();
        for (uint32 i = 0; i < curRoundIndex; i++) {
            uint32 nTimes = RoundsInfo[i][account].nTimes;
            console.log("nTimes:",nTimes);
            if (nTimes == 0) {
                continue;
            }
            for (uint32 j = 1; j <= nTimes; j++) {
                BalanceInfo memory bl = RoundMintDetail[i][j][account];
                if (bl.startTime == 0 || curTime < bl.startTime + dayTime || bl.balance == 0) {
                    continue;
                }
                uint256 endTime = bl.startTime + (i + 12) * 30 * dayTime;
                if (curTime > endTime) {
                    curTime = endTime;
                }
                uint256 elapsedDay = (curTime - bl.startTime) / dayTime;
                uint256 drawAmount = bl.total.mul(elapsedDay).div(uint256((i + 12) * 30));
                uint256 drawedAmount = bl.total.sub(bl.balance);
                //console.log("_CanDrawAmount:",elapsedDay,drawAmount,drawedAmount);
                if (drawAmount > drawedAmount) {
                    total = total.add(drawAmount.sub(drawedAmount));
                    //change balance
                    RoundMintDetail[i][j][account].balance = bl.total.sub(drawAmount);
                }
            }
        }
        //console.log("_CanDrawAmount",total);
        return total;
    }


    function WithDrawMint() public {
        // require(mintWithDraw[msg.sender] > 0 && lastMint[msg.sender].add(1) <= block.number, "no balance to withdraw");
        uint256 drawAmount = _CanDrawAmount(msg.sender);
        require(drawAmount > 0, "drawAmount == 0");
        require(team_address != address(0) && intensiveAddress != address(0), "system param can not 0 address");
        if (curRoundIndex <= 10) {
            _mint(intensiveAddress, drawAmount.mul(30).div(100));
        } else {
            _mint(intensiveAddress, drawAmount.mul(20).div(100));
            _mint(team_address, drawAmount.mul(10).div(100));
        }
        _mint(msg.sender, drawAmount.sub(drawAmount.mul(30).div(100)));
        emit WithDrawMintOne(msg.sender, drawAmount);
        tar_supply = tar_supply.add(drawAmount);
        //mintWithDraw[msg.sender] = 0;

    }


    function _CanMintAmount(address account) public view returns (uint256 total){
        //console.log("curRoundIndex:", curRoundIndex);
        uint256 mintAmount;
        for (uint32 i = 0; i < curRoundIndex; i++) {
            uint256 total = RoundsInfo[i][account].total;
            uint256 balance = RoundsInfo[i][account].balance;
            uint256 nTimes = RoundsInfo[i][account].nTimes;

            if (total == 0 || balance == 0 || nTimes == 10) {
                //console.log("_CanMintAmount:", total, balance, nTimes);
                continue;
            }
            mintAmount = mintAmount.add(balance);
           // console.log("_CanMintAmount:", balance, mintAmount);
        }
        return mintAmount;
    }

    function RoundMint(uint256 amount) public {
        require(curRoundIndex > 0 && amount > 0, "round mint not begin ");
        // require(intensiveAddress != address(0), "system param can not 0 address");
        uint256 mintAmount = _CanMintAmount(msg.sender);
        require(mintAmount > 0, "mint amount not available ");
        uint256 realAmount = 0;
        if (mintAmount > amount) {
            realAmount = amount;
        } else {
            realAmount = mintAmount;
        }
        console.log("realAmount:", realAmount);

        TransferHelper.safeTransferFrom(USRStableCoinAddr, msg.sender, address(this), realAmount);

        uint256 tmpAmount = realAmount;
        uint256 curTime = currentBlockTimestamp();
        for (uint32 i = 0; i < curRoundIndex; i++) {
            uint256 total = RoundsInfo[i][msg.sender].total;
            uint256 balance = RoundsInfo[i][msg.sender].balance;
            uint32 nTimes = RoundsInfo[i][msg.sender].nTimes;
            if (total == 0 || balance == 0 || nTimes == 10) {
                continue;
            }
            RoundsInfo[i][msg.sender].nTimes = RoundsInfo[i][msg.sender].nTimes + 1;
            if (balance < tmpAmount) {
                RoundsInfo[i][msg.sender].balance = 0;
                tmpAmount = tmpAmount.sub(balance);
                RoundMintDetail[i][nTimes + 1][msg.sender] = BalanceInfo(balance, balance, curTime, (i + 12) * 30);
            } else {
                RoundsInfo[i][msg.sender].balance = balance.sub(tmpAmount);
                RoundMintDetail[i][nTimes + 1][msg.sender] = BalanceInfo(tmpAmount, tmpAmount, curTime, (i + 12) * 30);
                break;
            }
        }
        emit RoundMintOne(msg.sender, realAmount);
    }


    //    function _roundMintAmount(address account) internal returns (uint256 total){
    //        console.log("curRoundIndex:", curRoundIndex);
    //        // uint32 dayTime = 24 * 3600;
    //        uint32 dayTime = 60;
    //        for (uint32 i = 0; i < curRoundIndex; i++) {
    //            uint32 start = Rounds[i][account].startTime;
    //            uint32 curTime = currentBlockTimestamp();
    //            if (start == 0 || curTime < start + dayTime) {
    //                continue;
    //            }
    //            uint32 endTime = start + (i + 12) * 30 * dayTime;
    //            if (curTime > endTime) {
    //                curTime = endTime;
    //            }
    //            uint32 elapsedDay = (curTime - start) / dayTime;
    //            uint256 totalAmount = Rounds[i][account].total;
    //            uint256 mintAmount = totalAmount.mul(uint256(elapsedDay)).div(uint256((i + 12) * 30));
    //            uint256 mintedAmount = totalAmount.sub(Rounds[i][account].balance);
    //            if (mintAmount > mintedAmount) {
    //                total = total.add(mintAmount.sub(mintedAmount));
    //                //change balance
    //                Rounds[i][account].balance = totalAmount.sub(mintAmount);
    //            }
    //        }
    //        total = total.add(mintBalance[msg.sender]);
    //    }


    //    function RoundMint(uint256 amount) public {
    //        require(curRoundIndex > 0 && amount > 0, "round mint not begin ");
    //        require(intensiveAddress != address(0), "system param can not 0 address");
    //        uint256 mintAmount = _roundMintAmount(msg.sender);
    //        require(mintAmount > 0, "mint amount not available ");
    //        uint256 realAmount = 0;
    //        if (mintAmount > amount) {
    //            realAmount = amount;
    //        } else {
    //            realAmount = mintAmount;
    //        }
    //        console.log("realAmount:", realAmount);
    //
    //        TransferHelper.safeTransferFrom(USRStableCoinAddr, msg.sender, address(this), realAmount);
    //        mintWithDraw[msg.sender] = mintWithDraw[msg.sender].add(realAmount);
    //        mintBalance[msg.sender] = mintAmount.sub(realAmount);
    //        lastMint[msg.sender] = block.number;
    //        emit RoundMintOne(msg.sender, realAmount);
    //    }

    //    function WithDrawMint() public {
    //        require(mintWithDraw[msg.sender] > 0 && lastMint[msg.sender].add(1) <= block.number, "no balance to withdraw");
    //        require(team_address != address(0) && intensiveAddress != address(0), "system param can not 0 address");
    //        if (curRoundIndex <= 10) {
    //            _mint(intensiveAddress, mintWithDraw[msg.sender].mul(30).div(100));
    //        } else {
    //            _mint(intensiveAddress, mintWithDraw[msg.sender].mul(20).div(100));
    //            _mint(team_address, mintWithDraw[msg.sender].mul(10).div(100));
    //        }
    //        _mint(msg.sender, mintWithDraw[msg.sender].sub(mintWithDraw[msg.sender].mul(30).div(100)));
    //        emit WithDrawMintOne(msg.sender, mintWithDraw[msg.sender]);
    //        tar_supply = tar_supply.add(mintWithDraw[msg.sender]);
    //        mintWithDraw[msg.sender] = 0;
    //
    //    }

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        require(new_timelock != address(0), "Timelock address cannot be 0");
        timelock_address = new_timelock;
    }

    function setUSRAddress(address usr_contract_address) external onlyByOwnerOrGovernance {
        require(usr_contract_address != address(0), "Zero address detected");

        USR = UsrStablecoin(usr_contract_address);
        USRStableCoinAddr = usr_contract_address;
        emit USRAddressSet(usr_contract_address);
    }

    function mint(address to, uint256 amount) public onlyPools {
        _mint(to, amount);
        tar_supply = tar_supply.add(amount);
    }

    // This function is what other usr pools will call to mint new TAR (similar to the USR mint)
    function pool_mint(address m_address, uint256 m_amount) external onlyPools {
        if (trackingVotes) {
            uint32 srcRepNum = numCheckpoints[address(this)];
            uint96 srcRepOld = srcRepNum > 0 ? checkpoints[address(this)][srcRepNum - 1].votes : 0;
            uint96 srcRepNew = add96(srcRepOld, uint96(m_amount), "pool_mint new votes overflows");
            _writeCheckpoint(address(this), srcRepNum, srcRepOld, srcRepNew);
            // mint new votes
            trackVotes(address(this), m_address, uint96(m_amount));
        }

        super._mint(m_address, m_amount);
        tar_supply = tar_supply.add(m_amount);
        emit TARMinted(address(this), m_address, m_amount);
    }

    // This function is what other usr pools will call to burn TAR
    function pool_burn_from(address b_address, uint256 b_amount) external onlyPools {
        if (trackingVotes) {
            trackVotes(b_address, address(this), uint96(b_amount));
            uint32 srcRepNum = numCheckpoints[address(this)];
            uint96 srcRepOld = srcRepNum > 0 ? checkpoints[address(this)][srcRepNum - 1].votes : 0;
            uint96 srcRepNew = sub96(srcRepOld, uint96(b_amount), "pool_burn_from new votes underflows");
            _writeCheckpoint(address(this), srcRepNum, srcRepOld, srcRepNew);
            // burn votes
        }

        super._burnFrom(b_address, b_amount);
        tar_supply = tar_supply.sub(b_amount);
        emit TARBurned(b_address, address(this), b_amount);
    }

    function toggleVotes() external onlyByOwnerOrGovernance {
        trackingVotes = !trackingVotes;
    }

    function setTeamAddress(address teamAddress) external onlyByOwnerOrGovernance {
        team_address = teamAddress;
    }

    function setIntensiveAddress(address _intensiveAddress) external onlyByOwnerOrGovernance {
        intensiveAddress = _intensiveAddress;
    }

    /* ========== OVERRIDDEN PUBLIC FUNCTIONS ========== */

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        if (trackingVotes) {
            // Transfer votes
            trackVotes(_msgSender(), recipient, uint96(amount));
        }
        _transfer(_msgSender(), recipient, amount);

        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        if (trackingVotes) {
            // Transfer votes
            trackVotes(sender, recipient, uint96(amount));
        }

        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));

        return true;
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint96) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber) public view returns (uint96) {
        require(blockNumber < block.number, "TAR::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // From compound's _moveDelegates
    // Keep track of votes. "Delegates" is a misnomer here
    function trackVotes(address srcRep, address dstRep, uint96 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint96 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint96 srcRepNew = sub96(srcRepOld, amount, "TAR::_moveVotes: vote amount underflows");
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint96 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint96 dstRepNew = add96(dstRepOld, amount, "TAR::_moveVotes: vote amount overflows");
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(address voter, uint32 nCheckpoints, uint96 oldVotes, uint96 newVotes) internal {
        uint32 blockNumber = safe32(block.number, "TAR::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[voter][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[voter][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[voter][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[voter] = nCheckpoints + 1;
        }

        emit VoterVotesChanged(voter, oldVotes, newVotes);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2 ** 32, errorMessage);
        return uint32(n);
    }

    function safe96(uint n, string memory errorMessage) internal pure returns (uint96) {
        require(n < 2 ** 96, errorMessage);
        return uint96(n);
    }

    function add96(uint96 a, uint96 b, string memory errorMessage) internal pure returns (uint96) {
        uint96 c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub96(uint96 a, uint96 b, string memory errorMessage) internal pure returns (uint96) {
        require(b <= a, errorMessage);
        return a - b;
    }

    /* ========== EVENTS ========== */

    /// @notice An event thats emitted when a voters account's vote balance changes
    event VoterVotesChanged(address indexed voter, uint previousBalance, uint newBalance);

    // Track TAR burned
    event TARBurned(address indexed from, address indexed to, uint256 amount);

    // Track TAR minted
    event TARMinted(address indexed from, address indexed to, uint256 amount);

    event USRAddressSet(address addr);

    event BalanceChanged(address sender, uint256 amount0, address receipt, uint256 amount1);

    event RoundMintOne(address user, uint256 amount);
    event  WithDrawMintOne(address user, uint256 amount);
}
