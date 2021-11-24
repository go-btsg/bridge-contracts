# Bridge Smart Contracts

# Documentation

The contracts directory contains the following subfolders:

```jsx
contracts/
	chainlink/ - related to chainlink integration
	interfaces/ - contains interfaces of the project contracts
	mock/ - contracts for tests
	oracles/ - related to oracle's stake management
	periphery/ - periphery contracts
	transfers/ - related to core cross-chain functionality
```

The full list of contracts:

- BridgeGate 
- AggregatorBase
- SignatureAggregator
- ConfirmationAggregator
- SignatureVerifier
- DelegatedStaking
- CallProxy
- FeeProxy
- WrappedAsset
- DefiController
- Pausable

## Transfers

**BridgeGate**

Contract for assets transfers. The user can transfer the asset to any of the approved chains. The admin manages the assets, fees and other important protocol parameters.

The detailed methods description can be found in the contracts themselves.

## Chainlink

**AggregatorBase**

The base contract for Chainlink oracles management. Allows to add/remove oracles, manage the minimal required amount of confirmations and assign oracle admins.

**ConfirmationAggregator**

Extends the **AggregatorBase** with confirmation-related methods; is deployed to the chain with low fees and is used to collect confirmations from oracles.

**SignatureAggregator**

Extends the **AggregatorBase** with confirmation-related methods; is deployed to the chain with low fees and is used to collect signatures from oracles that confirm the transfers.

**SignatureVerifier.sol**

Is deployed to the chain with high fees and is used to verify the transfer by oracles signatures.

## Oracles

Contains variety of the contracts interfaces.

**DelegatedStaking**

Manages oracle and delegator stakes. Oracles are required to stake LINK token to be accepted as an oracle on aggregators.

## Periphery

**WrappedAsset**

ERC20 token that is used as wrapped asset to represent the native token value on the other chains.

**DefiController**

Mock contract responsible for using the asset from the contracts in other DeFi protocols to earn extra reward.

**FeeProxy**

Helper to swap any token to Link. \*\*\*\*

**CallProxy**

Proxy to execute the other contract calls. This contract is used when the user requests transfer with specific call of other contract.

**Pausable**

Helper for pausable contracts.
## Test

```
yarn start-ganache 
```
create .env with 

```
TEST_BSC_PROVIDER=https://bsc-dataseed.binance.org/
TEST_ORACLE_KEYS=["0x512aba0","0x512aba0"]
```

Where TEST_ORACLE_KEYS is private keys from ganache

```
yarn test
```
