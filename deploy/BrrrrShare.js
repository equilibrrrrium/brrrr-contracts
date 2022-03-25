module.exports = async function ({ getNamedAccounts, deployments }) {
  const { deploy } = deployments;
  const { deployer, dao, dev } = await getNamedAccounts();

  await deploy('BrrrrShare', {
    from: deployer,
    args: [1648908000, dao, dev],
    log: true,
    deterministicDeployment: false,
  });
};

module.exports.tags = ['BrrrrShare'];
