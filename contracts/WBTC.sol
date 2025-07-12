// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Ownable } from '@openzeppelin/contracts-v5/access/Ownable.sol';
import { ERC20 } from '@openzeppelin/contracts-v5/token/ERC20/ERC20.sol';
import { ERC20Burnable } from '@openzeppelin/contracts-v5/token/ERC20/extensions/ERC20Burnable.sol';
import { ERC20Permit } from '@openzeppelin/contracts-v5/token/ERC20/extensions/ERC20Permit.sol';

contract WBTC is ERC20, ERC20Burnable, ERC20Permit, Ownable {
    uint8 private immutable _decimals;

    constructor() ERC20('Wrapped BTC', 'WBTC') ERC20Permit('Wrapped BTC') Ownable(msg.sender) {
        _decimals = 8;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(uint256 amount) external onlyOwner {
        _mint(msg.sender, amount);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
