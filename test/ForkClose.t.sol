// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {PoolCloser, IToken} from "../script/ClosePool.s.sol";

/// @notice Forked-mainnet dry run of the close. Runs the EXACT close sequence (ClosePool._close)
///         against the REAL live position, impersonating the euler-account owner, and asserts the
///         debt is fully repaid, collateral withdrawn, equity returned, and the pool operator revoked.
///         Run BEFORE broadcasting:  forge test --mc ForkClose -vvv --fork-url $MAINNET_RPC_URL
contract ForkClose is Test, PoolCloser {
    address constant OWNER = 0x32507c0d4182F39e5CFc5C4BF51fC55D594eDa88; // euler account == owner
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_close_real_position() public {
        address recipient = makeAddr("recipient");

        uint256 debt = IEVault(USDC_VAULT).debtOf(OWNER);
        uint256 collShares = IEVault(USDT_VAULT).balanceOf(OWNER);
        uint256 collAssets = IEVault(USDT_VAULT).convertToAssets(collShares);
        console2.log("--- before ---");
        console2.log("USDC debt (6dp):", debt);
        console2.log("USDT collateral (6dp):", collAssets);
        assertGt(debt, 0, "expected an open USDC debt to close");

        // Impersonate the owner and run the real close sequence.
        vm.startPrank(OWNER, OWNER);
        _close(OWNER, recipient, debt);
        vm.stopPrank();

        uint256 got = IToken(USDC).balanceOf(recipient);
        console2.log("--- after ---");
        console2.log("USDC debt (6dp):", IEVault(USDC_VAULT).debtOf(OWNER));
        console2.log("USDT coll shares left:", IEVault(USDT_VAULT).balanceOf(OWNER));
        console2.log("USDC returned to you (6dp):", got);

        assertEq(IEVault(USDC_VAULT).debtOf(OWNER), 0, "debt must be fully repaid");
        assertEq(IEVault(USDT_VAULT).balanceOf(OWNER), 0, "all collateral must be withdrawn");
        assertFalse(EVC.isAccountOperatorAuthorized(OWNER, POOL), "pool operator must be revoked");

        // Recovered equity should be roughly collateral - debt (a couple hundred $, here ~$198).
        assertGt(got, 50e6, "should recover a meaningful amount of equity");
        assertApproxEqAbs(got, collAssets - debt, 10e6, "equity returned should ~= collateral - debt");
    }
}
