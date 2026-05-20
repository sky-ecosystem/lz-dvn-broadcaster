// SPDX-License-Identifier: LZBL-1.2
// Consolidated source: CCIPDVNAdapter and all single-use dependencies.
//
// LZ pieces (inlined verbatim from LayerZero-v2 messagelib + protocol):
//   AddressCast, Transfer, IMessageLib, ISendLib, IWorker, ILayerZeroDVN,
//   IAny2EVMMessageReceiver, DVNAdapterMessageCodec, Worker, DVNAdapterBase.
//   Worker's `_grantRole`/`_revokeRole` overrides updated for OZ v5 (return bool).
//
// OZ pieces used only here (inlined from OZ v5.x):
//   IERC165, ERC165, IAccessControl, AccessControl, Pausable.
//
// Files still split (shared by other contracts in this repo):
//   OZ.sol (Context, Ownable, IERC20, SafeERC20)
//   Client.sol, IRouterClient.sol, ICCIPDVNAdapter.sol, ICCIPDVNAdapterFeeLib.sol
//   LZInterfaces.sol (shared LZ structs)
pragma solidity ^0.8.20;

import { Context, IERC20, SafeERC20 } from "./OZ.sol";
import { Client } from "./Client.sol";
import { IRouterClient } from "./IRouterClient.sol";
import { ICCIPDVNAdapter } from "./ICCIPDVNAdapter.sol";
import { ICCIPDVNAdapterFeeLib } from "./ICCIPDVNAdapterFeeLib.sol";
import { SetConfigParam, MessagingFee } from "./LZInterfaces.sol";

// ==========================================================================
// IERC165 / ERC165 (OZ v5.4.0)
// ==========================================================================
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

abstract contract ERC165 is IERC165 {
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// ==========================================================================
// Pausable (OZ v5.3.0), verbatim
// ==========================================================================
abstract contract Pausable is Context {
    bool private _paused;

    event Paused(address account);
    event Unpaused(address account);

    error EnforcedPause();
    error ExpectedPause();

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    modifier whenPaused() {
        _requirePaused();
        _;
    }

    function paused() public view virtual returns (bool) {
        return _paused;
    }

    function _requireNotPaused() internal view virtual {
        if (paused()) revert EnforcedPause();
    }

    function _requirePaused() internal view virtual {
        if (!paused()) revert ExpectedPause();
    }

    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}

// ==========================================================================
// IAccessControl / AccessControl (OZ v5.6.0)
// ==========================================================================
interface IAccessControl {
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error AccessControlBadConfirmation();

    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role].hasRole[account];
    }

    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
        return _roles[role].adminRole;
    }

    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }
        _revokeRole(role, callerConfirmation);
    }

    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (hasRole(role, account)) {
            _roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }
}

// ==========================================================================
// AddressCast (LZ)
// ==========================================================================
library AddressCast {
    error AddressCast_InvalidSizeForAddress();
    error AddressCast_InvalidAddress();

    function toBytes32(bytes calldata _addressBytes) internal pure returns (bytes32 result) {
        if (_addressBytes.length > 32) revert AddressCast_InvalidAddress();
        result = bytes32(_addressBytes);
        unchecked {
            uint256 offset = 32 - _addressBytes.length;
            result = result >> (offset * 8);
        }
    }

    function toBytes32(address _address) internal pure returns (bytes32 result) {
        result = bytes32(uint256(uint160(_address)));
    }

    function toBytes(bytes32 _addressBytes32, uint256 _size) internal pure returns (bytes memory result) {
        if (_size == 0 || _size > 32) revert AddressCast_InvalidSizeForAddress();
        result = new bytes(_size);
        unchecked {
            uint256 offset = 256 - _size * 8;
            assembly {
                mstore(add(result, 32), shl(offset, _addressBytes32))
            }
        }
    }

    function toAddress(bytes32 _addressBytes32) internal pure returns (address result) {
        result = address(uint160(uint256(_addressBytes32)));
    }

    function toAddress(bytes calldata _addressBytes) internal pure returns (address result) {
        if (_addressBytes.length != 20) revert AddressCast_InvalidAddress();
        result = address(bytes20(_addressBytes));
    }
}

