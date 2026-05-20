// SPDX-License-Identifier: MIT
// Aggregated interfaces inlined from LayerZero-v2 (protocol + oapp packages).
pragma solidity ^0.8.20;

// ------------------------ Messaging structs ------------------------

struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct SetConfigParam {
    uint32 eid;
    uint32 configType;
    bytes config;
}

struct EnforcedOptionParam {
    uint32 eid;
    uint16 msgType;
    bytes options;
}

// ULN config types passed to ILayerZeroEndpointV2.setConfig.
// configType values: 1 = ExecutorConfig (send side), 2 = UlnConfig (send/recv).

struct UlnConfig {
    uint64 confirmations;
    uint8  requiredDVNCount;
    uint8  optionalDVNCount;
    uint8  optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

struct ExecutorConfig {
    uint32 maxMessageSize;
    address executor;
}

// ------------------------ Endpoint sub-interfaces ------------------------

interface IMessageLibManager {
    struct Timeout {
        address lib;
        uint256 expiry;
    }

    event LibraryRegistered(address newLib);
    event DefaultSendLibrarySet(uint32 eid, address newLib);
    event DefaultReceiveLibrarySet(uint32 eid, address newLib);
    event DefaultReceiveLibraryTimeoutSet(uint32 eid, address oldLib, uint256 expiry);
    event SendLibrarySet(address sender, uint32 eid, address newLib);
    event ReceiveLibrarySet(address receiver, uint32 eid, address newLib);
    event ReceiveLibraryTimeoutSet(address receiver, uint32 eid, address oldLib, uint256 timeout);

    function registerLibrary(address _lib) external;
    function isRegisteredLibrary(address _lib) external view returns (bool);
    function getRegisteredLibraries() external view returns (address[] memory);
    function setDefaultSendLibrary(uint32 _eid, address _newLib) external;
    function defaultSendLibrary(uint32 _eid) external view returns (address);
    function setDefaultReceiveLibrary(uint32 _eid, address _newLib, uint256 _timeout) external;
    function defaultReceiveLibrary(uint32 _eid) external view returns (address);
    function setDefaultReceiveLibraryTimeout(uint32 _eid, address _lib, uint256 _expiry) external;
    function defaultReceiveLibraryTimeout(uint32 _eid) external view returns (address lib, uint256 expiry);
    function isSupportedEid(uint32 _eid) external view returns (bool);
    function isValidReceiveLibrary(address _receiver, uint32 _eid, address _lib) external view returns (bool);

    function setSendLibrary(address _oapp, uint32 _eid, address _newLib) external;
    function getSendLibrary(address _sender, uint32 _eid) external view returns (address lib);
    function isDefaultSendLibrary(address _sender, uint32 _eid) external view returns (bool);
    function setReceiveLibrary(address _oapp, uint32 _eid, address _newLib, uint256 _gracePeriod) external;
    function getReceiveLibrary(address _receiver, uint32 _eid) external view returns (address lib, bool isDefault);
    function setReceiveLibraryTimeout(address _oapp, uint32 _eid, address _lib, uint256 _gracePeriod) external;
    function receiveLibraryTimeout(address _receiver, uint32 _eid) external view returns (address lib, uint256 expiry);
    function setConfig(address _oapp, address _lib, SetConfigParam[] calldata _params) external;
    function getConfig(
        address _oapp,
        address _lib,
        uint32 _eid,
        uint32 _configType
    ) external view returns (bytes memory config);
}

interface IMessagingChannel {
    event InboundNonceSkipped(uint32 srcEid, bytes32 sender, address receiver, uint64 nonce);
    event PacketNilified(uint32 srcEid, bytes32 sender, address receiver, uint64 nonce, bytes32 payloadHash);
    event PacketBurnt(uint32 srcEid, bytes32 sender, address receiver, uint64 nonce, bytes32 payloadHash);

