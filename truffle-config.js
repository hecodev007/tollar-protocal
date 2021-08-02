/**
 * Use this file to configure your truffle project. It's seeded with some
 * common settings for different networks and features like migrations,
 * compilation and testing. Uncomment the ones you need or modify
 * them to suit your project as necessary.
 *
 * More information about configuration can be found at:
 *
 * trufflesuite.com/docs/advanced/configuration
 *
 * To deploy via Infura you'll need a wallet provider (like @truffle/hdwallet-provider)
 * to sign your transactions before they're sent to a remote public node. Infura accounts
 * are available for free at: infura.io/register.
 *
 * You'll also need a mnemonic - the twelve word phrase the wallet uses to generate
 * public/private key pairs. If you're publishing your code to GitHub make sure you load this
 * phrase from a file you've .gitignored so it doesn't accidentally become public.
 *
 */

// const HDWalletProvider = require('@truffle/hdwallet-provider');
// const infuraKey = "fj4jll3k.....";
//
 const fs = require('fs');
 const mnemonic = fs.readFileSync(".secret").toString().trim();

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.5.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100000
          }
        }
      },
      {
        version: "0.6.11",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100000
          }
        }
      },
      {
        version: "0.7.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100000
          }
        }
      },
      {
        version: "0.8.0",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100000
          }
        }
      },
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100000
          }
        }
      }
    ],
  },
  etherscan: {
     apiKey: `QVDVP85WK5D2UT77DWYEZPHGWZ2U5JFU3K` // ETH Mainnet
    //apiKey: `UMHGM6QP7MVI1NUVHBW4N3NZHTPJPAFG6J` // BSC
  },
  defaultNetwork: "ropsten",
  networks: {

    ropsten: {
      url: `https://ropsten.infura.io/v3/85c51263825545bf8496006327bd98d1`,
      accounts: [mnemonic],
      chainId: 3,
      gasPrice: 20000000000,
      gasMultiplier: 1.2
    },
    bsc_mainnet: {
      url: `https://bsc-dataseed.binance.org/`,
      accounts: [mnemonic],
      chainId: 56,
      gas: "auto",
      gasPrice: 15000000000,
      gasMultiplier: 1.2
    },
    bsc_test: {
      url: `https://data-seed-prebsc-1-s1.binance.org:8545/`,
      accounts: [mnemonic],
      chainId: 97,
      gas: 8000000,
      gasPrice: 15000000000,
      gasMultiplier: 1.2
    },

    rinkeby: {
      url: `https://rinkeby.infura.io/v3/85c51263825545bf8496006327bd98d1`,
      accounts: [mnemonic],
      chainId: 4,
      gas: "auto",
      gasPrice: "auto",
      gasMultiplier: 1.2
    }

  }
};