// ==========================================================================
// Transfer (LZ)
// ==========================================================================
library Transfer {
    using SafeERC20 for IERC20;

    address internal constant ADDRESS_ZERO = address(0);

    error Transfer_NativeFailed(address _to, uint256 _value);
    error Transfer_ToAddressIsZero();

    function native(address _to, uint256 _value) internal {
        if (_to == ADDRESS_ZERO) revert Transfer_ToAddressIsZero();
        (bool success, ) = _to.call{ value: _value }("");
        if (!success) revert Transfer_NativeFailed(_to, _value);
    }

    function token(address _token, address _to, uint256 _value) internal {
        if (_to == ADDRESS_ZERO) revert Transfer_ToAddressIsZero();
        IERC20(_token).safeTransfer(_to, _value);
    }

    function nativeOrToken(address _token, address _to, uint256 _value) internal {
        if (_token == ADDRESS_ZERO) native(_to, _value);
        else token(_token, _to, _value);
    }
}

// ==========================================================================
// IMessageLib / ISendLib (LZ)
// ==========================================================================
enum MessageLibType {
    Send,
    Receive,
    SendAndReceive
}

interface IMessageLib is IERC165 {
    function setConfig(address _oapp, SetConfigParam[] calldata _config) external;
    function getConfig(uint32 _eid, address _oapp, uint32 _configType) external view returns (bytes memory config);
    function isSupportedEid(uint32 _eid) external view returns (bool);
    function version() external view returns (uint64 major, uint8 minor, uint8 endpointVersion);
    function messageLibType() external view returns (MessageLibType);
}

struct Packet {
    uint64 nonce;
    uint32 srcEid;
    address sender;
    uint32 dstEid;
    bytes32 receiver;
    bytes32 guid;
    bytes message;
}

interface ISendLib is IMessageLib {
    function send(
        Packet calldata _packet,
        bytes calldata _options,
        bool _payInLzToken
    ) external returns (MessagingFee memory, bytes memory encodedPacket);

    function quote(
        Packet calldata _packet,
        bytes calldata _options,
        bool _payInLzToken
    ) external view returns (MessagingFee memory);

    function setTreasury(address _treasury) external;
    function withdrawFee(address _to, uint256 _amount) external;
    function withdrawLzTokenFee(address _lzToken, address _to, uint256 _amount) external;
}

// ==========================================================================
// IWorker (LZ)
// ==========================================================================
interface IWorker {
    event SetWorkerLib(address workerLib);
    event SetPriceFeed(address priceFeed);
    event SetDefaultMultiplierBps(uint16 multiplierBps);
    event SetSupportedOptionTypes(uint32 dstEid, uint8[] optionTypes);
    event Withdraw(address lib, address to, uint256 amount);

    error Worker_NotAllowed();
    error Worker_OnlyMessageLib();
    error Worker_RoleRenouncingDisabled();

    function setPriceFeed(address _priceFeed) external;
    function priceFeed() external view returns (address);
    function setDefaultMultiplierBps(uint16 _multiplierBps) external;
    function defaultMultiplierBps() external view returns (uint16);
    function withdrawFee(address _lib, address _to, uint256 _amount) external;
    function setSupportedOptionTypes(uint32 _eid, uint8[] calldata _optionTypes) external;
    function getSupportedOptionTypes(uint32 _eid) external view returns (uint8[] memory);
}

// ==========================================================================
// ILayerZeroDVN (LZ)
// ==========================================================================
interface ILayerZeroDVN {
    struct AssignJobParam {
        uint32 dstEid;
        bytes packetHeader;
        bytes32 payloadHash;
        uint64 confirmations;
        address sender;
    }

    function assignJob(AssignJobParam calldata _param, bytes calldata _options) external payable returns (uint256 fee);

    function getFee(
        uint32 _dstEid,
        uint64 _confirmations,
        address _sender,
        bytes calldata _options
    ) external view returns (uint256 fee);
}

// ==========================================================================
// IAny2EVMMessageReceiver (Chainlink CCIP @ 0.7.6)
// ==========================================================================
interface IAny2EVMMessageReceiver {
    function ccipReceive(Client.Any2EVMMessage calldata message) external;
}