    function eid() external view returns (uint32);
    function skip(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce) external;
    function nilify(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce, bytes32 _payloadHash) external;
    function burn(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce, bytes32 _payloadHash) external;
    function nextGuid(address _sender, uint32 _dstEid, bytes32 _receiver) external view returns (bytes32);
    function inboundNonce(address _receiver, uint32 _srcEid, bytes32 _sender) external view returns (uint64);
    function outboundNonce(address _sender, uint32 _dstEid, bytes32 _receiver) external view returns (uint64);
    function inboundPayloadHash(address _receiver, uint32 _srcEid, bytes32 _sender, uint64 _nonce) external view returns (bytes32);
    function lazyInboundNonce(address _receiver, uint32 _srcEid, bytes32 _sender) external view returns (uint64);
}

interface IMessagingComposer {
    event ComposeSent(address from, address to, bytes32 guid, uint16 index, bytes message);
    event ComposeDelivered(address from, address to, bytes32 guid, uint16 index);
    event LzComposeAlert(
        address indexed from,
        address indexed to,
        address indexed executor,
        bytes32 guid,
        uint16 index,
        uint256 gas,
        uint256 value,
        bytes message,
        bytes extraData,
        bytes reason
    );

    function composeQueue(address _from, address _to, bytes32 _guid, uint16 _index) external view returns (bytes32 messageHash);
    function sendCompose(address _to, bytes32 _guid, uint16 _index, bytes calldata _message) external;
    function lzCompose(
        address _from,
        address _to,
        bytes32 _guid,
        uint16 _index,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;
}

interface IMessagingContext {
    function isSendingMessage() external view returns (bool);
    function getSendContext() external view returns (uint32 dstEid, address sender);
}

// ------------------------ Endpoint ------------------------

interface ILayerZeroEndpointV2 is IMessageLibManager, IMessagingComposer, IMessagingChannel, IMessagingContext {
    event PacketSent(bytes encodedPayload, bytes options, address sendLibrary);
    event PacketVerified(Origin origin, address receiver, bytes32 payloadHash);
    event PacketDelivered(Origin origin, address receiver);
    event LzReceiveAlert(
        address indexed receiver,
        address indexed executor,
        Origin origin,
        bytes32 guid,
        uint256 gas,
        uint256 value,
        bytes message,
        bytes extraData,
        bytes reason
    );
    event LzTokenSet(address token);
    event DelegateSet(address sender, address delegate);

    function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory);
    function send(MessagingParams calldata _params, address _refundAddress) external payable returns (MessagingReceipt memory);
    function verify(Origin calldata _origin, address _receiver, bytes32 _payloadHash) external;
    function verifiable(Origin calldata _origin, address _receiver) external view returns (bool);
    function initializable(Origin calldata _origin, address _receiver) external view returns (bool);
    function lzReceive(
        Origin calldata _origin,
        address _receiver,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;
    function clear(address _oapp, Origin calldata _origin, bytes32 _guid, bytes calldata _message) external;
    function setLzToken(address _lzToken) external;
    function lzToken() external view returns (address);
    function nativeToken() external view returns (address);
    function setDelegate(address _delegate) external;
}

// ------------------------ OApp interfaces ------------------------

interface ILayerZeroReceiver {
    function allowInitializePath(Origin calldata _origin) external view returns (bool);
    function nextNonce(uint32 _eid, bytes32 _sender) external view returns (uint64);
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

interface IOAppCore {
    error OnlyPeer(uint32 eid, bytes32 sender);
    error NoPeer(uint32 eid);
    error InvalidEndpointCall();
    error InvalidDelegate();

    event PeerSet(uint32 eid, bytes32 peer);

    function oAppVersion() external view returns (uint64 senderVersion, uint64 receiverVersion);
    function endpoint() external view returns (ILayerZeroEndpointV2 iEndpoint);
    function peers(uint32 _eid) external view returns (bytes32 peer);
    function setPeer(uint32 _eid, bytes32 _peer) external;
    function setDelegate(address _delegate) external;
}

interface IOAppReceiver is ILayerZeroReceiver {
    function isComposeMsgSender(
        Origin calldata _origin,
        bytes calldata _message,
        address _sender
    ) external view returns (bool isSender);
}

interface IOAppOptionsType3 {
    error InvalidOptions(bytes options);
    event EnforcedOptionSet(EnforcedOptionParam[] _enforcedOptions);

    function setEnforcedOptions(EnforcedOptionParam[] calldata _enforcedOptions) external;
    function combineOptions(
        uint32 _eid,
        uint16 _msgType,
        bytes calldata _extraOptions
    ) external view returns (bytes memory options);
}
