// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IOneInch {
    function swap(address src, address dst, uint256 amount, uint256 minReturn, address referral) external payable returns(uint256 result);
}
