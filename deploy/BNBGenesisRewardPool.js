// eslint-disable-next-line node/no-unpublished-require
const { ethers } = require('hardhat');

module.exports = async function ({ getNamedAccounts, deployments }) {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const brrrr = await ethers.getContract('Brrrr');

  await deploy('BnbGenesisRewardPool', {
    from: deployer,
    args: [brrrr.address, 1648908000],
    log: true,
    deterministicDeployment: false,
    gasLimit: 10e6,
  });
};

module.exports.tags = ['bnbGenesisRewardPool'];