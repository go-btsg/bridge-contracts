const BridgeGate = artifacts.require("BridgeGate");
const ConfirmationAggregator = artifacts.require("ConfirmationAggregator");
const SignatureVerifier = artifacts.require("SignatureVerifier");
const CallProxy = artifacts.require("CallProxy");
const FeeProxy = artifacts.require("FeeProxy");
const DefiController = artifacts.require("DefiController");
const { getWeth } = require("./utils");
const { deployProxy } = require("@openzeppelin/truffle-upgrades");
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

module.exports = async function(deployer, network) {
  // if (network == "test") return;

  const bridgeInitParams = require("../assets/bridgeInitParams")[network];
  let bridgeInstance;
  let weth = await getWeth(deployer, network);
  console.log("weth: " + weth);
  if (bridgeInitParams.type == "full") {
    //   function initialize(
    //     uint256 _excessConfirmations,
    //     address _signatureVerifier,
    //     address _confirmationAggregator,
    //     address _callProxy,
    //     uint256[] memory _supportedChainIds,
    //     ChainSupportInfo[] memory _chainSupportInfo,
    //     IWETH _weth,
    //     IFeeProxy _feeProxy,
    //     IDefiController _defiController,
    //     address _treasury
    // )
    await deployProxy(
      BridgeGate,
      [
        bridgeInitParams.excessConfirmations,    
        ZERO_ADDRESS, //SignatureVerifier.address.toString(),
        ConfirmationAggregator.address.toString(),
        CallProxy.address.toString(),
        bridgeInitParams.supportedChains,
        bridgeInitParams.chainSupportInfo,
        weth,
        FeeProxy.address.toString(),
        DefiController.address.toString(),
      ],
      { deployer }
    );
    aggregatorInstance = await ConfirmationAggregator.deployed();
    bridgeInstance = await BridgeGate.deployed();

    console.log("ConfirmationAggregator: " + aggregatorInstance.address);
    console.log("BridgeGate: " + bridgeInstance.address);
  } else {
    await deployProxy(
      BridgeGate,
      [
        bridgeInitParams.excessConfirmations,
        SignatureVerifier.address.toString(),        
        ZERO_ADDRESS, //ConfirmationAggregator.address.toString(),
        CallProxy.address.toString(),
        bridgeInitParams.supportedChains,
        bridgeInitParams.chainSupportInfo,
        DefiController.address.toString(),
        weth,
        FeeProxy.address.toString(),
        DefiController.address.toString(),
      ],
      { deployer }
    );
    aggregatorInstance = await SignatureVerifier.deployed();
    bridgeInstance = await BridgeGate.deployed();

    console.log("ConfirmationAggregator: " + aggregatorInstance.address);
    console.log("BridgeGate: " + bridgeInstance.address);
  }
  await aggregatorInstance.setBridgeAddress(
    bridgeInstance.address.toString()
  );

  console.log("aggregator setBridgeAddress: " + bridgeInstance.address.toString());
};
