// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @dev USDT-tolerant token interface (no return values on approve/transfer).
interface IToken {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
}

/// @dev Uniswap v3 SwapRouter02 (exact-input single-hop).
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Atomic deleverage helper. Called from inside an EVC batch (so the account's health check
///         is deferred to the end): it receives the withdrawn USDT collateral, swaps it to USDC on
///         Uniswap v3, repays the account's full USDC debt, and sweeps the remaining equity to you.
contract CloseHelper {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    ISwapRouter02 constant ROUTER = ISwapRouter02(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    uint24 constant POOL_FEE = 100; // Uniswap v3 USDC/USDT 0.01% pool (deepest)

    /// @dev Swap all held USDT -> USDC, repay `account`'s USDC debt in full, sweep the rest to `recipient`.
    function swapAndRepay(address account, address recipient) external {
        uint256 debt = IEVault(USDC_VAULT).debtOf(account);
        uint256 haveUSDT = IToken(USDT).balanceOf(address(this));
        require(haveUSDT > 0, "no USDT to swap");

        IToken(USDT).approve(address(ROUTER), haveUSDT);
        // amountOutMinimum = debt -> revert unless the swap yields enough to fully repay (safe floor).
        ROUTER.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDT,
                tokenOut: USDC,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: haveUSDT,
                amountOutMinimum: debt,
                sqrtPriceLimitX96: 0
            })
        );

        IToken(USDC).approve(USDC_VAULT, type(uint256).max);
        IEVault(USDC_VAULT).repay(type(uint256).max, account); // repays the full outstanding debt

        uint256 leftUSDC = IToken(USDC).balanceOf(address(this));
        if (leftUSDC > 0) IToken(USDC).transfer(recipient, leftUSDC);
        uint256 leftUSDT = IToken(USDT).balanceOf(address(this));
        if (leftUSDT > 0) IToken(USDT).transfer(recipient, leftUSDT);
    }
}

/// @notice Shared close logic (no forge cheatcodes), so the fork test exercises the EXACT sequence
///         that gets broadcast. Assumes the caller (msg.sender) owns `account`.
abstract contract PoolCloser {
    IEVC constant EVC = IEVC(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);
    address constant POOL = 0x2Cf734A241Ba6A036d09144a7A68053b15c2a8a8;
    address constant USDC_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address constant USDT_VAULT = 0x313603FA690301b0CaeEf8069c065862f9162162;

    /// @dev The close sequence. Pauses the pool, atomically deleverages, withdraws equity, tidies up.
    function _close(address account, address recipient, uint256 debt) internal {
        // 1) Pause: stop the pool from quoting / touching the account.
        if (EVC.isAccountOperatorAuthorized(account, POOL)) EVC.setAccountOperator(account, POOL, false);

        // 2) Atomic deleverage (only if there is debt): within one EVC batch the account health check
        //    is deferred, so we can pull all collateral, swap, and repay before the end-of-batch check.
        if (debt > 0) {
            CloseHelper helper = new CloseHelper();
            IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
            items[0] = IEVC.BatchItem({
                targetContract: USDT_VAULT,
                onBehalfOfAccount: account,
                value: 0,
                data: abi.encodeCall(IEVault.withdraw, (type(uint256).max, address(helper), account))
            });
            items[1] = IEVC.BatchItem({
                targetContract: address(helper),
                onBehalfOfAccount: account,
                value: 0,
                data: abi.encodeCall(CloseHelper.swapAndRepay, (account, recipient))
            });
            EVC.batch(items);
        }

        // 3) Withdraw any residual supply straight to you (covers the no-debt path and dust).
        if (IEVault(USDT_VAULT).balanceOf(account) > 0) {
            IEVault(USDT_VAULT).withdraw(type(uint256).max, recipient, account);
        }
        if (IEVault(USDC_VAULT).balanceOf(account) > 0) {
            IEVault(USDC_VAULT).withdraw(type(uint256).max, recipient, account);
        }

        // 4) Tidy up: drop the controller and collaterals (best-effort; funds are already recovered).
        if (IEVault(USDC_VAULT).debtOf(account) == 0) {
            try IEVault(USDC_VAULT).disableController() {} catch {}
        }
        try EVC.disableCollateral(account, USDT_VAULT) {} catch {}
        try EVC.disableCollateral(account, USDC_VAULT) {} catch {}
    }
}

/// @notice Close the credit-amplified USDC/USDT pool position and return your equity, with NO outside
///         capital: it pauses the pool, atomically deleverages (USDT collateral -> USDC -> repay debt),
///         withdraws the remaining ~equity, and tidies up controller/collateral/operator state.
///
///         ALWAYS dry-run on a fork first:  forge test --mc ForkClose -vvv --fork-url $MAINNET_RPC_URL
///         Broadcast (sign with your own keystore, never a raw key):
///           RECIPIENT=0xYou \
///           forge script script/ClosePool.s.sol:ClosePool \
///             --rpc-url $MAINNET_RPC_URL --account <name> --sender 0xYourOwner --broadcast --slow
contract ClosePool is Script, PoolCloser {
    function run() external {
        address account = vm.envOr("EULER_ACCOUNT", msg.sender);
        address recipient = vm.envOr("RECIPIENT", msg.sender);
        require(account == msg.sender, "broadcast as the euler account owner (sub-account: route via EVC)");

        uint256 debtBefore = IEVault(USDC_VAULT).debtOf(account);
        uint256 usdtColl = IEVault(USDT_VAULT).convertToAssets(IEVault(USDT_VAULT).balanceOf(account));
        console2.log("account:        ", account);
        console2.log("USDC debt (6dp):", debtBefore);
        console2.log("USDT coll (6dp):", usdtColl);

        vm.startBroadcast();
        _close(account, recipient, debtBefore);
        vm.stopBroadcast();

        console2.log("--- after ---");
        console2.log("USDC debt (6dp):", IEVault(USDC_VAULT).debtOf(account));
        console2.log("USDT coll (6dp):", IEVault(USDT_VAULT).balanceOf(account));
        console2.log("operator still authorized:", EVC.isAccountOperatorAuthorized(account, POOL));
    }
}

