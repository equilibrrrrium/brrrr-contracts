// eslint-disable-next-line node/no-unpublished-require
const { ethers } = require('hardhat');

module.exports = async function ({ getNamedAccounts, deployments }) {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const brrrr = await ethers.getContract('Brrrr');
  const wbnbAddress = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';
  const pairAddress = '0xAF5062f52E17039fCabF243a5487Aaa80A733033';

  await deploy('TaxOracle', {
    from: deployer,
    args: [brrrr.address, wbnbAddress, pairAddress],
    log: true,
    deterministicDeployment: false,
  });
};

module.exports.tags = ['TaxOracle'];
