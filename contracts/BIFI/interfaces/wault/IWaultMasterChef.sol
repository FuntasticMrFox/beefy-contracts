// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;
pragma abicoder v1;

interface IWaultMasterChef {
    function deposit(uint256 _pid, uint256 _amount, bool _withdrawRewards) external;
    function withdraw(uint256 _pid, uint256 _amount, bool _withdrawRewards) external;
    function claim(uint256 _pid) external;
    function pendingWex(uint256 _pid, address _user) external view returns (uint256);
    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);
    function emergencyWithdraw(uint256 _pid) external;
}