// ==========================================================================
// DVNAdapterMessageCodec (LZ)
// ==========================================================================
library DVNAdapterMessageCodec {
    using AddressCast for bytes32;

    error DVNAdapter_InvalidMessageSize();

    uint256 private constant RECEIVE_LIB_OFFSET   = 0;
    uint256 private constant PAYLOAD_HASH_OFFSET  = 32;
    uint256 private constant PACKET_HEADER_OFFSET = 64;
    uint256 private constant SRC_EID_OFFSET       = 73;

    uint256 internal constant PACKET_HEADER_SIZE = 81;
    uint256 internal constant MESSAGE_SIZE       = 32 + 32 + PACKET_HEADER_SIZE;

    function encode(
        bytes32 _receiveLib,
        bytes memory _packetHeader,
        bytes32 _payloadHash
    ) internal pure returns (bytes memory payload) {
        return abi.encodePacked(_receiveLib, _payloadHash, _packetHeader);
    }

    function decode(
        bytes calldata _message
    ) internal pure returns (address receiveLib, bytes memory packetHeader, bytes32 payloadHash) {
        if (_message.length != MESSAGE_SIZE) revert DVNAdapter_InvalidMessageSize();
        receiveLib   = bytes32(_message[RECEIVE_LIB_OFFSET:PAYLOAD_HASH_OFFSET]).toAddress();
        payloadHash  = bytes32(_message[PAYLOAD_HASH_OFFSET:PACKET_HEADER_OFFSET]);
        packetHeader = _message[PACKET_HEADER_OFFSET:];
    }

    function srcEid(bytes calldata _message) internal pure returns (uint32) {
        return uint32(bytes4(_message[SRC_EID_OFFSET:SRC_EID_OFFSET + 4]));
    }
}

// ==========================================================================
// Worker (LZ)
// ==========================================================================
abstract contract Worker is AccessControl, Pausable, IWorker {
    bytes32 internal constant MESSAGE_LIB_ROLE = keccak256("MESSAGE_LIB_ROLE");
    bytes32 internal constant ALLOWLIST        = keccak256("ALLOWLIST");
    bytes32 internal constant DENYLIST         = keccak256("DENYLIST");
    bytes32 internal constant ADMIN_ROLE       = keccak256("ADMIN_ROLE");

    address public workerFeeLib;

    uint64 public allowlistSize;
    uint16 public defaultMultiplierBps;
    address public priceFeed;

    mapping(uint32 eid => uint8[] optionTypes) internal supportedOptionTypes;

    constructor(
        address[] memory _messageLibs,
        address _priceFeed,
        uint16 _defaultMultiplierBps,
        address _roleAdmin,
        address[] memory _admins
    ) {
        defaultMultiplierBps = _defaultMultiplierBps;
        priceFeed = _priceFeed;

        if (_roleAdmin != address(0x0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, _roleAdmin);
        }

        for (uint256 i = 0; i < _messageLibs.length; ++i) {
            _grantRole(MESSAGE_LIB_ROLE, _messageLibs[i]);
        }

        for (uint256 i = 0; i < _admins.length; ++i) {
            _grantRole(ADMIN_ROLE, _admins[i]);
        }
    }

    modifier onlyAcl(address _sender) {
        if (!hasAcl(_sender)) revert Worker_NotAllowed();
        _;
    }

    function hasAcl(address _sender) public view returns (bool) {
        if (hasRole(DENYLIST, _sender)) return false;
        if (allowlistSize == 0 || hasRole(ALLOWLIST, _sender)) return true;
        return false;
    }

    function setPaused(bool _paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_paused) _pause();
        else _unpause();
    }

    function setPriceFeed(address _priceFeed) external onlyRole(ADMIN_ROLE) {
        priceFeed = _priceFeed;
        emit SetPriceFeed(_priceFeed);
    }

    function setWorkerFeeLib(address _workerFeeLib) external onlyRole(ADMIN_ROLE) {
        workerFeeLib = _workerFeeLib;
        emit SetWorkerLib(_workerFeeLib);
    }

    function setDefaultMultiplierBps(uint16 _multiplierBps) external onlyRole(ADMIN_ROLE) {
        defaultMultiplierBps = _multiplierBps;
        emit SetDefaultMultiplierBps(_multiplierBps);
    }

    function withdrawFee(address _lib, address _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        if (!hasRole(MESSAGE_LIB_ROLE, _lib)) revert Worker_OnlyMessageLib();
        ISendLib(_lib).withdrawFee(_to, _amount);
        emit Withdraw(_lib, _to, _amount);
    }

    function withdrawToken(address _token, address _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        Transfer.nativeOrToken(_token, _to, _amount);
    }

    function setSupportedOptionTypes(uint32 _eid, uint8[] calldata _optionTypes) external onlyRole(ADMIN_ROLE) {
        supportedOptionTypes[_eid] = _optionTypes;
    }

    function getSupportedOptionTypes(uint32 _eid) external view returns (uint8[] memory) {
        return supportedOptionTypes[_eid];
    }

    /// @dev v5 AccessControl returns bool from these
    function _grantRole(bytes32 _role, address _account) internal override returns (bool) {
        if (_role == ALLOWLIST && !hasRole(_role, _account)) {
            ++allowlistSize;
        }
        return super._grantRole(_role, _account);
    }

    function _revokeRole(bytes32 _role, address _account) internal override returns (bool) {
        if (_role == ALLOWLIST && hasRole(_role, _account)) {
            --allowlistSize;
        }
        return super._revokeRole(_role, _account);
    }

    function renounceRole(bytes32 /*role*/, address /*account*/) public pure override {
        revert Worker_RoleRenouncingDisabled();
    }
}

