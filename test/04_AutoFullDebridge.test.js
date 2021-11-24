const { expectRevert } = require("@openzeppelin/test-helpers");
const { ZERO_ADDRESS, permit } = require("./utils.spec");
const MockLinkToken = artifacts.require("MockLinkToken");
const MockToken = artifacts.require("MockToken");
const WrappedAsset = artifacts.require("WrappedAsset");
const FeeProxy = artifacts.require("FeeProxy");
const CallProxy = artifacts.require("CallProxy");
const IUniswapV2Pair = artifacts.require("IUniswapV2Pair");

const { MAX_UINT256 } = require("@openzeppelin/test-helpers/src/constants");
const { toWei } = web3.utils;
const MAX = web3.utils.toTwosComplement(-1);
const bobPrivKey = "0x79b2a2a43a1e9f325920f99a720605c9c563c61fb5ae3ebe483f83f1230512d3";

const { BigNumber } = require("ethers");

function toBN(number) {
  return BigNumber.from(number.toString());
}
const transferFeeBps = 50;
const minReservesBps = 3000;
const BPS = toBN(10000);
const referralCode = 555;
const zeroFlag = 0;

const ethChainId = 1;
const bscChainId = 56;
const hecoChainId = 256;

contract("BridgeGate full with auto", function () {
  let reserveAddress;
  const claimFee = toBN(toWei("0"));
  const data = "0x";

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

    reserveAddress = devid;
    const Bridge = await ethers.getContractFactory("BridgeGate", alice);
    const ConfirmationAggregator = await ethers.getContractFactory("ConfirmationAggregator", alice);
    const UniswapV2 = await deployments.getArtifact("UniswapV2Factory");
    const WETH9 = await deployments.getArtifact("WETH9");
    const UniswapV2Factory = await ethers.getContractFactory(
      UniswapV2.abi,
      UniswapV2.bytecode,
      alice
    );
    const WETH9Factory = await ethers.getContractFactory(WETH9.abi, WETH9.bytecode, alice);
    const DefiControllerFactory = await ethers.getContractFactory("DefiController", alice);

    this.mockToken = await MockToken.new("Link Token", "dLINK", 18, {
      from: alice,
    });
    this.linkToken = await MockLinkToken.new("Link Token", "dLINK", 18, {
      from: alice,
    });
    this.dbrToken = await MockLinkToken.new("DBR", "DBR", 18, {
      from: alice,
    });
    this.amountThreshols = toWei("1000");
    this.minConfirmations = 1;
    this.confirmationThreshold = 5; //Confirmations per block before extra check enabled.
    this.excessConfirmations = 3; //Confirmations count in case of excess activity.

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
      await this.confirmationAggregator.addOracles([oracle.address], [oracle.admin], [false], {
        from: alice,
      });
    }
    this.uniswapFactory = await UniswapV2Factory.deploy(carol);
    this.feeProxy = await FeeProxy.new(this.linkToken.address, this.uniswapFactory.address, {
      from: alice,
    });
    this.callProxy = await CallProxy.new({
      from: alice,
    });
    this.defiController = await upgrades.deployProxy(DefiControllerFactory, []);
    const maxAmount = toWei("1000000");
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

    this.bridge = await upgrades.deployProxy(Bridge, [
      this.excessConfirmations,
      ZERO_ADDRESS,
      ZERO_ADDRESS,
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
    ]);
    await this.bridge.deployed();
    const GOVMONITORING_ROLE = await this.bridge.GOVMONITORING_ROLE();
    await this.bridge.grantRole(GOVMONITORING_ROLE, alice);
    await this.confirmationAggregator.setBridgeAddress(this.bridge.address.toString());

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
    it("should set aggregator if called by the admin", async function () {
      const aggregator = this.confirmationAggregator.address;
      await this.bridge.setAggregator(aggregator, {
        from: alice,
      });
      const newAggregator = await this.bridge.confirmationAggregator();
      assert.equal(aggregator, newAggregator);
    });

    it("should set fee proxy if called by the admin", async function () {
      const feeProxy = this.feeProxy.address;
      await this.bridge.setFeeProxy(feeProxy, {
        from: alice,
      });
      const newFeeProxy = await this.bridge.feeProxy();
      assert.equal(feeProxy, newFeeProxy);
    });

    it("should set defi controller if called by the admin", async function () {
      const defiController = this.defiController.address;
      await this.bridge.setDefiController(defiController, {
        from: alice,
      });
      const newDefiController = await this.bridge.defiController();
      assert.equal(defiController, newDefiController);
    });

    // it("should set weth if called by the admin", async function() {
    //   const weth = this.weth.address;
    //   await this.bridge.setWeth(weth, {
    //     from: alice,
    //   });
    //   const newWeth = await this.bridge.weth();
    //   assert.equal(weth, newWeth);
    // });

    it("should reject setting aggregator if called by the non-admin", async function () {
      await expectRevert(
        this.bridge.connect(bobAccount).setAggregator(ZERO_ADDRESS),
        "AdminBadRole()"
      );
    });

    it("should reject setting fee proxy if called by the non-admin", async function () {
      await expectRevert(
        this.bridge.connect(bobAccount).setFeeProxy(ZERO_ADDRESS),
        "AdminBadRole()"
      );
    });

    it("should reject setting defi controller if called by the non-admin", async function () {
      await expectRevert(
        this.bridge.connect(bobAccount).setDefiController(ZERO_ADDRESS),
        "AdminBadRole()"
      );
    });

    // it("should reject setting weth if called by the non-admin", async function() {
    //   await expectRevert(
    //     this.bridge.connect(bobAccount).setWeth(ZERO_ADDRESS),
    //     "AdminBadRole()"
    //   );
    // });
  });

  context("Test managing assets", () => {
    before(async function () {
      currentChainId = await this.bridge.getChainId();
      const newSupply = toWei("100");
      await this.linkToken.mint(alice, newSupply, {
        from: alice,
      });
      await this.dbrToken.mint(alice, newSupply, {
        from: alice,
      });
      //await this.dbrToken.transferAndCall(
      //  this.confirmationAggregator.address.toString(),
      //  newSupply,
      //  "0x",
      //  {
      //    from: alice,
      //  }
      //);
      //await this.linkToken.transferAndCall(
      //  this.confirmationAggregator.address.toString(),
      //  newSupply,
      //  "0x",
      //  {
      //    from: alice,
      //  }
      //);
    });

    const isSupported = true;
    it("should add external asset if called by the admin", async function () {
      const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
      const chainId = 56;
      const maxAmount = toWei("100000000000000000");
      const amountThreshold = toWei("10000000000000");
      const fixedNativeFee = toWei("0.00001");
      const supportedChainIds = [42, 3, 56];
      const name = "MUSD";
      const symbol = "Magic Dollar";
      const decimals = 18;
      const bridgeId = await this.bridge.getBridgeId(chainId, tokenAddress);
      //   function confirmNewAsset(
      //     address _tokenAddress,
      //     uint256 _chainId,
      //     string memory _name,
      //     string memory _symbol,
      //     uint8 _decimals
      // )
      await this.confirmationAggregator
        .connect(this.initialOracles[0].account)
        .confirmNewAsset(tokenAddress, chainId, name, symbol, decimals);

      //   function getDeployId(
      //     bytes32 _bridgeId,
      //     string memory _name,
      //     string memory _symbol,
      //     uint8 _decimals
      // )
      // let deployId = await this.confirmationAggregator.getDeployId(bridgeId, name, symbol, decimals)
      // //function deployAsset(bytes32 _deployId)
      // await this.bridge.checkAndDeployAsset(bridgeId, {
      //   from: this.initialOracles[0].address,
      // });
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
  });

  context("Test send method", () => {
    it("should send native tokens from the current chain", async function () {
      const tokenAddress = ZERO_ADDRESS;
      const receiver = bob;
      const amount = toBN(toWei("1"));
      const chainIdTo = 42;
      const balance = toBN(await this.weth.balanceOf(this.bridge.address));
      const bridgeWethFeeInfo = await this.bridge.getBridgeFeeInfo(this.wethBridgeId);
      const supportedChainInfo = await this.bridge.getChainSupport(chainIdTo);
      const feesWithFix = toBN(supportedChainInfo.transferFeeBps)
        .mul(amount)
        .div(BPS)
        .add(toBN(supportedChainInfo.fixedNativeFee));

      await this.bridge.autoSend(
        tokenAddress,
        receiver,
        amount,
        chainIdTo,
        reserveAddress,
        claimFee,
        data,
        false,
        zeroFlag,
        referralCode,
        {
          value: amount,
          from: alice,
        }
      );
      const newBalance = toBN(await this.weth.balanceOf(this.bridge.address));
      const newWethBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(this.wethBridgeId);
      assert.equal(balance.add(amount).toString(), newBalance.toString());
      assert.equal(
        bridgeWethFeeInfo.collectedFees.add(feesWithFix).toString(),
        newWethBridgeFeeInfo.collectedFees.toString()
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
      await this.bridge.autoSend(
        tokenAddress,
        receiver,
        amount,
        chainIdTo,
        reserveAddress,
        claimFee,
        data,
        false,
        zeroFlag,
        referralCode,
        {
          value: supportedChainInfo.fixedNativeFee,
          from: alice,
        }
      );
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
      await expectRevert(
        this.bridge.autoSend(
          tokenAddress,
          receiver,
          amount,
          chainIdTo,
          reserveAddress,
          claimFee,
          data,
          false,
          zeroFlag,
          referralCode,
          {
            value: toWei("0.1"),
            from: alice,
          }
        ),
        "AmountMismatch()"
      );
    });

    it("should reject sending tokens to unsupported chain", async function () {
      const tokenAddress = ZERO_ADDRESS;
      const receiver = bob;
      const chainId = await this.bridge.getChainId();
      const amount = toBN(toWei("1"));
      const chainIdTo = chainId;
      await expectRevert(
        this.bridge.autoSend(
          tokenAddress,
          receiver,
          amount,
          chainIdTo,
          reserveAddress,
          claimFee,
          data,
          false,
          zeroFlag,
          referralCode,
          {
            value: amount,
            from: alice,
          }
        ),
        "WrongTargedChain()"
      );
    });
  });

  context("Test mint method", () => {
    const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
    let receiver;
    let nativeSender;
    const amount = toBN(toWei("100"));
    const nonce = 2;
    let burnAutoSubmissionId;
    before(async function () {
      nativeSender = bob;
      receiver = bob;
      const newSupply = toWei("100");
      await this.linkToken.mint(alice, newSupply, {
        from: alice,
      });
      await this.dbrToken.mint(alice, newSupply, {
        from: alice,
      });
      //await this.dbrToken.transferAndCall(
      //  this.confirmationAggregator.address.toString(),
      //  newSupply,
      //  "0x",
      //  {
      //    from: alice,
      //  }
      //);
      //await this.linkToken.transferAndCall(
      //  this.confirmationAggregator.address.toString(),
      //  newSupply,
      //  "0x",
      //  {
      //    from: alice,
      //  }
      //);
      const bridgeId = await this.bridge.getBridgeId(bscChainId, tokenAddress);

      //  function getAutoSubmissionIdFrom(
      //     bytes memory _nativeSender,
      //     bytes32 _bridgeId,
      //     uint256 _chainIdFrom,
      //     uint256 _amount,
      //     address _receiver,
      //     uint256 _nonce,
      //     address _fallbackAddress,
      //     uint256 _executionFee,
      //     bytes memory _data,
      //     uint8 _reservedFlag
      // )
      burnAutoSubmissionId = await this.bridge.getAutoSubmissionIdFrom(
        nativeSender,
        bridgeId,
        bscChainId,
        amount,
        receiver,
        nonce,
        reserveAddress,
        claimFee,
        data,
        zeroFlag
      );
      await this.confirmationAggregator.connect(bobAccount).submit(burnAutoSubmissionId);

      let submissionInfo = await this.confirmationAggregator.getSubmissionInfo(
        burnAutoSubmissionId
      );
      let submissionConfirmations = await this.confirmationAggregator.getSubmissionConfirmations(
        burnAutoSubmissionId
      );

      assert.equal(1, submissionInfo.confirmations);
      assert.equal(true, submissionConfirmations[0]);
      assert.equal(1, submissionConfirmations[1]);
    });

    it("should mint when the submission is approved", async function () {
      const bridgeId = await this.bridge.getBridgeId(bscChainId, tokenAddress);
      const balance = toBN("0");

      await this.bridge.autoMint(
        bridgeId,
        bscChainId,
        receiver,
        amount,
        nonce,
        [],
        reserveAddress,
        claimFee,
        data,
        zeroFlag,
        nativeSender,
        {
          from: alice,
        }
      );
      const bridge = await this.bridge.getBridge(bridgeId);
      const wrappedAsset = await WrappedAsset.at(bridge.tokenAddress);
      const newBalance = toBN(await wrappedAsset.balanceOf(receiver));

      const isSubmissionUsed = await this.bridge.isSubmissionUsed(burnAutoSubmissionId);
      assert.equal(balance.add(amount).toString(), newBalance.toString());
      assert.ok(isSubmissionUsed);
    });

    it("should reject minting with unconfirmed submission", async function () {
      const nonce = 4;
      const bridgeId = await this.bridge.getBridgeId(bscChainId, tokenAddress);
      await expectRevert(
        this.bridge.autoMint(
          bridgeId,
          bscChainId,
          receiver,
          amount,
          nonce,
          [],
          reserveAddress,
          claimFee,
          data,
          zeroFlag,
          nativeSender,
          {
            from: alice,
          }
        ),
        "SubmissionNotConfirmed()"
      );
    });

    it("should reject minting twice", async function () {
      const bridgeId = await this.bridge.getBridgeId(bscChainId, tokenAddress);
      await expectRevert(
        this.bridge.autoMint(
          bridgeId,
          bscChainId,
          receiver,
          amount,
          nonce,
          [],
          reserveAddress,
          claimFee,
          data,
          zeroFlag,
          nativeSender,
          {
            from: alice,
          }
        ),
        "SubmissionUsed()"
      );
    });
  });

  context("Test burn method", () => {
    it("should burning when the amount is suficient", async function () {
      const tokenAddress = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984";
      const chainIdTo = 56;
      const receiver = alice;
      const amount = toBN(toWei("100"));
      const bridgeId = await this.bridge.getBridgeId(chainIdTo, tokenAddress);
      const bridge = await this.bridge.getBridge(bridgeId);
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(bridgeId);
      const wrappedAsset = await WrappedAsset.at(bridge.tokenAddress);
      const balance = toBN(await wrappedAsset.balanceOf(bob));
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
      await this.bridge.connect(bobAccount).autoBurn(
        bridgeId,
        receiver,
        amount,
        chainIdTo,
        reserveAddress,
        claimFee,
        data,
        //deadline + signature;
        //                                      remove first 0x
        deadlineHex + permitSignature.substring(2, permitSignature.length),
        false,
        zeroFlag,
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
      const receiver = bob;
      const amount = toBN(toWei("1"));
      const permit = "0x";
      await expectRevert(
        this.bridge.autoBurn(
          this.wethBridgeId,
          receiver,
          amount,
          42,
          reserveAddress,
          claimFee,
          data,
          permit,
          false,
          zeroFlag,
          referralCode,
          {
            from: alice,
          }
        ),
        "WrongChain()"
      );
    });
  });

  context("Test claim method", () => {
    const tokenAddress = ZERO_ADDRESS;
    let receiver;
    let nativeSender;
    const amount = toBN(toWei("0.9"));
    const nonce = 4;
    let chainIdFrom = hecoChainId;
    let outsideBridgeId;
    let erc20BridgeId;
    before(async function () {
      receiver = bob;
      nativeSender = alice;
      outsideBridgeId = await this.bridge.getBridgeId(
        56,
        "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
      );
      erc20BridgeId = await this.bridge.getBridgeId(ethChainId, this.mockToken.address);

      //   function getAutoSubmissionIdFrom(
      //     bytes memory _nativeSender,
      //     bytes32 _bridgeId,
      //     uint256 _chainIdFrom,
      //     uint256 _amount,
      //     address _receiver,
      //     uint256 _nonce,
      //     address _fallbackAddress,
      //     uint256 _executionFee,
      //     bytes memory _data,
      //     uint8 _reservedFlag
      // )
      const currentChainSubmission = await this.bridge.getAutoSubmissionIdFrom(
        nativeSender,
        this.wethBridgeId,
        chainIdFrom,
        amount,
        receiver,
        nonce,
        reserveAddress,
        claimFee,
        data,
        zeroFlag
      );
      await this.confirmationAggregator.connect(bobAccount).submit(currentChainSubmission);

      // const outsideChainSubmission = await this.bridge.getAutoSubmissionIdFrom(
      //   nativeSender,
      //   outsideBridgeId,
      //   chainIdFrom,
      //   // 56,
      //   amount,
      //   receiver,
      //   nonce,
      //   reserveAddress,
      //   claimFee,
      //   data,
      //   zeroFlag
      // );
      // await this.confirmationAggregator.connect(bobAccount).submit(outsideChainSubmission);

      const erc20Submission = await this.bridge.getAutoSubmissionIdFrom(
        nativeSender,
        erc20BridgeId,
        chainIdFrom,
        amount,
        receiver,
        nonce,
        reserveAddress,
        claimFee,
        data,
        zeroFlag
      );
      await this.confirmationAggregator.connect(bobAccount).submit(erc20Submission);
    });

    it("should claim native token when the submission is approved", async function () {
      const bridgeFeeInfo = await this.bridge.getBridgeFeeInfo(this.wethBridgeId);
      const balance = toBN(await this.weth.balanceOf(receiver));

      //   function autoClaim(
      //     bytes32 _bridgeId,
      //     uint256 _chainIdFrom,
      //     address _receiver,
      //     uint256 _amount,
      //     uint256 _nonce,
      //     bytes memory _signatures,
      //     address _fallbackAddress,
      //     uint256 _executionFee,
      //     bytes memory _data,
      //     uint8 _reservedFlag,
      //     bytes memory _nativeSender
      // )

      await this.bridge.autoClaim(
        this.wethBridgeId,
        chainIdFrom,
        receiver,
        amount,
        nonce,
        [],
        reserveAddress,
        claimFee,
        data,
        zeroFlag,
        nativeSender,
        {
          from: alice,
        }
      );
      const newBalance = toBN(await this.weth.balanceOf(receiver));
      const submissionId = await this.bridge.getAutoSubmissionIdFrom(
        nativeSender,
        this.wethBridgeId,
        chainIdFrom,
        amount,
        receiver,
        nonce,
        reserveAddress,
        claimFee,
        data,
        zeroFlag
      );
      const isSubmissionUsed = await this.bridge.isSubmissionUsed(submissionId);
      const newBridgeFeeInfo = await this.bridge.getBridgeFeeInfo(this.wethBridgeId);
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
      await this.bridge.autoClaim(
        erc20BridgeId,
        chainIdFrom,
        receiver,
        amount,
        nonce,
        [],
        reserveAddress,
        claimFee,
        data,
        zeroFlag,
        nativeSender,
        {
          from: alice,
        }
      );
      const newBalance = toBN(await this.mockToken.balanceOf(receiver));
      const submissionId = await this.bridge.getAutoSubmissionIdFrom(
        nativeSender,
        erc20BridgeId,
        chainIdFrom,
        amount,
        receiver,
        nonce,
        reserveAddress,
        claimFee,
        data,
        zeroFlag
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
      const nonce = 1;
      await expectRevert(
        this.bridge.autoClaim(
          this.wethBridgeId,
          chainIdFrom,
          receiver,
          amount,
          nonce,
          [],
          reserveAddress,
          claimFee,
          data,
          zeroFlag,
          nativeSender,
          {
            from: alice,
          }
        ),
        "SubmissionNotConfirmed()"
      );
    });

    // it("should reject claiming the token from outside chain", async function () {
    //   await expectRevert(
    //     this.bridge.autoClaim(
    //       outsideBridgeId,
    //       chainIdFrom,
    //       receiver,
    //       amount,
    //       nonce,
    //       [],
    //       reserveAddress,
    //       claimFee,
    //       data,
    //       nativeSender,
    //       zeroFlag,
    //       {
    //         from: alice,
    //       }
    //     ),
    //     "SubmissionNotConfirmed()"
    //   );
    // });

    it("should reject claiming twice", async function () {
      await expectRevert(
        this.bridge.autoClaim(
          this.wethBridgeId,
          chainIdFrom,
          receiver,
          amount,
          nonce,
          [],
          reserveAddress,
          claimFee,
          data,
          zeroFlag,
          nativeSender,
          {
            from: alice,
          }
        ),
        "SubmissionUsed()"
      );
    });
  });
});
