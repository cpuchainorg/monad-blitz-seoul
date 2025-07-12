import process from 'process';
import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import '@nomicfoundation/hardhat-ethers';
import 'hardhat-dependency-compiler';
import 'hardhat-contract-sizer';
import 'hh-flatten';

const config: HardhatUserConfig & { dependencyCompiler: { paths: string[] } } = {
    defaultNetwork: 'hardhat',
    solidity: {
        compilers: [
            {
                version: '0.8.30',
                settings: {
                    evmVersion: 'london',
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                },
            },
        ],
    },
    dependencyCompiler: {
        paths: []
    },
    networks: {
        develop: {
            url: process.env.RPC_URL || '',
            accounts: {
                mnemonic: process.env.MNEMONIC || 'test test test test test test test test test test test junk',
                initialIndex: Number(process.env.MNEMONIC_INDEX) || 0,
            },
        },
        hardhat: {},
    },
    etherscan: {
        apiKey: process.env.ETHERSCAN,
    },
    sourcify: {
        enabled: true,
    },
};

export default config;
