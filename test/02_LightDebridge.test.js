const Web3 = require("web3");
const { expectRevert } = require("@openzeppelin/test-helpers");
const { ZERO_ADDRESS, permit } = require("./utils.spec");
const { MAX_UINT256 } = require("@openzeppelin/test-helpers/src/constants");
const MockLinkToken = artifacts.require("MockLinkToken");
const MockToken = artifacts.require("MockToken");
const WrappedAsset = artifacts.require("WrappedAsset");
const CallProxy = artifacts.require("CallProxy");
const DefiController = artifacts.require("DefiController");
const { toWei } = web3.utils;
const { BigNumber } = require("ethers");
const MAX = web3.utils.toTwosComplement(-1);
const Tx = require("ethereumjs-tx");
const bscWeb3 = new Web3(process.env.TEST_BSC_PROVIDER);
const oracleKeys = JSON.parse(process.env.TEST_ORACLE_KEYS);
const bobPrivKey = "0x79b2a2a43a1e9f325920f99a720605c9c563c61fb5ae3ebe483f83f1230512d3";

function toBN(number) {
  return BigNumber.from(number.toString());
}

const transferFeeBps = 50;
const minReservesBps = 3000;
const BPS = toBN(10000);

const referralCode = 555;

contract("BridgeGate light mode", function () {
  before(async function () {
    this.signers = await ethers.getSigners();
    aliceAccount = this.signers[0];
    bobAccount = this.signers[1];
    carolAccount = this.signers[2];
    eveAccount = this.signers[3];
    feiAccount = this.signers[4];
    devidAccount = this.signers[5];
    alice = aliceAccount.address;
    bob = bobAccount.address;
    carol = carolAccount.address;
    eve = eveAccount.address;
    fei = feiAccount.address;
    devid = devidAccount.address;

    const Bridge = await ethers.getContractFactory("MockBridgeGate", alice);
    const ConfirmationAggregator = await ethers.getContractFactory("ConfirmationAggregator", alice);
    const SignatureVerifier = await ethers.getContractFactory("SignatureVerifier", alice);
    const DefiControllerFactory = await ethers.getContractFactory("DefiController", alice);

    const WETH9 = await deployments.getArtifact("WETH9");
    const WETH9Factory = await ethers.getContractFactory(WETH9.abi, WETH9.bytecode, alice);
    this.mockToken = await MockToken.new("Link Token", "dLINK", 18, {
      from: alice,
    });
    this.linkToken = await MockLinkToken.new("Link Token", "dLINK", 18, {
      from: alice,
    });
    this.dbrToken = await MockLinkToken.new("DBR", "DBR", 18, {
      from: alice,
    });
    this.amountThreshold = toWei("1000");
    this.minConfirmations = 3;
    //this.confirmationAggregatorAddress = "0x72736f8c88bd1e438b05acc28c58ac21c5dc76ce";
    //this.aggregatorInstance = new web3.eth.Contract(
    //  ConfirmationAggregator.abi,
    //  this.confirmationAggregatorAddress
    //);
    this.confirmationThreshold = 5; //Confirmations per block before extra check enabled.
    this.excessConfirmations = 4; //Confirmations count in case of excess activity.

    //   function initialize(
    //     uint256 _minConfirmations,
    //     uint256 _confirmationThreshold,
    //     uint256 _excessConfirmations,
    //     address _wrappedAssetAdmin,
    //     address _bridgeAddress
    // )
    this.confirmationAggregator = await upgrades.deployProxy(ConfirmationAggregator, [
      this.minConfirmations,
      this.confirmationThreshold,
      this.excessConfirmations,
      alice,
      ZERO_ADDRESS,
    ]);

    await this.confirmationAggregator.deployed();
    //   function initialize(
    //     uint256 _minConfirmations,
    //     uint256 _confirmationThreshold,
    //     uint256 _excessConfirmations,
    //     address _wrappedAssetAdmin,
    //     address _bridgeAddress
    // )
    this.signatureVerifier = await upgrades.deployProxy(SignatureVerifier, [
      this.minConfirmations,
      this.confirmationThreshold,
      this.excessConfirmations,
      alice,
      ZERO_ADDRESS,
    ]);
    await this.signatureVerifier.deployed();
    this.initialOracles = [
      // {
      //   address: alice,
      //   admin: alice,
      // },
      {
        account: bobAccount,
        address: bob,
        admin: carol,
      },
      {
        account: carolAccount,
        address: carol,
        admin: eve,
      },
      {
        account: eveAccount,
        address: eve,
        admin: carol,
      },
      {
        account: feiAccount,
        address: fei,
        admin: eve,
      },
      {
        account: devidAccount,
        address: devid,
        admin: carol,
      },
    ];
    for (let oracle of this.initialOracles) {
      await this.signatureVerifier.addOracles([oracle.address], [oracle.address], [false], {
        from: alice,
      });
    }

    //Alice is required oracle
    await this.signatureVerifier.addOracles([alice], [alice], [true], {
      from: alice,
    });

    this.defiController = await upgrades.deployProxy(DefiControllerFactory, []);
    this.callProxy = await CallProxy.new({
      from: alice,
    });
    const maxAmount = toWei("100000000000");
    const fixedNativeFee = toWei("0.00001");
    const isSupported = true;
    const supportedChainIds = [42, 56];
    this.weth = await WETH9Factory.deploy();

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

    this.bridge = await upgrades.deployProxy(
      Bridge,
      [
        this.excessConfirmations,
        this.signatureVerifier.address.toString(),
        this.confirmationAggregator.address.toString(),
        this.callProxy.address.toString(),
        supportedChainIds,
        [
          {
            transferFeeBps,
            fixedNativeFee,
            isSupported,
          },
          {
            transferFeeBps,
            fixedNativeFee,
            isSupported,
          },
        ],
        this.weth.address,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        devid,
        1, //overrideChainId
      ],
      {
        initializer: "initializeMock",
        kind: "transparent",
      }
    );

    await this.bridge.deployed();
    const GOVMONITORING_ROLE = await this.bridge.GOVMONITORING_ROLE();
    await this.bridge.grantRole(GOVMONITORING_ROLE, alice);
    await this.signatureVerifier.setBridgeAddress(this.bridge.address.toString());

    this.wethBridgeId = await this.bridge.getBridgeId(1, this.weth.address);
    this.nativeBridgeId = await this.bridge.getBridgeId(1, ZERO_ADDRESS);
    await this.bridge.updateAssetFixedFees(this.wethBridgeId, supportedChainIds, [
      fixedNativeFee,
      fixedNativeFee,
    ]);

    const Bridge_GATE_ROLE = await this.callProxy.Bridge_GATE_ROLE();
    await this.callProxy.grantRole(Bridge_GATE_ROLE, this.bridge.address);
  });

  context("Test setting configurations by different users", () => {
    it("should set Verifier if called by the admin", async function () {
      await this.bridge.setSignatureVerifier(this.signatureVerifier.address, {
        from: alice,
      });
      const newAggregator = await this.bridge.signatureVerifier();
      assert.equal(this.signatureVerifier.address, newAggregator);
    });

    it("should set defi controller if called by the admin", async function () {
      const defiController = this.defiController.address;
      await this.bridge.setDefiController(defiController, {
        from: alice,
      });
      const newDefiController = await this.bridge.defiController();
      assert.equal(defiController, newDefiController);
    });

    it("should reject setting Verifier if called by the non-admin", async function () {
      await expectRevert(
        this.bridge.connect(bobAccount).setSignatureVerifier(ZERO_ADDRESS),
        "AdminBadRole()"
      );
    });

    it("should reject setting defi controller if called by the non-admin", async function () {
      await expectRevert(
        this.bridge.connect(bobAccount).setDefiController(ZERO_ADDRESS),
        "AdminBadRole()"
      );
    });
  });

  context("Test managing assets", () => {
    const isSupported = true;
    it("should add external asset if called by the admin", async function () {
      const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
      const chainId = 56;
      const maxAmount = toWei("100000000000");
      const amountThreshold = toWei("10000000000000");
      const fixedFee = toWei("0.00001");
      const supportedChainIds = [42, 3];
      const name = "MUSD";
      const symbol = "Magic Dollar";
      const decimals = 18;

      //   function confirmNewAsset(
      //     address _tokenAddress,
      //     uint256 _chainId,
      //     string memory _name,
      //     string memory _symbol,
      //     uint8 _decimals,
      //     bytes[] memory _signatures
      // )
      const bridgeId = await this.signatureVerifier.getBridgeId(chainId, tokenAddress);
      //console.log('bridgeId '+bridgeId);
      const deployId = await this.signatureVerifier.getDeployId(bridgeId, name, symbol, decimals);

      let signatures = "0x";
      for (let i = 0; i < oracleKeys.length; i++) {
        const oracleKey = oracleKeys[i];
        let currentSignature = (await bscWeb3.eth.accounts.sign(deployId, oracleKey)).signature;
        //HACK remove first 0x
        signatures += currentSignature.substring(2, currentSignature.length);
      }
      await this.signatureVerifier
        .connect(this.initialOracles[0].account)
        .confirmNewAsset(tokenAddress, chainId, name, symbol, decimals, signatures);

      ////   function getDeployId(
      ////     bytes32 _bridgeId,
      ////     string memory _name,
      ////     string memory _symbol,
      ////     uint8 _decimals
      //// )
      ////function deployAsset(bytes32 _deployId)
      //await this.signatureVerifier.deployAsset(deployId, {
      //  from: this.initialOracles[0].address,
      //});

      await this.bridge.updateAsset(bridgeId, maxAmount, minReservesBps, amountThreshold, {
        from: alice,
      });
      const bridge = await this.bridge.getBridge(bridgeId);
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      assert.equal(bridge.maxAmount.toString(), maxAmount);
      assert.equal(bridgeFeeInfo.collectedFees.toString(), "0");
      assert.equal(bridge.balance.toString(), "0");
      assert.equal(bridge.minReservesBps.toString(), minReservesBps);
    });

    it("should reject add external asset without DSRM confirmation", async function () {
      const tokenAddress = "0x5A0b54D5dc17e0AadC383d2db43B0a0D3E029c4c";
      const chainId = 56;
      const name = "SPARK";
      const symbol = "SPARK Dollar";
      const decimals = 18;

      const bridgeId = await this.signatureVerifier.getBridgeId(chainId, tokenAddress);
      //console.log('bridgeId '+bridgeId);
      const deployId = await this.signatureVerifier.getDeployId(bridgeId, name, symbol, decimals);

      let signatures = "0x";
      //start from 1 (skipped alice)
      for (let i = 1; i < oracleKeys.length; i++) {
        const oracleKey = oracleKeys[i];
        let currentSignature = (await bscWeb3.eth.accounts.sign(deployId, oracleKey)).signature;
        //HACK remove first 0x
        signatures += currentSignature.substring(2, currentSignature.length);
      }

      await expectRevert(
        this.signatureVerifier.confirmNewAsset(
          tokenAddress,
          chainId,
          name,
          symbol,
          decimals,
          signatures,
          {
            from: alice,
          }
        ),
        "NotConfirmedByRequiredOracles()"
      );
    });

    it("should reject add external asset without -1 confirmation", async function () {
      const tokenAddress = "0x5A0b54D5dc17e0AadC383d2db43B0a0D3E029c4c";
      const chainId = 56;
      const name = "MUSD";
      const symbol = "Magic Dollar";
      const decimals = 18;

      const bridgeId = await this.signatureVerifier.getBridgeId(chainId, tokenAddress);
      //console.log('bridgeId '+bridgeId);
      const deployId = await this.signatureVerifier.getDeployId(bridgeId, name, symbol, decimals);

      let signatures = "0x";
      // count of oracles = this.minConfirmations - 1
      for (let i = 0; i < this.minConfirmations - 1; i++) {
        const oracleKey = oracleKeys[i];
        let currentSignature = (await bscWeb3.eth.accounts.sign(deployId, oracleKey)).signature;
        //HACK remove first 0x
        signatures += currentSignature.substring(2, currentSignature.length);
      }

      await expectRevert(
        this.signatureVerifier.confirmNewAsset(
          tokenAddress,
          chainId,
          name,
          symbol,
          decimals,
          signatures,
          {
            from: alice,
          }
        ),
        "DeployNotConfirmed()"
      );
    });
  });

  context("Test send method", () => {
    it("should send native tokens from the current chain", async function () {
      const tokenAddress = ZERO_ADDRESS;
      const chainId = await this.bridge.getChainId();
      const receiver = bob;
      const amount = toBN(toWei("1"));
      const chainIdTo = 42;
      const bridgeWethId = await this.bridge.getBridgeId(chainId, this.weth.address);
      const balance = toBN(await this.weth.balanceOf(this.bridge.address));
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeWethId);
      const supportedChainInfo = await this.bridge.getChainSupport(chainIdTo);
      const feesWithFix = toBN(supportedChainInfo.transferFeeBps)
        .mul(amount)
        .div(BPS)
        .add(toBN(supportedChainInfo.fixedNativeFee));
      await this.bridge.send(tokenAddress, receiver, amount, chainIdTo, false, referralCode, {
        value: amount,
        from: alice,
      });
      const newBalance = toBN(await this.weth.balanceOf(this.bridge.address));
      const newBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeWethId);
      assert.equal(balance.add(amount).toString(), newBalance.toString());
      assert.equal(
        bridgeFeeInfo.collectedFees.add(feesWithFix).toString(),
        newBridgeFeeInfo.collectedFees.toString()
      );
    });

    it("should send ERC20 tokens from the current chain", async function () {
      const tokenAddress = this.mockToken.address;
      const chainId = await this.bridge.getChainId();
      const receiver = bob;
      const amount = toBN(toWei("100"));
      const chainIdTo = 42;
      await this.mockToken.mint(alice, amount, {
        from: alice,
      });
      await this.mockToken.approve(this.bridge.address, amount, {
        from: alice,
      });
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      const balance = toBN(await this.mockToken.balanceOf(this.bridge.address));
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      const supportedChainInfo = await this.bridge.getChainSupport(chainIdTo);
      const nativeBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(this.nativeBridgeId);
      const fees = toBN(supportedChainInfo.transferFeeBps).mul(amount).div(BPS);
      await this.bridge.send(tokenAddress, receiver, amount, chainIdTo, false, referralCode, {
        value: supportedChainInfo.fixedNativeFee,
        from: alice,
      });
      const newNativeBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(
        this.nativeBridgeId
      );
      const newBalance = toBN(await this.mockToken.balanceOf(this.bridge.address));
      const newBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      assert.equal(balance.add(amount).toString(), newBalance.toString());
      assert.equal(
        bridgeFeeInfo.collectedFees.add(fees).toString(),
        newBridgeFeeInfo.collectedFees.toString()
      );
      assert.equal(
        nativeBridgeFeeInfo.collectedFees.add(toBN(supportedChainInfo.fixedNativeFee)).toString(),
        newNativeBridgeFeeInfo.collectedFees.toString()
      );
    });

    it("should reject sending too mismatched amount of native tokens", async function () {
      const tokenAddress = ZERO_ADDRESS;
      const receiver = bob;
      const chainId = await this.bridge.getChainId();
      const amount = toBN(toWei("1"));
      const chainIdTo = 42;
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      await expectRevert(
        this.bridge.send(tokenAddress, receiver, amount, chainIdTo, false, referralCode, {
          value: toWei("0.1"),
          from: alice,
        }),
        "AmountMismatch()"
      );
    });

    it("should reject sending tokens to unsupported chain", async function () {
      const tokenAddress = ZERO_ADDRESS;
      const receiver = bob;
      const chainId = await this.bridge.getChainId();
      const amount = toBN(toWei("1"));
      const chainIdTo = chainId;
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      await expectRevert(
        this.bridge.send(tokenAddress, receiver, amount, chainIdTo, false, referralCode, {
          value: amount,
          from: alice,
        }),
        "WrongTargedChain()"
      );
    });
  });

  context("Test mint method", () => {
    let bridgeId;
    let receiver;
    const amount = toBN(toWei("100"));
    const nonce = 1;
    const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
    const chainId = 56;
    let currentChainId;

    before(async function () {
      receiver = bob;
      bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      //console.log('bridgeId '+bridgeId);
      currentChainId = await this.bridge.getChainId();
      const submission = await this.bridge.getSubmissionId(
        bridgeId,
        chainId,
        currentChainId,
        amount,
        receiver,
        nonce
      );
      this.signatures = "0x";
      for (let i = 0; i < oracleKeys.length; i++) {
        const oracleKey = oracleKeys[i];
        let currentSignature = (await bscWeb3.eth.accounts.sign(submission, oracleKey)).signature;
        //HACK remove first 0x
        this.signatures += currentSignature.substring(2, currentSignature.length);
      }
    });

    it("should mint when the submission is approved", async function () {
      const balance = toBN("0");

      //   function mint(
      //     address _tokenAddress,
      //     uint256 _chainId,
      //     uint256 _chainIdFrom,
      //     address _receiver,
      //     uint256 _amount,
      //     uint256 _nonce,
      //     bytes[] calldata _signatures
      // )
      await this.bridge.mint(bridgeId, chainId, receiver, amount, nonce, this.signatures, {
        from: alice,
      });
      const bridge = await this.bridge.getBridge(bridgeId);
      const wrappedAsset = await WrappedAsset.at(bridge.tokenAddress);

      const newBalance = toBN(await wrappedAsset.balanceOf(receiver));
      const submissionId = await this.bridge.getSubmissionId(
        bridgeId,
        chainId,
        currentChainId,
        amount,
        receiver,
        nonce
      );
      const isSubmissionUsed = await this.bridge.isSubmissionUsed(submissionId);
      assert.equal(balance.add(amount).toString(), newBalance.toString());
      assert.ok(isSubmissionUsed);
    });

    // it("should update asset if called by the admin after deploy assets by mint", async function () {
    //     const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
    //     const chainId = 56;
    //     const maxAmount = toWei("100000000000");
    //     const amountThreshold = toWei("10000000000000");
    //     const fixedFee = toWei("0.00001");
    //     const transferFee = toWei("0.01");
    //     const minReserves = toWei("0.2");
    //     const supportedChainIds = [42, 3];
    //     const name = "MUSD";
    //     const symbol = "Magic Dollar";
    //     const decimals = 18;

    //     await this.bridge.updateAsset(
    //       bridgeId,
    //       maxAmount,
    //       minReserves,
    //       amountThreshold,
    //       {
    //         from: alice,
    //       }
    //     );
    //     const bridge = await this.bridge.getBridge(bridgeId);
    //     assert.equal(bridge.maxAmount.toString(), maxAmount);
    //     assert.equal(bridge.collectedFees.toString(), "0");
    //     assert.equal(bridge.balance.toString(), "0");
    //     assert.equal(bridge.minReserves.toString(), minReserves);
    // });

    it("should reject minting with unconfirmed submission", async function () {
      const wrongnonce = 4;
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      await expectRevert(
        this.bridge.mint(bridgeId, chainId, receiver, amount, wrongnonce, [], {
          //will call IConfirmationAggregator
          from: alice,
        }),
        "SubmissionNotConfirmed()"
      );
    });

    it("should reject minting with error signature", async function () {
      const wrongnonce = 4;
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      await expectRevert(
        this.bridge.mint(bridgeId, chainId, receiver, amount, wrongnonce, this.signatures, {
          from: alice,
        }),
        "NotConfirmedByRequiredOracles()"
      );
    });

    it("should reject minting twice", async function () {
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      await expectRevert(
        this.bridge.mint(bridgeId, chainId, receiver, amount, nonce, this.signatures, {
          from: alice,
        }),
        "SubmissionUsed()"
      );
    });
  });

  context("Test burn method", () => {
    it("should burning when the amount is suficient", async function () {
      const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
      const chainIdTo = 56;
      const receiver = alice;
      const amount = toBN(toWei("5"));
      const bridgeId = await this.bridge.getBridgeId(chainIdTo, tokenAddress);
      const bridge = await this.bridge.getBridge(bridgeId);
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      const wrappedAsset = await WrappedAsset.at(bridge.tokenAddress);
      const balance = toBN(await wrappedAsset.balanceOf(bob));
      // const deadline = toBN(Math.floor(Date.now() / 1000)+1000);
      const deadline = toBN(MAX_UINT256);
      const deadlineHex = web3.utils.padLeft(web3.utils.toHex(deadline.toString()), 64);
      const supportedChainInfo = await this.bridge.getChainSupport(chainIdTo);
      const permitSignature = await permit(
        wrappedAsset,
        bob,
        this.bridge.address,
        amount,
        deadline,
        bobPrivKey
      );
      const nativeBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(this.nativeBridgeId);
      await this.bridge.connect(bobAccount).burn(
        bridgeId,
        receiver,
        amount,
        chainIdTo,
        //deadline + signature;
        //                                      remove first 0x
        deadlineHex + permitSignature.substring(2, permitSignature.length),
        false,
        referralCode,
        {
          value: supportedChainInfo.fixedNativeFee,
        }
      );
      const newNativeBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(
        this.nativeBridgeId
      );
      const newBalance = toBN(await wrappedAsset.balanceOf(bob));
      assert.equal(balance.sub(amount).toString(), newBalance.toString());
      const newBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      const fees = toBN(supportedChainInfo.transferFeeBps).mul(amount).div(BPS);
      assert.equal(
        bridgeFeeInfo.collectedFees.add(fees).toString(),
        newBridgeFeeInfo.collectedFees.toString()
      );
      assert.equal(
        nativeBridgeFeeInfo.collectedFees.add(toBN(supportedChainInfo.fixedNativeFee)).toString(),
        newNativeBridgeFeeInfo.collectedFees.toString()
      );
    });

    it("should reject burning from current chain", async function () {
      const tokenAddress = this.weth.address;
      const chainId = await this.bridge.getChainId();
      const receiver = bob;
      const amount = toBN(toWei("1"));
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      const permit = "0x";
      await expectRevert(
        this.bridge.burn(bridgeId, receiver, amount, 42, permit, false, referralCode, {
          from: alice,
        }),
        "WrongChain()"
      );
    });

    //TODO: check 'send: amount does not cover fees' when pay by token
    //   it("should reject burning too few tokens", async function() {
    //     const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
    //     const chainIdTo = 56;
    //     const receiver = bob;
    //     const amount = toBN("10");
    //     const bridgeId = await this.bridge.getBridgeId(
    //       chainIdTo,
    //       tokenAddress
    //       );
    //     const bridge = await this.bridge.getBridge(bridgeId);
    //     const wrappedAsset = await WrappedAsset.at(bridge.tokenAddress);
    //     //const balance = toBN(await wrappedAsset.balanceOf(bob));
    //     const deadline = 0;
    //     const supportedChainInfo = await this.bridge.getChainSupport(chainIdTo);
    //     //const signature = "0x";
    //     const signature = await permit(
    //           wrappedAsset,
    //           bob,
    //           this.bridge.address,
    //           amount,
    //           deadline,
    //           bobPrivKey
    //       );
    //     await expectRevert(
    //       this.bridge.burn(
    //         bridgeId,
    //         receiver,
    //         amount,
    //         chainIdTo,
    //         deadline,
    //         signature,
    //         false,
    //         {
    //           from: bob,
    //           value: supportedChainInfo.fixedNativeFee,
    //         }
    //       ),
    //       "burn: amount too low"
    //     );
    //   });
  });

  context("Test claim method", () => {
    let receiver;
    const amount = toBN(toWei("0.9"));
    const nonce = 4;
    let chainId;
    let chainIdFrom = 87;
    let bridgeId;
    let erc20BridgeId;
    let curentChainSubmission;

    before(async function () {
      receiver = bob;
      chainId = await this.bridge.getChainId();
      bridgeId = await this.bridge.getBridgeId(chainId, this.weth.address);
      erc20BridgeId = await this.bridge.getBridgeId(chainId, this.mockToken.address);
      curentChainSubmission = await this.bridge.getSubmissionId(
        bridgeId,
        chainIdFrom,
        chainId,
        amount,
        receiver,
        nonce
      );
      this.ethSignatures = "0x";
      for (let i = 0; i < oracleKeys.length; i++) {
        const oracleKey = oracleKeys[i];
        let _currentSignature = (await bscWeb3.eth.accounts.sign(curentChainSubmission, oracleKey))
          .signature;
        //HACK remove first 0x
        this.ethSignatures += _currentSignature.substring(2, _currentSignature.length);
      }
      const erc20Submission = await this.bridge.getSubmissionId(
        erc20BridgeId,
        chainIdFrom,
        chainId,
        amount,
        receiver,
        nonce
      );

      this.erc20Signatures = "0x";
      for (let i = 0; i < oracleKeys.length; i++) {
        const oracleKey = oracleKeys[i];
        let currentSignature = (await bscWeb3.eth.accounts.sign(erc20Submission, oracleKey))
          .signature;
        //HACK remove first 0x
        this.erc20Signatures += currentSignature.substring(2, currentSignature.length);
      }
    });

    it("should reject native token without DSRM confirmation", async function () {
      currentSignatures = "0x";
      for (let i = 1; i < oracleKeys.length; i++) {
        const oracleKey = oracleKeys[i];
        let _currentSignature = (await bscWeb3.eth.accounts.sign(curentChainSubmission, oracleKey))
          .signature;
        //HACK remove first 0x
        currentSignatures += _currentSignature.substring(2, _currentSignature.length);
      }
      await expectRevert(
        this.bridge.claim(bridgeId, chainIdFrom, receiver, amount, nonce, currentSignatures, {
          from: alice,
        }),
        "NotConfirmedByRequiredOracles()"
      );
    });

    it("should claim native token when the submission is approved", async function () {
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      const balance = toBN(await this.weth.balanceOf(receiver));
      await this.bridge.claim(
        bridgeId,
        chainIdFrom,
        receiver,
        amount,
        nonce,
        this.ethSignatures,
        {
          from: alice,
        }
      );
      const newBalance = toBN(await this.weth.balanceOf(receiver));
      const submissionId = await this.bridge.getSubmissionId(
        bridgeId,
        chainIdFrom,
        chainId,
        amount,
        receiver,
        nonce
      );
      const isSubmissionUsed = await this.bridge.isSubmissionUsed(submissionId);
      const newBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      assert.equal(balance.add(amount).toString(), newBalance.toString());
      assert.equal(
        bridgeFeeInfo.collectedFees.toString(),
        newBridgeFeeInfo.collectedFees.toString()
      );
      assert.ok(isSubmissionUsed);
    });

    it("should claim ERC20 when the submission is approved", async function () {
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(erc20BridgeId);
      const balance = toBN(await this.mockToken.balanceOf(receiver));
      await this.bridge.claim(
        erc20BridgeId,
        chainIdFrom,
        receiver,
        amount,
        nonce,
        this.erc20Signatures,
        {
          from: alice,
        }
      );
      const newBalance = toBN(await this.mockToken.balanceOf(receiver));
      const submissionId = await this.bridge.getSubmissionId(
        erc20BridgeId,
        chainIdFrom,
        chainId,
        amount,
        receiver,
        nonce
      );
      const isSubmissionUsed = await this.bridge.isSubmissionUsed(submissionId);
      const newBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(erc20BridgeId);
      assert.equal(balance.add(amount).toString(), newBalance.toString());
      assert.equal(
        bridgeFeeInfo.collectedFees.toString(),
        newBridgeFeeInfo.collectedFees.toString()
      );
      assert.ok(isSubmissionUsed);
    });

    it("should reject claiming with unconfirmed submission", async function () {
      const wrongnonce = 122;
      await expectRevert(
        this.bridge.claim(
          bridgeId,
          chainIdFrom,
          receiver,
          amount,
          wrongnonce,
          this.ethSignatures,
          {
            from: alice,
          }
        ),
        "NotConfirmedByRequiredOracles()"
      );
    });

    it("should reject claiming twice", async function () {
      await expectRevert(
        this.bridge.claim(bridgeId, chainIdFrom, receiver, amount, nonce, this.ethSignatures, {
          from: alice,
        }),
        "SubmissionUsed()"
      );
    });
  });
});
