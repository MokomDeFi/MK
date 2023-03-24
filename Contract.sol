// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @title Contract for MK Staking
/// @author Anbang
contract MkStaking is Ownable {
    using SafeERC20 for IERC20;
    /* ============ Struct ============ */
    struct UserInfo {
        uint256 id;
        uint256 timestamp;
        // Main
        uint256 amount;
        uint256 rewardDebt;
        uint256 lockStartTime;
        uint256 lockEndTime;
        // frontend
        bool isDeposit;
        uint256 singleAmount;
        uint256 currentRewardValue;
        uint256 historyRewardValue;
    }

    /* ============ State Variables ============ */
    address public fundAddress;
    bool public stakingStatus = true;
    bool public writingStatus = true;

    address public immutable mkToken;
    uint256 public immutable startBlock;
    uint256 public oneDayBlocks = 25676;
    uint256 public oneDayRewards = 2465753424660000000000;
    uint256 public baseline = 1560000000000000000000000;

    // ************ pool ************
    uint256 public poolAmount;
    uint256 public poolAmountTotalReward;
    uint256 public lastRewardBlock;
    uint256 public accPerShare;

    // ************ user ************
    mapping(address => mapping(uint256 => UserInfo)) public userInfo;
    mapping(address => UserInfo[]) public userHistoryBill;
    mapping(address => uint256) public userAmount;
    mapping(address => uint256) public userReward;

    // ************ other ************
    uint256 internal constant DURATION = 31536000;
    uint256 internal constant BASE_MUL = 1e18;

    /* ============ Events ============ */
    event Deposit(address indexed user, uint256 bid, uint256 amount);
    event Withdraw(address indexed user, uint256 bid, uint256 amount);
    event StakingStatus(bool status);
    event WriteHistoryStatus(bool write_status);
    event AtomValue(uint256 one_day_rewards, uint256 baseline_value, uint256 one_day_blocks);
    event FundAddressChange(address old_fund_address, address new_fund_address);
    event HistoryBill(address indexed user, uint256 bid);

    /* ============ Constructor ============ */
    constructor(address _mkAddress, address _fundAddr, uint256 _startBlock) {
        mkToken = _mkAddress;
        fundAddress = _fundAddr;
        startBlock = block.number > _startBlock ? block.number : _startBlock;
    }

    /* ============ Limit Functions ============ */
    function setStakingStatus(bool _status) public onlyOwner {
        updatePool();
        stakingStatus = _status;
        emit StakingStatus(_status);
    }

    function setWritingStatus(bool _status) public onlyOwner {
        writingStatus = _status;
        emit WriteHistoryStatus(_status);
    }

    function setAtomValue(uint256 _rewards, uint256 _baseline, uint256 _blocks) public onlyOwner {
        updatePool();
        oneDayRewards = _rewards;
        baseline = _baseline;
        oneDayBlocks = _blocks;
        emit AtomValue(_rewards, _baseline, _blocks);
    }

    function transferFundAddress(address _fundAddress) public onlyOwner {
        fundAddress = _fundAddress;
        emit FundAddressChange(fundAddress, _fundAddress);
    }

    /* ============ Main Functions ============ */
    function updatePool() public {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (poolAmount == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
        uint256 perBlock = getPerBlock();

        accPerShare += (multiplier * (stakingStatus ? perBlock : 0)) / (poolAmount > baseline ? poolAmount : baseline);
        lastRewardBlock = block.number;
    }

    function deposit(uint256 _amount) public {
        require(_amount > 0, 'Deposit: amount must be greater than zero');
        uint256 bid = userHistoryBill[msg.sender].length;
        UserInfo storage user = userInfo[msg.sender][bid];
        user.id = bid;
        user.timestamp = block.timestamp;
        user.lockStartTime = block.timestamp;
        user.lockEndTime = block.timestamp + DURATION;
        user.isDeposit = true;
        user.singleAmount = _amount;
        user.currentRewardValue = 0;
        user.historyRewardValue = 0;

        updatePool();

        if (_amount > 0) {
            IERC20(mkToken).safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = _amount;
            userAmount[msg.sender] += _amount;
            poolAmount += _amount;
        }

        user.rewardDebt = (user.amount * accPerShare) / BASE_MUL;

        _pushUserHistory(msg.sender, bid);

        emit Deposit(msg.sender, bid, _amount);
    }

    function withdraw(uint256 _bid, uint256 _amount) public {
        UserInfo storage user = userInfo[msg.sender][_bid];
        require(user.amount >= _amount, 'Withdraw: not good');
        if (block.timestamp <= user.lockEndTime && _amount > 0) {
            revert('Withdraw: locked');
        }

        // new bill
        uint256 newBid = userHistoryBill[msg.sender].length;
        UserInfo storage newUser = userInfo[msg.sender][newBid];
        newUser.id = newBid;
        newUser.timestamp = block.timestamp;
        newUser.lockStartTime = user.lockStartTime;
        newUser.lockEndTime = user.lockEndTime;
        newUser.isDeposit = false;

        updatePool();

        // Reward
        if (user.amount > 0) {
            uint256 pendingReward = ((user.amount * accPerShare) / BASE_MUL) - (user.rewardDebt);
            if (pendingReward > 0) {
                IERC20(mkToken).safeTransferFrom(fundAddress, address(msg.sender), pendingReward);
                userReward[msg.sender] += pendingReward;
                poolAmountTotalReward += pendingReward;
                user.historyRewardValue += pendingReward;
                newUser.currentRewardValue = pendingReward;
                newUser.historyRewardValue = user.historyRewardValue;
            }
        }

        // Amount
        if (_amount > 0) {
            user.singleAmount = _amount;
            user.amount -= _amount;
            newUser.singleAmount = _amount;
            newUser.amount = user.amount;
            userAmount[msg.sender] -= _amount;
            poolAmount -= _amount;
            IERC20(mkToken).safeTransfer(address(msg.sender), _amount);
        }

        user.rewardDebt = (user.amount * accPerShare) / BASE_MUL;

        _pushUserHistory(msg.sender, newBid);

        emit Withdraw(msg.sender, _bid, _amount);
    }

    /* ============ Internal Functions ============ */
    function _getMultiplier(uint256 _from, uint256 _to) internal pure returns (uint256) {
        return _to - _from;
    }

    // history
    function _pushUserHistory(address _user_address, uint256 _bid) private {
        if (!writingStatus) {
            return;
        }
        UserInfo storage user = userInfo[_user_address][_bid];
        userHistoryBill[msg.sender].push(user);
        emit HistoryBill(msg.sender, _bid);
    }

    /* ============ Helper Functions ============ */
    function getPerBlock() public view returns (uint256 perBlock) {
        perBlock = (oneDayRewards * BASE_MUL) / oneDayBlocks;
    }

    // frontend:Get the user's bill list, in reverse order
    function getUserHistoryBill(address _user_address, uint256 _start_id, uint256 _limit) public view returns (UserInfo[] memory) {
        UserInfo[] storage billList = userHistoryBill[_user_address];
        uint256 length = billList.length;
        if (length == 0) {
            return new UserInfo[](0);
        }

        // If _start_id is large
        if (_start_id >= length) {
            _start_id = length - 1;
        }

        // If start ID is less than limit: correct limit
        if ((_start_id + 1) < _limit) {
            _limit = _start_id + 1;
        }

        uint256 startIndex = _start_id; // Include
        uint256 endIndex = _start_id + 1 - _limit; // Include
        UserInfo[] memory result = new UserInfo[](_limit);
        for (uint256 i = startIndex; i >= endIndex; --i) {
            result[startIndex - i] = billList[i];
            if (i == 0) {
                break;
            }
        }
        return result;
    }

    // frontend:View pending rewards
    function pending(address _user, uint256 _bid) external view returns (uint256 pendingReward) {
        UserInfo storage user = userInfo[_user][_bid];
        uint256 tempAccPS = accPerShare;
        if (poolAmount != 0 && block.number > lastRewardBlock) {
            uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
            uint256 perBlock = getPerBlock();
            tempAccPS += (multiplier * (stakingStatus ? perBlock : 0)) / (poolAmount > baseline ? poolAmount : baseline);
        }
        pendingReward = ((user.amount * tempAccPS) / BASE_MUL) - user.rewardDebt;
    }
}
