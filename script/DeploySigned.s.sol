// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MortalityEmission} from "../src/MortalityEmission.sol";
import {SignedMortalityOracle} from "../src/SignedMortalityOracle.sol";
import {BcusStaking} from "../src/BcusStaking.sol";
import {FounderLock} from "../src/FounderLock.sol";
import {BcusMining} from "../src/BcusMining.sol";

interface VmScript {
    function envAddress(string calldata) external view returns (address);
    function envUint(string calldata) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// Wie Deploy.s.sol, aber mit dem eigenen signierten Melder statt Chainlink CRE (Plan B).
/// ORACLE_SIGNER ist die Adresse des Server-Schlüssels (oracle/signed/README.md).
/// Die Startmenge (Gründer-BCUS) geht nicht an eine Adresse, sondern in den FounderLock:
/// über 10 Jahre ab Deploy linear frei (100.000 pro Jahr bei 1 Mio.), nur an FOUNDER_BENEFICIARY.
/// Neue BCUS gehen je zur Hälfte an das Mining (jeder kann schürfen) und an das Staking.
contract DeploySigned {
    VmScript internal constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));
    bool public IS_SCRIPT = true;

    function run()
        external
        returns (address oracle, address staking, address emission, address token, address founderLock, address mining)
    {
        address signer = vm.envAddress("ORACLE_SIGNER");
        address beneficiary = vm.envAddress("FOUNDER_BENEFICIARY");
        uint256 initialMint = vm.envUint("INITIAL_MINT_BCUS") * 1e18;

        vm.startBroadcast();
        SignedMortalityOracle o = new SignedMortalityOracle(signer);
        BcusStaking st = new BcusStaking();
        FounderLock lock = new FounderLock(beneficiary);
        BcusMining m = new BcusMining();
        MortalityEmission e = new MortalityEmission(address(o), address(st), address(m), address(lock), initialMint);
        o.bind(address(e));
        st.bind(address(e));
        m.bind(address(e));
        vm.stopBroadcast();
        require(e.token().balanceOf(address(lock)) == initialMint, "Startmenge nicht im FounderLock");
        return (address(o), address(st), address(e), address(e.token()), address(lock), address(m));
    }
}
