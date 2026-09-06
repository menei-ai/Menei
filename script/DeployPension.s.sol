// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AUM0Pension} from "../src/AUM0Pension.sol";

/// The pension edition on the full venue: USDG plus the same twenty six
/// assets, frozen at deploy forever. Everything the desk edition does, plus
/// laws that age on a schedule carved once.
contract DeployPension is Script {
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 constant N = 26;

    function run() external {
        vm.startBroadcast();
        AUM0Pension aum = _deploy();
        vm.stopBroadcast();
        console2.log("AUM0 pension edition deployed at:", address(aum));
    }

    function deployForTest() external returns (AUM0Pension) {
        return _deploy();
    }

    function _deploy() internal returns (AUM0Pension) {
        address[] memory tokens = new address[](N);
        address[] memory feeds  = new address[](N);
        uint24[]  memory fees   = new uint24[](N);
        uint8[]   memory decs   = new uint8[](N);

        // the fifteen the firm already ran, in the same order, so a wallet's
        // existing weights keep meaning the same thing
        _set(tokens, feeds, fees, 0,  0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15, 500);   // NVDA
        _set(tokens, feeds, fees, 1,  0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb, 500);   // SPCX
        _set(tokens, feeds, fees, 2,  0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 0x4A1166a659A55625345e9515b32adECea5547C38, 3000);  // TSLA
        _set(tokens, feeds, fees, 3,  0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0, 3000);  // AAPL
        _set(tokens, feeds, fees, 4,  0xe93237C50D904957Cf27E7B1133b510C669c2e74, 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E, 3000);  // MSFT
        _set(tokens, feeds, fees, 5,  0x12f190a9F9d7D37a250758b26824B97CE941bF54, 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C, 3000);  // AMZN
        _set(tokens, feeds, fees, 6,  0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596, 3000);  // MU
        _set(tokens, feeds, fees, 7,  0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 0x319724394D3A0e3669269846abE664Cd621f9f6A, 500);   // SPY
        _set(tokens, feeds, fees, 8,  0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c, 3000);  // PLTR
        _set(tokens, feeds, fees, 9,  0xB90A19fF0Af67f7779afF50A882A9CfF42446400, 0xfb133Fa4B7b385802B693a293606682Df47109A3, 10000); // SNDK
        _set(tokens, feeds, fees, 10, 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681, 0x3f390C5C24628Ac7C489515402235FeAD71D1913, 3000);  // INTC
        _set(tokens, feeds, fees, 11, 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72, 3000);  // AMD
        _set(tokens, feeds, fees, 12, 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 0xF6f373a037c30F0e5010d854385cA89185AE638b, 500);   // GOOGL
        _set(tokens, feeds, fees, 13, 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, 0x7C38C00C30BEe9378381E7B6135d7283356D71b1, 3000);  // META
        _set(tokens, feeds, fees, 14, 0xd917B029C761D264c6A312BBbcDA868658eF86a6, 0x451B1295aA84FD6d6b58af1a5002eA1b1A1913A0, 3000);  // USAR

        // and the eleven that were sitting on the chain unused
        _set(tokens, feeds, fees, 15, 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, 0x80901d846d5D7B030F26B480776EE3b29374C2ae, 500);   // QQQ    $1.19M
        _set(tokens, feeds, fees, 16, 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5, 0xa0DF4ee0fFf975306345875E3548Fcc519577A11, 3000);  // SGOV   $217k
        _set(tokens, feeds, fees, 17, 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f, 0x209b73908e92Ae021826eD79609845451Ecba2ce, 3000);  // SLV    $126k
        _set(tokens, feeds, fees, 18, 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344, 0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c, 3000);  // USO    $346k
        _set(tokens, feeds, fees, 19, 0x1b0E319c6A659F002271B69dB8A7df2F911c153E, 0x27C71df6A64fB476468EdF256CF72c038baB5B67, 500);   // GME    $308k
        _set(tokens, feeds, fees, 20, 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5, 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a, 3000);  // CRCL   $649k
        _set(tokens, feeds, fees, 21, 0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd, 0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b, 10000); // DELL   $429k
        _set(tokens, feeds, fees, 22, 0xec262a75e413fAfD0dF80480274532C79D42da09, 0x396118bdFB181e6240E74D243F266B061c0edc3D, 10000); // MSTR   $94k
        _set(tokens, feeds, fees, 23, 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA, 0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F, 10000); // TSM    $47k
        _set(tokens, feeds, fees, 24, 0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4, 0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984, 3000);  // BABA   $39k
        _set(tokens, feeds, fees, 25, 0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA, 0xB4106147E8cce40b7d46124090d373A71b70f87D, 10000); // ASML   $24k

        for (uint256 i; i < N; ++i) decs[i] = 18;
        return new AUM0Pension(ROUTER, USDG, 6, 7 days, tokens, feeds, fees, decs);
    }

    function _set(address[] memory t, address[] memory f, uint24[] memory p, uint256 i, address token, address feed, uint24 fee) internal pure {
        t[i] = token; f[i] = feed; p[i] = fee;
    }
}
