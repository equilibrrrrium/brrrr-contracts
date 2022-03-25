const { version } = require("chai");

require("dotenv").config();

require("@nomiclabs/hardhat-etherscan");
require('hardhat-deploy');
require("@nomiclabs/hardhat-waffle");
require("hardhat-gas-reporter");
require("solidity-coverage");
require('hardhat-contract-sizer');

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.6.12",
        settings: {
          optimizer: {
            enabled: true,
            runs: 99999
          }
        }
      },
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 99999
          }
        }
      },
      {
        version: "0.7.6"
      }
        
    ],

  },
  paths: {
    artifacts: './artifacts',
  },
  networks: {
    mainBSC: {
      chainId: 56,
      url: 'https://bsc-dataseed.binance.org/',
      accounts: ['helloworld'],

    }
  },
  etherscan: {
    apiKey: 'helloworld'
  },
  namedAccounts: {
    deployer: '0x9F6051748Fa8A4b308240bbb7DEEAE5e2b47DcE1',
    dev: '0x625188909f5aaDFFd2175257bdC686984ccC39D9',
    dao: '0x627dc25fb60BaE0BBEeE0D84cc3f37C085b34090'
  },
};
