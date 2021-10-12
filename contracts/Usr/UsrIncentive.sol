pragma solidity >=0.6.11;

import "../Math/SafeMath.sol";
import "../Staking/Owned.sol";
import "./AccountAddress.sol";
import "./Usr.sol";
import '../Uniswap/Interfaces/IUniswapV2Pair.sol';
import '../Uniswap/UniswapV2Library.sol';
import '../TAR/TAR.sol';
import "hardhat/console.sol";

contract UsrIncentive is Owned {
    using SafeMath for uint256;

    struct UserTrans {
        address account;
        uint256 amount;
    }

    struct UserReward {
        address account;
        uint256 reward;
        uint256 amount;
        uint256 level;
    }
    /* ========== STATE VARIABLES ========== */

    uint public declineDays = 7;   //
    uint  public curDeclineDays = 0;
    address public creator_address;
    address public timelock_address; // Governance timelock address

    IUniswapV2Pair public   PAIR;
    address private pair_address;

    UserTrans[100]  public UserLast100Trans;
    uint256 public curTransIndex = 0;
    uint256 private lastTransTimeStamp = 0;
    uint public rewardCount = 100;
    bool public isStartFOMO = false;
    bool private SuccessFOMO = false;
    uint256 private curRound = 1;
    uint256 private transInterval = 10 * 60;//10 mins
    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 public fomoThreshold = 100e18;
    bool public IsPenalty = false; //
    mapping(address => bool) public intensive;//swap pair include usr
    address public intensiveAddress;
    address public penaltyAddress;
    address private UsrAddress;
    address private TarAddress;
    UsrStablecoin private USR;
    Tollar private TAR;
    uint256 private lastTarUsd24H = 0;
    uint256 private  _tarUsd24H = 0;
    uint256 public fmRound = 0;
    //round->addr->value
    //mapping(uint256 => mapping(address => UserReward)) public rewards;
    mapping(uint256 => UserReward[]) public rewards;
    mapping(address => mapping(uint256 => uint256)) _rank;
    modifier onlyUsr() {
        require(UsrAddress == msg.sender, "only Usr");
        _;
    }
    modifier onlyByOwnerGovernanceOrController() {
        require(msg.sender == owner || msg.sender == timelock_address, "You are not the owner, controller, or the governance timelock");
        _;
    }

    constructor(
        address _creator_address,
        address _timelock_address,
        address _usrAddress,
        address _tarAddress
    ) public Owned(_creator_address){

        creator_address = _creator_address;
        timelock_address = _timelock_address;
        intensiveAddress = createContract("intensiveAddress");
        penaltyAddress = createContract("penaltyAddress");
        UsrAddress = _usrAddress;
        USR = UsrStablecoin(_usrAddress);
        TarAddress = _tarAddress;
        TAR = Tollar(_tarAddress);
    }

    function createContract(string memory _name) internal returns (address accountContract){
        bytes memory bytecode = type(AccountAddress).creationCode;
        bytes32 salt = keccak256(bytes(_name));
        assembly {
            accountContract := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

    }

    function currentBlockTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }

    function currentBlockTimestampForTest() public view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    function setPair(address pair, bool b) public onlyByOwnerGovernanceOrController {
        intensive[pair] = b;

    }

    function _IsPair(address addr) internal view returns (bool){
        return intensive[addr] == true;
    }

    function setTarUsrPair(address pair) public onlyByOwnerGovernanceOrController {
        PAIR = IUniswapV2Pair(pair);
        pair_address = pair;
    }

    function buyTar(uint256 amount, address to) internal returns (uint256) {
        require(USR.superBalanceOf(intensiveAddress) > amount, "balance not enough");
        (uint256 reserves0, uint256 reserves1,) = PAIR.getReserves();
        (uint256 reserveUsr, uint256 reserveTar) = PAIR.token0() == address(UsrAddress) ? (reserves0, reserves1) : (reserves1, reserves0);
        uint256 amountOut = UniswapV2Library.getAmountOut(
            amount,
            reserveUsr,
            reserveTar
        );
        // super._transfer(intensiveAddress, pair_address, amount);
        USR.superTransfer(intensiveAddress, pair_address, amount);
        (uint256 amount0Out, uint256 amount1Out) =
        PAIR.token0() == address(UsrAddress) ? (uint256(0), amountOut) : (amountOut, uint256(0));
        PAIR.swap(amount0Out, amount1Out, to, new bytes(0));
        return amountOut;
    }

    function getAmountOut(uint256 amount) internal returns (uint256){
        (uint256 reserves0, uint256 reserves1,) = PAIR.getReserves();
        (uint256 reserveUsr, uint256 reserveTar) = PAIR.token0() == address(UsrAddress) ? (reserves0, reserves1) : (reserves1, reserves0);
        uint256 amountOut = UniswapV2Library.getAmountOut(
            amount,
            reserveUsr,
            reserveTar
        );
        return amountOut;
    }

    //only for test
    function buyTarForTest(uint256 amount, address to) public onlyByOwnerGovernanceOrController returns (uint256) {
        require(USR.superBalanceOf(msg.sender) > amount, "balance not enough");
        (uint256 reserves0, uint256 reserves1,) = PAIR.getReserves();
        (uint256 reserveUsr, uint256 reserveTar) = PAIR.token0() == address(UsrAddress) ? (reserves0, reserves1) : (reserves1, reserves0);
        uint256 amountOut = UniswapV2Library.getAmountOut(
            amount,
            reserveUsr,
            reserveTar
        );
        // super._transfer(intensiveAddress, pair_address, amount);
        // USR.superTransfer(msg.sender, pair_address, amount);
        require(USR.transferFrom(msg.sender, pair_address, amount) == true, "transFrom need success");
        (uint256 amount0Out, uint256 amount1Out) =
        PAIR.token0() == address(UsrAddress) ? (uint256(0), amountOut) : (amountOut, uint256(0));
        PAIR.swap(amount0Out, amount1Out, to, new bytes(0));

        return amountOut;
    }
    //only for test
    function sellTarForTest(uint256 amount, address to) public onlyByOwnerGovernanceOrController returns (uint256) {
        // require(USR.superBalanceOf(msg.sender) > amount, "balance not enough");
        (uint256 reserves0, uint256 reserves1,) = PAIR.getReserves();
        (uint256 reserveUsr, uint256 reserveTar) = PAIR.token0() == address(UsrAddress) ? (reserves0, reserves1) : (reserves1, reserves0);
        uint256 amountOut = UniswapV2Library.getAmountOut(
            amount,
            reserveTar,
            reserveUsr

        );
        //address tarAddress = PAIR.token0() == address(UsrAddress) ? PAIR.token1() : PAIR.token0();
        //Tollar TAR = Tollar(tarAddress);
        require(TAR.transferFrom(msg.sender, pair_address, amount) == true, "transFrom need success");
        (uint256 amount0Out, uint256 amount1Out) =
        PAIR.token0() == address(UsrAddress) ? (amountOut, uint256(0)) : (uint256(0), amountOut);
        PAIR.swap(amount0Out, amount1Out, to, new bytes(0));
        return amountOut;
    }

    function setDeclineDays(uint _declineDays) public onlyByOwnerGovernanceOrController {
        declineDays = _declineDays;
    }

    function setTransInterval(uint _transInterval) public onlyByOwnerGovernanceOrController {
        transInterval = _transInterval;
    }

    function setFOMO(bool _fomo) public onlyByOwnerGovernanceOrController {
        isStartFOMO = _fomo;
        curTransIndex = 0;
    }

    function setFOMOThreshold(uint256 threshold) public onlyByOwnerGovernanceOrController {
        fomoThreshold = threshold;
    }

    function setRewardCount(uint _rewardCount) public onlyByOwnerGovernanceOrController {
        require(_rewardCount > 0, "bigger than 0");
        rewardCount = _rewardCount;
        delete UserLast100Trans;
        //clear array
    }

    function SetPenalty(bool b) public onlyByOwnerGovernanceOrController {
        IsPenalty = b;
    }

    function incentiveTransfer(
        address sender,
        address recipient,
        uint256 amount) public onlyUsr {
        if (USR.IsOracleReady()) {
            if (USR.tarUsr24HOracleCanUpdate() == true) {
                lastTarUsd24H = _tarUsd24H;
                USR.tarUsr24HOracleUpdate();
            }
            if (USR.usrUsd24HOracleCanUpdate() == true) {
                USR.usrUsd24HOracleUpdate();

            }
            if (USR.usrUsd1HOracleCanUpdate() == true) {
                USR.usrUsd1HOracleUpdate();
            }
            if (USR.tarUsr1HOracleCanUpdate() == true) {
                USR.tarUsr1HOracleUpdate();
            }
            if (USR.CanRefreshCollateralRatio() == true) {
                USR.refreshCollateralRatio();
            }

            _tarUsd24H = USR.tar_usd_24H_price();
            if (_tarUsd24H < lastTarUsd24H) {
                curDeclineDays = curDeclineDays + 1;
            }


            uint256 tarUsd = USR.tar_usd_price();
            uint256 tarUsd24H = USR.tar_usd_24H_price();
            //console.log(tarUsd,tarUsd24H);
            if (tarUsd != 0 && tarUsd24H != 0) {
                if (tarUsd <= tarUsd24H.mul(97).div(100)) {
                    IsPenalty = true;
                    // console.log("start penalty!");
                }

                if (tarUsd >= tarUsd24H) {
                    IsPenalty = false;

                }
            }

            if (_IsPair(recipient) && (tarUsd.div(10 * PRICE_PRECISION) > curRound - 1)) {
                curRound = curRound + 1;
                emit StartMintRound(curRound - 1);
            }

            uint256 balTar = TAR.balanceOf(intensiveAddress);

            uint256 value = USR.superBalanceOf(intensiveAddress).add(balTar.mul(tarUsd).div(PRICE_PRECISION));
            if (curDeclineDays >= declineDays && SuccessFOMO == false && value >= fomoThreshold) {//begin FOMO
                curDeclineDays = 0;
                isStartFOMO = true;
                console.log("StartFOMO");
                emit StartFOMO();
            }

            if (isStartFOMO) {
                uint256 curTime = currentBlockTimestamp();
                if (lastTransTimeStamp > 0 && curTransIndex >= 1 && curTime - lastTransTimeStamp > transInterval) {
                    SuccessFOMO = true;
                    isStartFOMO = false;
                    if (curTransIndex > 0) {
                        curTransIndex = curTransIndex - 1;
                    } else {
                        curTransIndex = rewardCount - 1;
                    }

                    fmRound = fmRound.add(1);
                    console.log("FOMOSuccess");
                    emit FOMOSuccess(curTransIndex, USR.superBalanceOf(intensiveAddress).mul(10).div(100), fmRound);
                } else if (_IsPair(recipient)) {
                    if (curTransIndex == rewardCount) {
                        curTransIndex = 0;
                    }
                    UserLast100Trans[curTransIndex] = UserTrans(sender, amount);
                    curTransIndex = curTransIndex + 1;
                    lastTransTimeStamp = curTime;
                    emit FOMOBuy();
                }
            }

        }


        if (IsPenalty && amount >= 20) {
            if (_IsPair(sender)) {//pair->user
                uint256 penalty = amount.mul(10).div(100);
                require(penalty < amount, "penalty should less acmount");
                require(intensiveAddress != address(0), "intensiveAddress is 0 addr");
                USR.superTransfer(sender, recipient, amount.sub(penalty));
                uint256 penaltyHalf = amount.mul(5).div(100);
                uint256 left = penalty.sub(penaltyHalf);
                if (penaltyHalf > 0) {
                    USR.superTransfer(sender, intensiveAddress, penaltyHalf);
                }
                if (left > 0) {
                    USR.superTransfer(sender, penaltyAddress, left);
                }
                if (penalty > 0) {
                    emit PenaltyAddress(recipient, penalty);
                }
            } else if (_IsPair(recipient)) {//user->pair

                uint256 intensiveValue = amount.mul(5).div(100);
                require(intensiveValue < amount, "intensiveValue should less amount");
                require(penaltyAddress != address(0), "penaltyAddress is 0 addr");

                if (intensiveValue > 0 && USR.superBalanceOf(penaltyAddress) >= intensiveValue) {
                    USR.superTransfer(penaltyAddress, sender, intensiveValue);
                    emit  IntensiveAddress(sender, intensiveValue);

                }
                USR.superTransfer(sender, recipient, amount);

            } else {
                USR.superTransfer(sender, recipient, amount);

            }

        } else {
            USR.superTransfer(sender, recipient, amount);

        }

    }


    //    function sendChampion(UserTrans memory info) internal {
    //        uint256 reward = info.amount.mul(100);
    //        //reward 100x
    //        if (info.account != address(0)) {
    //            buyTar(reward, info.account);
    //            rewards[fmRound].push(UserReward(info.account, reward, info.amount, 1));
    //        }
    //
    //    }
    //
    //    function sendLast9(UserTrans memory info) internal {
    //        uint256 reward = info.amount.mul(10);
    //        //reward 10x
    //        buyTar(reward, info.account);
    //        rewards[fmRound].push(UserReward(info.account, reward, info.amount, 2));
    //    }
    //
    //    function sendLast90(UserTrans memory info) internal {
    //        uint256 reward = info.amount.mul(10).div(100);
    //        //reward 10%
    //        buyTar(reward, info.account);
    //        rewards[fmRound].push(UserReward(info.account, reward, info.amount, 3));
    //    }
    //
    //    function sendPercentChampion(UserTrans memory info, uint256 bal) internal {
    //        uint256 reward = bal.mul(908).div(1000);
    //        //reward 90.8/100
    //        if (info.account != address(0)) {
    //            AccountAddress(intensiveAddress).transfer(TarAddress, info.account, reward);
    //            rewards[fmRound].push(UserReward(info.account, reward, info.amount, 1));
    //        }
    //
    //    }
    //
    //    function sendPercentLast9(UserTrans memory info, uint256 bal) internal {
    //        uint256 reward = bal.div(100);
    //        //reward each 1/100
    //
    //        AccountAddress(intensiveAddress).transfer(TarAddress, info.account, reward);
    //        rewards[fmRound].push(UserReward(info.account, reward, info.amount, 2));
    //        // buyTar(reward, info.account);
    //    }
    //
    //    function sendPercentLast90(UserTrans memory info, uint256 bal) internal {
    //        uint256 reward = bal.div(100000);
    //        //reward 0.09/100
    //        // each 0.09/(100*90)
    //        AccountAddress(intensiveAddress).transfer(TarAddress, info.account, reward);
    //        rewards[fmRound].push(UserReward(info.account, reward, info.amount, 3));
    //    }


    function getReward() public view returns (uint256){
        uint256 index = curTransIndex;
        // console.log("curTransIndex:", curTransIndex);
        uint256 _reward;
        if (UserLast100Trans[index].account == address(0)) {
            return _reward;
        }
        //_rank[UserLast100Trans[index].account][index] = 1;
        _reward = _reward.add(UserLast100Trans[index].amount.mul(100));
        if (index == 0) {
            index = 100;
        }
        uint256 j = 0;
        for (uint256 i = index - 1;;) {
            if (j < 9) {
                if (UserLast100Trans[i].account == address(0)) {
                    break;
                }
                //_rank[UserLast100Trans[i].account][i] = 2;
                _reward = _reward.add(UserLast100Trans[i].amount.mul(10));
                j++;
            } else {
                if (i == curTransIndex || UserLast100Trans[i].account == address(0)) {
                    break;
                }

                _reward = _reward.add(UserLast100Trans[index].amount.mul(10).div(100));
                // _rank[UserLast100Trans[i].account][i] = 3;
            }

            if (i == 0) {
                i = 100;
            }

            i--;
        }
        return _reward;
    }


    function rank() internal returns (uint256){
        uint256 index = curTransIndex;
        // console.log("curTransIndex:", curTransIndex);
        uint256 _reward;
        if (UserLast100Trans[index].account == address(0)) {
            return _reward;
        }
        _rank[UserLast100Trans[index].account][index] = 1;
        _reward = _reward.add(UserLast100Trans[index].amount.mul(100));
        if (index == 0) {
            index = 100;
        }
        uint256 j = 0;
        for (uint256 i = index - 1;;) {
            if (j < 9) {
                if (UserLast100Trans[i].account == address(0)) {
                    break;
                }
                _rank[UserLast100Trans[i].account][i] = 2;
                _reward = _reward.add(UserLast100Trans[i].amount.mul(10));
                j++;
            } else {
                if (i == curTransIndex || UserLast100Trans[i].account == address(0)) {
                    break;
                }

                _reward = _reward.add(UserLast100Trans[index].amount.mul(10).div(100));
                _rank[UserLast100Trans[i].account][i] = 3;
            }

            if (i == 0) {
                i = 100;
            }

            i--;
        }
        return _reward;
    }


    function dispatch(uint256 calReward, uint256 realReward) internal {

        for (uint256 i = 0; i < UserLast100Trans.length; i++) {

            if (UserLast100Trans[i].account == address(0)) {
                break;
            }
            if (_rank[UserLast100Trans[i].account][i] == 1) {
                uint256 reward = UserLast100Trans[i].amount.mul(100).mul(realReward).div(calReward);
                if (reward > 0 && TAR.balanceOf(intensiveAddress) >= reward) {
                    // console.log("1:",i, reward);
                    AccountAddress(intensiveAddress).transfer(TarAddress, UserLast100Trans[i].account, reward);
                }
                rewards[fmRound].push(UserReward(UserLast100Trans[i].account, reward, UserLast100Trans[i].amount, 1));
            } else if (_rank[UserLast100Trans[i].account][i] == 2) {
                uint256 reward = UserLast100Trans[i].amount.mul(10).mul(realReward).div(calReward);
                if (reward > 0 && TAR.balanceOf(intensiveAddress) >= reward) {
                    //console.log("2:",i, reward);
                    AccountAddress(intensiveAddress).transfer(TarAddress, UserLast100Trans[i].account, reward);
                }
                rewards[fmRound].push(UserReward(UserLast100Trans[i].account, reward, UserLast100Trans[i].amount, 2));
            } else if (_rank[UserLast100Trans[i].account][i] == 3) {
                uint256 reward = UserLast100Trans[i].amount.mul(10).div(100).mul(realReward).div(calReward);
                if (reward > 0 && TAR.balanceOf(intensiveAddress) >= reward) {
                    AccountAddress(intensiveAddress).transfer(TarAddress, UserLast100Trans[i].account, reward);
                }
                rewards[fmRound].push(UserReward(UserLast100Trans[i].account, reward, UserLast100Trans[i].amount, 3));
            }

        }

    }

    //this is new one
    function dispatchFMReward() public onlyByOwnerGovernanceOrController {
        require(SuccessFOMO == true, "need successFoMo");
        // reward amount of usr
        uint256 _reward = rank();
        uint256 balUsr = USR.balanceOf(intensiveAddress).mul(10).div(100);
        require(_reward > 0, "_reward bigger than 0");
        uint256 tarBal = TAR.balanceOf(intensiveAddress).mul(10).div(100);
        //dispatch logic
        uint256 bal;
        if (balUsr > 0) {
            bal = buyTar(balUsr, intensiveAddress);
        }
        //usr to tar value
        //uint256 calTar = bal.mul(_reward).div(balUsr);
        uint256 calTar = getAmountOut(_reward);
        bal = bal.add(tarBal);
        if (calTar > bal) {//percent
            dispatch(_reward, bal);
        } else {//100%
            dispatch(_reward, calTar);
        }
        curTransIndex = 0;
        SuccessFOMO = false;
        delete UserLast100Trans;
        emit RewardDispatched(fmRound);

    }

    //    function dispatchReward() public onlyByOwnerGovernanceOrController {
    //        require(SuccessFOMO == true, "need successFoMo");
    //        //dispatch logic
    //        if (curTransIndex >= 9) {//last 10
    //            for (uint i = curTransIndex - 9; i <= curTransIndex - 1; i++) {//last 9
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendLast9(UserLast100Trans[i]);
    //
    //            }
    //            //cur trans index is last one
    //            sendChampion(UserLast100Trans[curTransIndex]);
    //
    //            for (uint i = curTransIndex + 1; i < UserLast100Trans.length; i++) {
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendLast90(UserLast100Trans[i]);
    //
    //            }
    //            for (uint i = 0; i < curTransIndex - 9; i++) {
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendLast90(UserLast100Trans[i]);
    //
    //            }
    //
    //        } else {
    //            for (uint i = 0; i < curTransIndex; i++) {//last 9
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendLast9(UserLast100Trans[i]);
    //
    //            }
    //            //cur trans index is last one
    //            sendChampion(UserLast100Trans[curTransIndex]);
    //
    //            if (curTransIndex + UserLast100Trans.length > 10) {
    //                for (uint i = curTransIndex + 1; i <= curTransIndex + UserLast100Trans.length - 10; i++) {
    //                    if (UserLast100Trans[i].account == address(0)) {
    //                        break;
    //                    }
    //                    sendLast90(UserLast100Trans[i]);
    //
    //                }
    //            }
    //
    //
    //            if (UserLast100Trans.length > 9) {
    //                for (uint i = curTransIndex + UserLast100Trans.length - 9; i < UserLast100Trans.length; i++) {
    //                    if (UserLast100Trans[i].account == address(0)) {
    //                        break;
    //                    }
    //                    sendLast9(UserLast100Trans[i]);
    //
    //                }
    //            }
    //
    //        }
    //
    //        curTransIndex = 0;
    //        SuccessFOMO = false;
    //        delete UserLast100Trans;
    //        emit RewardDispatched(fmRound);
    //    }
    //
    //
    //    function dispatchRewardPercent() public onlyByOwnerGovernanceOrController {
    //
    //        require(SuccessFOMO, "SuccessFOMO");
    //        uint256 balUsr = USR.balanceOf(intensiveAddress).mul(10).div(100);
    //        require(balUsr > 0, "usr bal bigger than 0");
    //        uint256 tarBal = TAR.balanceOf(intensiveAddress).mul(10).div(100);
    //        //dispatch logic
    //        uint256 bal = buyTar(balUsr, intensiveAddress);
    //        bal = bal.add(tarBal);
    //        require(bal > 100000, "tar'bal>100000");
    //        if (curTransIndex >= 9) {//last 10
    //            for (uint i = curTransIndex - 9; i <= curTransIndex - 1; i++) {//last 9
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendPercentLast9(UserLast100Trans[i], bal);
    //
    //            }
    //            //cur trans index is last one
    //            sendPercentChampion(UserLast100Trans[curTransIndex], bal);
    //
    //            for (uint i = curTransIndex + 1; i < UserLast100Trans.length; i++) {
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendPercentLast90(UserLast100Trans[i], bal);
    //
    //            }
    //            for (uint i = 0; i < curTransIndex - 9; i++) {
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendPercentLast90(UserLast100Trans[i], bal);
    //
    //            }
    //
    //        } else {
    //            for (uint i = 0; i < curTransIndex; i++) {//last 9
    //                if (UserLast100Trans[i].account == address(0)) {
    //                    break;
    //                }
    //                sendPercentLast9(UserLast100Trans[i], bal);
    //
    //            }
    //            //cur trans index is last one
    //            sendPercentChampion(UserLast100Trans[curTransIndex], bal);
    //
    //            if (curTransIndex + UserLast100Trans.length > 10) {
    //                for (uint i = curTransIndex + 1; i <= curTransIndex + UserLast100Trans.length - 10; i++) {
    //                    if (UserLast100Trans[i].account == address(0)) {
    //                        break;
    //                    }
    //                    sendPercentLast90(UserLast100Trans[i], bal);
    //
    //                }
    //            }
    //
    //
    //            if (UserLast100Trans.length > 9) {
    //                for (uint i = curTransIndex + UserLast100Trans.length - 9; i < UserLast100Trans.length; i++) {
    //                    if (UserLast100Trans[i].account == address(0)) {
    //                        break;
    //                    }
    //                    sendPercentLast9(UserLast100Trans[i], bal);
    //
    //                }
    //            }
    //
    //        }
    //
    //        curTransIndex = 0;
    //        SuccessFOMO = false;
    //        delete UserLast100Trans;
    //        emit RewardDispatched(fmRound);
    //    }


    function getIncentiveBalance() public view returns (uint256) {
        return USR.superBalanceOf(intensiveAddress);
    }

    function getIncentiveAddress() public view returns (address) {
        return intensiveAddress;
    }

    function getRewardList() public view returns (address[] memory, uint256[] memory){
        address[] memory accounts = new address[](UserLast100Trans.length);
        uint256[] memory amounts = new uint256[](UserLast100Trans.length);
        for (uint256 i = 0; i < UserLast100Trans.length; i++) {
            if (UserLast100Trans[i].account == address(0)) {
                break;
            }
            accounts[i] = UserLast100Trans[i].account;
            amounts[i] = UserLast100Trans[i].amount;

        }
        return (accounts, amounts);
    }

    function intensiveForGovernance(address account, uint256 amount) external onlyByOwnerGovernanceOrController {
        require(USR.superBalanceOf(intensiveAddress) > amount, "can not bigger than balance");
        USR.superTransfer(intensiveAddress, account, amount);
    }


    // event FOMOSuccess(uint curTransIndex);
    event IntensiveAddress(address addr, uint256 amount);
    event PenaltyAddress(address addr, uint256 amount);
    event FOMOSuccess(uint256 curTransIndex, uint256 bal, uint256 round);
    event StartMintRound(uint256 round);
    event StartFOMO();
    event FOMOBuy();
    event RewardDispatched(uint256 round);
}