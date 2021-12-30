//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IDistributor {
    function setShare(address shareholder, uint256 amount) external;
    function process(uint256 gas) external;
    function getShareholders() external view returns (address[] memory);
    function getShareForHolder(address holder) external view returns(uint256);
    function getRewardTokenForHolder(address holder) external view returns(address);
}