import type { Network } from 'bitcoinjs-lib';

declare module 'coininfo' {
    export interface BasicInfo {
        hashGenesisBlock: string;
        // nDefaultPort
        port: number;
        portRpc?: number;
        protocol: {
            // pchMessageStart
            magic: number;
        };
        bech32?: string;
        // vSeeds
        seedsDns?: string[];
        // base58Prefixes
        versions: {
            bip32: {
                private: number;
                public: number;
            };
            bip44: number;
            private: number;
            public: number;
            scripthash: number;
        };
    }
    export type CoinInfo = BasicInfo & {
        toBitcoinJS(): BasicInfo & Network;
    };
    export default function coininfo(input: string): CoinInfo;
}