// ==========================================================================
// DVNAdapterBase (LZ)
// ==========================================================================
interface ISendLibBase {
    function fees(address _worker) external view returns (uint256);
}

interface IReceiveUln {
    function verify(bytes calldata _packetHeader, bytes32 _payloadHash, uint64 _confirmations) external;
}

struct ReceiveLibParam {
    address sendLib;
    uint32 dstEid;
    bytes32 receiveLib;
}

abstract contract DVNAdapterBase is Worker, ILayerZeroDVN {
    error DVNAdapter_InsufficientBalance(uint256 actual, uint256 requested);
    error DVNAdapter_NotImplemented();
    error DVNAdapter_MissingRecieveLib(address sendLib, uint32 dstEid);

    event ReceiveLibsSet(ReceiveLibParam[] params);

    uint64 internal constant MAX_CONFIRMATIONS = type(uint64).max;

    mapping(address sendLib => mapping(uint32 dstEid => bytes32 receiveLib)) public receiveLibs;

    constructor(
        address _roleAdmin,
        address[] memory _admins,
        uint16 _defaultMultiplierBps
    ) Worker(new address[](0), address(0x0), _defaultMultiplierBps, _roleAdmin, _admins) {}

    function setReceiveLibs(ReceiveLibParam[] calldata _params) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _params.length; i++) {
            ReceiveLibParam calldata param = _params[i];
            receiveLibs[param.sendLib][param.dstEid] = param.receiveLib;
        }
        emit ReceiveLibsSet(_params);
    }

    function _getAndAssertReceiveLib(address _sendLib, uint32 _dstEid) internal view returns (bytes32 lib) {
        lib = receiveLibs[_sendLib][_dstEid];
        if (lib == bytes32(0)) revert DVNAdapter_MissingRecieveLib(_sendLib, _dstEid);
    }

    function _encode(
        bytes32 _receiveLib,
        bytes memory _packetHeader,
        bytes32 _payloadHash
    ) internal pure returns (bytes memory) {
        return DVNAdapterMessageCodec.encode(_receiveLib, _packetHeader, _payloadHash);
    }

    function _encodeEmpty() internal pure returns (bytes memory) {
        return DVNAdapterMessageCodec.encode(bytes32(0), new bytes(DVNAdapterMessageCodec.PACKET_HEADER_SIZE), bytes32(0));
    }

    function _decodeAndVerify(uint32 _srcEid, bytes calldata _payload) internal {
        require((DVNAdapterMessageCodec.srcEid(_payload) % 30000) == _srcEid, "DVNAdapterBase: invalid srcEid");
        (address receiveLib, bytes memory packetHeader, bytes32 payloadHash) = DVNAdapterMessageCodec.decode(_payload);
        IReceiveUln(receiveLib).verify(packetHeader, payloadHash, MAX_CONFIRMATIONS);
    }

    function _withdrawFeeFromSendLib(address _sendLib, address _to) internal {
        uint256 fee = ISendLibBase(_sendLib).fees(address(this));
        if (fee > 0) {
            ISendLib(_sendLib).withdrawFee(_to, fee);
            emit Withdraw(_sendLib, _to, fee);
        }
    }

    function _assertBalanceAndWithdrawFee(address _sendLib, uint256 _messageFee) internal {
        uint256 balance = address(this).balance;
        if (balance < _messageFee) {
            _withdrawFeeFromSendLib(_sendLib, address(this));
            balance = address(this).balance;
            if (balance < _messageFee) revert DVNAdapter_InsufficientBalance(balance, _messageFee);
        }
    }

    receive() external payable {}
}

