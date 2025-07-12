// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20 } from '@openzeppelin/contracts-v5/token/ERC20/IERC20.sol';
import {
    IERC20Metadata
} from '@openzeppelin/contracts-v5/token/ERC20/extensions/IERC20Metadata.sol';
import { IERC20Permit } from '@openzeppelin/contracts-v5/token/ERC20/extensions/IERC20Permit.sol';

interface IERC20Exp is IERC20Metadata, IERC20Permit {}

interface IERC20Mintable is IERC20Exp {
    function burn(uint256 value) external;
    function mint(address to, uint256 amount) external;
}
