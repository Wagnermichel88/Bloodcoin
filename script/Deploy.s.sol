// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MortalityEmission} from "../src/MortalityEmission.sol";
import {CreMortalityOracle} from "../src/CreMortalityOracle.sol";
import {BcusStaking} from "../src/BcusStaking.sol";

interface VmScript {
    function envAddress(string calldata) external view returns (address);
    function envUint(string calldata) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// Deployt Oracle (CRE-Empfänger), Staking, Emission und Token und verbindet sie. Neue BCUS gehen ans Staking. Beispiel siehe README.md.
contract Deploy {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));
    bool public IS_SCRIPT = true;

    function run() external returns (address oracle, address staking, address emission, address token) {
        address forwarder = vm.envAddress("CRE_FORWARDER");
        address holder = vm.envAddress("INITIAL_HOLDER");
        uint256 initialMint = vm.envUint("INITIAL_MINT_BCUS") * 1e18;

        vm.startBroadcast();
        CreMortalityOracle o = new CreMortalityOracle(forwarder);
        BcusStaking st = new BcusStaking();
        MortalityEmission e = new MortalityEmission(address(o), address(st), address(0), holder, initialMint);
        o.bind(address(e));
        st.bind(address(e));
        vm.stopBroadcast();
        return (address(o), address(st), address(e), address(e.token()));
    }
}
