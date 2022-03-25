module.exports = async function ({ getNamedAccounts, deployments }) {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const pairAddress = '0xAF5062f52E17039fCabF243a5487Aaa80A733033'; // BRRRR/WBNB PancakeSwap address

  await deploy('Oracle', {
    from: deployer,
    args: [pairAddress, 21600, 1648994400],
    log: true,
    deterministicDeployment: false,
    gasLimit: 10e6
  });
};

module.exports.tags = ['Oracle'];
