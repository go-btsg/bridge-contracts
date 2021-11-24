// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "../interfaces/IAggregatorBase.sol";

contract AggregatorBase is Initializable, AccessControlUpgradeable, IAggregatorBase {
    /* ========== STATE VARIABLES ========== */

    uint8 public minConfirmations; // minimal required confirmations
    uint8 public requiredOraclesCount; // count of required oracles

    address[] public oracleAddresses;
    mapping(address => OracleInfo) public getOracleInfo; // oracle address => oracle details

    /* ========== ERRORS ========== */

    error AdminBadRole();
    error OracleBadRole();
    error BridgeGateBadRole();

    error OraclesAdminAccessDenied();

    error OracleAlreadyExist();
    error OracleNotFound();

    error IncorrectParams();

    error SubmittedAlready();

    error DeployNotConfirmed();
    error DeployNotFound();
    error DeployedAlready();

    /* ========== MODIFIERS ========== */

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AdminBadRole();
        _;
    }
    modifier onlyOracle() {
        if (!getOracleInfo[msg.sender].isValid) revert OracleBadRole();
        _;
    }

    /* ========== CONSTRUCTOR  ========== */

    /// @dev Constructor that initializes the most important configurations.
    /// @param _minConfirmations Common confirmations count.
    function initializeBase(uint8 _minConfirmations) internal {
        minConfirmations = _minConfirmations;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ========== ORACLES  ========== */

    /// @dev Updates oracle's admin address.
    /// @param _oracle Oracle address.
    /// @param _newOracleAdmin New oracle address.
    function updateOracleAdmin(address _oracle, address _newOracleAdmin) external {
        if (getOracleInfo[_oracle].admin != msg.sender) revert OraclesAdminAccessDenied();
        getOracleInfo[_oracle].admin = _newOracleAdmin;
        emit UpdateOracleAdmin(_oracle, _newOracleAdmin);
    }

    /* ========== ADMIN ========== */

    /// @dev Sets minimal required confirmations.
    /// @param _minConfirmations Confirmation info.
    function setMinConfirmations(uint8 _minConfirmations) external onlyAdmin {
        if (_minConfirmations == 0) revert IncorrectParams();
        minConfirmations = _minConfirmations;
    }

    /// @dev Add oracle.
    /// @param _oracles Oracles addresses.
    /// @param _admins Oracles admin addresses.
    /// @param _required Without this oracle, the transfer will not be confirmed
    function addOracles(
        address[] memory _oracles,
        address[] memory _admins,
        bool[] memory _required
    ) external onlyAdmin {
        for (uint256 i = 0; i < _oracles.length; i++) {
            OracleInfo storage oracleInfo = getOracleInfo[_oracles[i]];
            if (oracleInfo.exist) revert OracleAlreadyExist();

            oracleAddresses.push(_oracles[i]);

            if (_required[i]) {
                requiredOraclesCount += 1;
            }

            oracleInfo.exist = true;
            oracleInfo.isValid = true;
            oracleInfo.required = _required[i];
            oracleInfo.admin = _admins[i];

            emit AddOracle(_oracles[i], _admins[i], _required[i]);
        }
    }

    /// @dev Update oracle.
    /// @param _oracle Oracle address.
    /// @param _isValid is valid oracle
    /// @param _required Without this oracle, the transfer will not be confirmed
    function updateOracle(
        address _oracle,
        bool _isValid,
        bool _required
    ) external onlyAdmin {
        //If oracle is invalid, it must be not required
        if (!_isValid && _required) revert IncorrectParams();

        OracleInfo storage oracleInfo = getOracleInfo[_oracle];
        if (!oracleInfo.exist) revert OracleNotFound();

        oracleInfo.isValid = _isValid;

        if (oracleInfo.required && !_required) {
            requiredOraclesCount -= 1;
        } else if (!oracleInfo.required && _required) {
            requiredOraclesCount += 1;
        }
        oracleInfo.required = _required;
        emit UpdateOracle(_oracle, _required, _isValid);
    }

    /// @dev Update oracle admin.
    /// @param _oracle Oracle address.
    /// @param _admin new admin address.
    function updateOracleAdminByOwner(address _oracle, address _admin) external onlyAdmin {
        OracleInfo storage oracleInfo = getOracleInfo[_oracle];
        if (!oracleInfo.exist) revert OracleNotFound();
        oracleInfo.admin = _admin;
        emit UpdateOracleAdminByOwner(_oracle, _admin);
    }

    /* ========== VIEW ========== */

    /// @dev Calculates asset identifier.
    function getDeployId(
        bytes32 _bridgeId,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_bridgeId, _name, _symbol, _decimals));
    }

    /// @dev Calculates asset identifier.
    /// @param _chainId Current chain id.
    /// @param _tokenAddress Address of the asset on the other chain.
    function getBridgeId(uint256 _chainId, bytes memory _tokenAddress)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_chainId, _tokenAddress));
    }
}
