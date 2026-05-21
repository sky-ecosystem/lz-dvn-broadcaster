// SPDX-License-Identifier: AGPL-3.0-or-later
// Sourced from https://metadata.layerzero-api.com/v1/metadata (LayerZero v2 deployments)
pragma solidity ^0.8.24;

library Addresses {
    struct LZ {
        uint32  eid;
        address endpoint;
        address sendUln302;
        address receiveUln302;
        address executor;
        address[7] dvns;        // not pre-sorted; sortDVNs() before passing to UlnConfig
        address ccipRouter;     // Chainlink CCIP router
        uint64  ccipChainSelector;
    }

    function ethereum() internal pure returns (LZ memory c) {
        c.eid           = 30101;
        c.endpoint      = 0x1a44076050125825900e736c501f859c50fE728c;
        c.sendUln302    = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
        c.receiveUln302 = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
        c.executor      = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
        c.dvns[0] = 0x06559EE34D85a88317Bf0bfE307444116c631b67; // P2P
        c.dvns[1] = 0x373a6E5c0C4E89E24819f00AA37ea370917AAfF4; // Deutsche Telekom
        c.dvns[2] = 0x380275805876Ff19055EA900CDb2B46a94ecF20D; // Horizen
        c.dvns[3] = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b; // LayerZero Labs
        c.dvns[4] = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd; // Canary
        c.dvns[5] = 0x58249a2Ec05c1978bF21DF1f5eC1847e42455CF4; // Luganodes
        c.dvns[6] = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5; // Nethermind
        c.ccipRouter        = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
        c.ccipChainSelector = 5009297550715157269;
    }

    function base() internal pure returns (LZ memory c) {
        c.eid           = 30184;
        c.endpoint      = 0x1a44076050125825900e736c501f859c50fE728c;
        c.sendUln302    = 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2;
        c.receiveUln302 = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;
        c.executor      = 0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4;
        c.dvns[0] = 0x5b6735c66d97479cCD18294fc96B3084EcB2fa3f; // P2P
        c.dvns[1] = 0xcd37CA043f8479064e10635020c65FfC005d36f6; // Nethermind
        c.dvns[2] = 0x554833698Ae0FB22ECC90B01222903fD62CA4B47; // Canary
        c.dvns[3] = 0xa7b5189bcA84Cd304D8553977c7C614329750d99; // Horizen
        c.dvns[4] = 0xa0AF56164F02bDf9d75287ee77c568889F11d5f2; // Luganodes
        c.dvns[5] = 0xc2A0C36f5939A14966705c7Cec813163FaEEa1F0; // Deutsche Telekom
        c.dvns[6] = 0x9e059a54699a285714207b43B055483E78FAac25; // LayerZero Labs
        c.ccipRouter        = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
        c.ccipChainSelector = 15971525489660198786;
    }

    /// @notice Sort a fixed-size DVN list ascending by address (UlnConfig requires sorted optional DVNs).
    function sortDVNs(address[7] memory arr) internal pure returns (address[7] memory) {
        for (uint256 i = 1; i < 7; ++i) {
            address k = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > k) {
                arr[j] = arr[j - 1];
                unchecked { --j; }
            }
            arr[j] = k;
        }
        return arr;
    }
}
