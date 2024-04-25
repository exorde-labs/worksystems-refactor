// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

interface IReputation {
    function balanceOf(address _owner) external view returns (uint256 balance);
}