// ==========================================================================
// CCIPDVNAdapter (LZ)
// ==========================================================================
contract CCIPDVNAdapter is DVNAdapterBase, IAny2EVMMessageReceiver, ICCIPDVNAdapter {
    address private constant NATIVE_GAS_TOKEN_ADDRESS = address(0);

    IRouterClient public immutable router;

    mapping(uint32 dstEid => DstConfig) public dstConfig;
    mapping(uint64 srcChainSelector => SrcConfig) public srcConfig;

    constructor(address[] memory _admins, address _router) DVNAdapterBase(msg.sender, _admins, 12000) {
        router = IRouterClient(_router);
    }

    function setDstConfig(DstConfigParam[] calldata _params) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < _params.length; i++) {
            DstConfigParam calldata param = _params[i];
            uint32 eid = param.eid % 30000;

            if (dstConfig[eid].chainSelector == 0) {
                dstConfig[eid].chainSelector = param.chainSelector;
                dstConfig[eid].peer          = param.peer;
                srcConfig[param.chainSelector].eid  = eid;
                srcConfig[param.chainSelector].peer = param.peer;
            }

            dstConfig[eid].multiplierBps = param.multiplierBps;
            dstConfig[eid].gas           = param.gas;
        }
        emit DstConfigSet(_params);
    }

    function assignJob(
        AssignJobParam calldata _param,
        bytes calldata _options
    ) external payable override onlyAcl(_param.sender) returns (uint256 totalFee) {
        bytes32 receiveLib = _getAndAssertReceiveLib(msg.sender, _param.dstEid);

        ICCIPDVNAdapterFeeLib.Param memory feeLibParam = ICCIPDVNAdapterFeeLib.Param(
            _param.dstEid, _param.confirmations, _param.sender, defaultMultiplierBps
        );
        DstConfig memory config = dstConfig[_param.dstEid % 30000];

        bytes memory data = _encode(receiveLib, _param.packetHeader, _param.payloadHash);
        Client.EVM2AnyMessage memory message = _createCCIPMessage(data, config.peer, config.gas);

        IRouterClient ccipRouter = router;
        uint256 ccipFee;
        (ccipFee, totalFee) = ICCIPDVNAdapterFeeLib(workerFeeLib).getFeeOnSend(
            feeLibParam, config, message, _options, ccipRouter
        );

        _assertBalanceAndWithdrawFee(msg.sender, ccipFee);
        ccipRouter.ccipSend{ value: ccipFee }(config.chainSelector, message);
    }

    function ccipReceive(Client.Any2EVMMessage calldata _message) external {
        if (msg.sender != address(router)) revert CCIPDVNAdapter_InvalidRouter(msg.sender);
        SrcConfig memory config = srcConfig[_message.sourceChainSelector];
        _assertPeer(_message.sourceChainSelector, _message.sender, config.peer);
        _decodeAndVerify(config.eid, _message.data);
    }

    function getFee(
        uint32 _dstEid,
        uint64 _confirmations,
        address _sender,
        bytes calldata _options
    ) external view override onlyAcl(_sender) returns (uint256 totalFee) {
        ICCIPDVNAdapterFeeLib.Param memory feeLibParam = ICCIPDVNAdapterFeeLib.Param(
            _dstEid, _confirmations, _sender, defaultMultiplierBps
        );
        DstConfig memory config = dstConfig[_dstEid % 30000];

        bytes memory data = _encodeEmpty();
        Client.EVM2AnyMessage memory message = _createCCIPMessage(data, config.peer, config.gas);
        totalFee = ICCIPDVNAdapterFeeLib(workerFeeLib).getFee(feeLibParam, config, message, _options, router);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    function _createCCIPMessage(
        bytes memory _data,
        bytes memory _receiver,
        uint256 _gas
    ) private pure returns (Client.EVM2AnyMessage memory message) {
        message = Client.EVM2AnyMessage({
            receiver:     _receiver,
            data:         _data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs:    Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: _gas, strict: false })),
            feeToken:     NATIVE_GAS_TOKEN_ADDRESS
        });
    }

    function _assertPeer(uint64 _sourceChainSelector, bytes memory _sourceAddress, bytes memory peer) private pure {
        if (keccak256(_sourceAddress) != keccak256(peer)) {
            revert CCIPDVNAdapter_UntrustedPeer(_sourceChainSelector, _sourceAddress);
        }
    }
}
