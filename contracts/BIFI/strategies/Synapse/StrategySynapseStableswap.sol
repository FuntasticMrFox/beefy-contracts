// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/sushi/IMiniChefV2.sol";
import "../../interfaces/sushi/IRewarder.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";

contract StrategySynapseStableswap is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address constant nullAddress = address(0);

    // Tokens used
    address public native;
    address public output;
    address public reward;
    address public want;
    address public stable;

    // Third party contracts
    address public chef;
    uint256 public poolId;

    uint256 public lastHarvest;
    bool public harvestOnDeposit;

    // Routes
    address[] public outputToNativeRoute;
    address[] public outputToStableRoute;
    address[] public rewardToStableRoute;

    address[] public stablecoins;
    mapping (address => uint256) stablecoinIndex;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    constructor(
        address _want,
        uint256 _poolId,
        address _chef,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _beefyFeeRecipient,
        address[] memory _outputToNativeRoute,
        address[] memory _outputToStableRoute,
        address[] memory _rewardToStableRoute,
        address[] memory _stablecoins,
        address[] memory _stable
    ) StratManager(_keeper, _strategist, _unirouter, _vault, _beefyFeeRecipient) public {
        want = _want;
        poolId = _poolId;
        chef = _chef;

        require(_outputToNativeRoute.length >= 2);
        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;

        _buildStablecoins(_stablecoins);

        require(stablecoinIndex[_stable] != 0, 'Stable not found.');
        stable = _stable;
        require(_outputToStableRoute[0] == output, 'first != output');
        require(_outputToStableRoute[_outputToStableRoute.length - 1] == stable, 'last != stable');
        outputToStableRoute = _outputToStableRoute;

        reward = _rewardToStableRoute[0];
        require(_rewardToStableRoute[_rewardToStableRoute.length - 1] == stable, 'last != stable');
        rewardToStableRoute = _rewardToStableRoute;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IMiniChefV2(chef).deposit(poolId, wantBal, address(this));
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMiniChefV2(chef).withdraw(poolId, _amount.sub(wantBal), address(this));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
        }
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IMiniChefV2(chef).harvest(poolId, address(this));
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        uint256 rewardBal = IERC20(reward).balanceOf(address(this));
        if (outputBal > 0 || rewardBal > 0) {
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        IMiniChefV2(_chef).rewarder(_poolId);

        uint256 toNative = IERC20(output).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toNative, 0, outputToNativeRoute, address(this), block.timestamp);

        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE);
            IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 beefyFeeAmount = nativeBal.mul(beefyFee).div(MAX_FEE);
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        if (lpToken0 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp0Route, address(this), block.timestamp);
        }

        if (lpToken1 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp1Route, address(this), block.timestamp);
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), block.timestamp);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMiniChefV2(chef).userInfo(poolId, address(this));
        return _amount;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        return IMiniChefV2(chef).pendingSushi(poolId, address(this));
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
         if (outputBal > 0) {
            try IUniswapRouterETH(unirouter).getAmountsOut(outputBal, outputToNativeRoute)
                returns (uint256[] memory amountOut) 
            {
                nativeOut = amountOut[amountOut.length -1];
            }
            catch {}
        }

        uint256 pendingNative;
        address rewarder = IMiniChefV2(chef).rewarder(poolId);
        if (rewarder != nullAddress) {
            pendingNative = IRewarder(rewarder).pendingToken(poolId, address(this));
        } 

        return pendingNative.add(nativeOut).mul(45).div(1000).mul(callFee).div(MAX_FEE);
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMiniChefV2(chef).emergencyWithdraw(poolId, address(this));
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(chef, type(uint256).max);
        IERC20(output).safeApprove(unirouter, type(uint256).max);
        IERC20(reward).safeApprove(unirouter, type(uint256).max);

        IERC20(stable).safeApprove(unirouter, 0);
        IERC20(stable).safeApprove(unirouter, type(uint256).max);
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(reward).safeApprove(unirouter, 0);
        IERC20(stable).safeApprove(unirouter, 0);
        IERC20(stable).safeApprove(unirouter, 0);
    }

    function outputToNative() external view returns (address[] memory) {
        return outputToNativeRoute;
    }

    function outputToStable() external view returns (address[] memory) {
        return outputToStableRoute;
    }

    function rewardToStable() external view returns (address[] memory) {
        return rewardToStableRoute;
    }

    function viewStablecoins() external view returns (address[] memory) {
        return stablecoins;
    }

    function buildStablecoins(address[] memory _stablecoins) public onlyManager {
        _buildStablecoins(_stablecoins);
    }

    function _buildStablecoins(address[] memory _stablecoins) internal {
        // wipe existing stablecoin mapping
        for (uint256 i = 0; i < stablecoins.length; ++i) {
            delete stablecoinIndex[stablecoins[i]];
        }

        // overwrite stablecoin array
        stablecoins = _stablecoins;
        // create dummy at start of array by pushing first elt to end
        stablecoins.push(stablecoins[0]);
        // set dummy to 0x0
        stablecoins[0] = address(0); 

        // build new mapping, skipping dummy
        for (uint256 i = 1; i < stablecoins.length; ++i) {
            stablecoinIndex[stablecoins[i]] = i;
        }
    }

    function addStablecoin(address _stable) public onlyManager {
        // add address to end of array
        stablecoins.push(_stable);
        // map added stable to last index in array 
        stablecoinIndex[_stable] = stablecoins.length-1;
    }

    function removeStablecoin(address _stable) public onlyManager {
        require(stablecoins.length > 2, 'Must be at least one stablecoin.');
        require(_stable != stable, 'Cannot remove stable in use.');

        // get index for stable
        uint256 stableIndex = stablecoinIndex[_stable];
        require(stableIndex != 0, 'Stable not found.');

        // swap last element with index to delete
        uint256 lastElement = stablecoins[stablecoins.length-1];
        stablecoins[stableIndex] = lastElement;
        stablecoins.pop();

        // remove mapping of removed stable to index
        delete stablecoinIndex[_stable];
        // update mapping of last element to index of stable removed
        stablecoinIndex[lastElement] = stableIndex;
    }
}