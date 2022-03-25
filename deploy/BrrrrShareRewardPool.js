// eslint-disable-next-line node/no-unpublished-require
const { ethers } = require('hardhat');

module.exports = async function ({ getNamedAccounts, deployments }) {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  const brrrrshare = await ethers.getContract('BrrrrShare');

  await deploy('BrrrrShareRewardPool', {
    from: deployer,
    args: [brrrrshare.address, 1648994400], // exactly genesis time +1
    log: true,
    deterministicDeployment: false,
    gasLimit: 10e6
  });
};

module.exports.tags = ['BrrrrShareRewardPool'];
