import { type Signer } from 'ethers';
import { ethers } from 'hardhat';
import { Lock__factory } from '../typechain-types';

const { getSigners } = ethers;

const JAN_1ST_2030 = 1893456000;

async function deploy() {
    const [owner] = await getSigners();

    const Lock = await new Lock__factory(owner as unknown as Signer).deploy(JAN_1ST_2030);

    await Lock.waitForDeployment();

    console.log(Lock.target);
}

deploy();
