import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { Signer } from 'ethers';
import { GroupLib__factory, OwnableLib__factory, UseGroupLib__factory } from '../typechain-types';

const { getSigners, getContractFactory } = ethers;

describe('UseGroupLib', function () {
    const groupFixture = async () => {
        const [owner, alice, bob] = (await getSigners()) as unknown as (Signer & {
            address: string;
        })[];

        const addressSet = await (await getContractFactory('AddressSet', owner)).deploy();

        const ownerLib = await new OwnableLib__factory(owner).deploy();

        const groupLib = await new GroupLib__factory(
            {
                'contracts/libraries/AddressSet.sol:AddressSet': addressSet.target as string,
                'contracts/libraries/OwnableLib.sol:OwnableLib': ownerLib.target as string,
            },
            owner,
        ).deploy();

        const useGroup = await new UseGroupLib__factory(
            {
                'contracts/libraries/GroupLib.sol:GroupLib': groupLib.target as string,
                'contracts/libraries/OwnableLib.sol:OwnableLib': ownerLib.target as string,
            },
            owner,
        ).deploy();

        return {
            owner,
            alice,
            bob,
            useGroup,
            ownerLib,
            groupLib,
        };
    };

    describe('Ownership', function () {
        it('deploy', async function () {
            const { useGroup, owner } = await loadFixture(groupFixture);

            const tx = useGroup.deploymentTransaction();

            await owner.provider?.getTransactionReceipt(tx?.hash as string);

            //console.log(Number(tx?.data?.length) / 2, receipt?.gasUsed);
        });

        it('Owner can add member, non-owner cannot', async function () {
            const { useGroup, ownerLib, alice, bob } = await loadFixture(groupFixture);

            await expect(useGroup.addTstMember(alice.address))
                .to.emit(useGroup, 'AddMember')
                .withArgs(ethers.keccak256(ethers.toUtf8Bytes('Group')), alice.address);

            await expect(useGroup.connect(alice).addTstMember(bob.address)).to.be.revertedWithCustomError(
                ownerLib,
                'OwnableUnauthorizedAccount',
            );
        });

        it('Owner can remove member, non-owner cannot', async function () {
            const { useGroup, ownerLib, alice, bob } = await loadFixture(groupFixture);

            await useGroup.addTstMember(alice.address);

            await expect(useGroup.removeTstMember(alice.address))
                .to.emit(useGroup, 'RemoveMember')
                .withArgs(ethers.keccak256(ethers.toUtf8Bytes('Group')), alice.address);

            await useGroup.addTstMember(bob.address);

            await expect(useGroup.connect(alice).removeTstMember(bob.address)).to.be.revertedWithCustomError(
                ownerLib,
                'OwnableUnauthorizedAccount',
            );
        });

        it('Owner can transfer ownership', async function () {
            const { useGroup, ownerLib, owner, alice, bob } = await loadFixture(groupFixture);

            await expect(useGroup.transferOwnership(alice.address))
                .to.emit(useGroup, 'OwnershipTransferred')
                .withArgs(owner.address, alice.address);

            expect(await useGroup.owner()).to.eql(alice.address);

            await expect(useGroup.addTstMember(bob.address)).to.be.revertedWithCustomError(
                ownerLib,
                'OwnableUnauthorizedAccount',
            );

            await expect(useGroup.connect(alice).addTstMember(bob.address))
                .to.emit(useGroup, 'AddMember')
                .withArgs(ethers.keccak256(ethers.toUtf8Bytes('Group')), bob.address);
        });
    });

    describe('Membership', function () {
        it('Add and remove members, and check the list', async function () {
            const { useGroup, alice, bob } = await loadFixture(groupFixture);

            // Should start empty
            expect(await useGroup.tstMembers()).to.eql([]);
            expect(await useGroup.tstMembersLength()).to.eql(0n);

            // Add one
            await useGroup.addTstMember(alice.address);
            expect(await useGroup.tstMembers()).to.eql([alice.address]);
            expect(await useGroup.tstMembersLength()).to.eql(1n);

            // Add another
            await useGroup.addTstMember(bob.address);
            expect(await useGroup.tstMembers()).to.include(alice.address);
            expect(await useGroup.tstMembers()).to.include(bob.address);
            expect(await useGroup.tstMembersLength()).to.eql(2n);

            // Remove one
            await useGroup.removeTstMember(alice.address);
            expect(await useGroup.tstMembers()).to.eql([bob.address]);
            expect(await useGroup.tstMembersLength()).to.eql(1n);
        });

        it('Cannot add same member twice', async function () {
            const { useGroup, groupLib, alice } = await loadFixture(groupFixture);

            await useGroup.addTstMember(alice.address);

            await expect(useGroup.addTstMember(alice.address)).to.be.revertedWithCustomError(
                groupLib,
                'DuplicatedMember',
            );
        });

        it('Cannot remove non-existent member', async function () {
            const { useGroup, groupLib, alice } = await loadFixture(groupFixture);

            await expect(useGroup.removeTstMember(alice.address)).to.be.revertedWithCustomError(
                groupLib,
                'InvalidMember',
            );
        });
    });
});
