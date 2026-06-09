// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {IEulerSwapFactory} from "euler-swap/interfaces/IEulerSwapFactory.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @notice Minimal deploy of a credit-amplified USDC/USDT EulerSwap pool (static fee, no hook).
///         Broadcasts EVC calls 2-4 from the README sequence. Deposit (step 1) is done via UI.
///         The euler account = sub-account that already holds the collateral; the broadcasting
///         wallet must be that sub-account's EVC owner. Signing is done by your own keystore.
contract DeployStablePool is Script {
    // --- VERIFIED mainnet addresses (re-verify on Etherscan before broadcast) ---
    IEVC constant EVC = IEVC(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);
    IEulerSwapFactory constant FACTORY = IEulerSwapFactory(0xD05213331221fAB8a3C387F2affBb605Bb04DF5F);
    address constant USDC_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9; // eUSDC-2  -> asset0 (USDC)
    address constant USDT_VAULT = 0x313603FA690301b0CaeEf8069c065862f9162162; // eUSDT-2  -> asset1 (USDT)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // --- TUNABLES ---
    // Virtual depth per side (6dp). Set comfortably ABOVE your real credit cap so the curve never
    // caps you before your live borrow capacity does. Cosmetic beyond that for a constant-sum curve;
    // keep <= ~1e18 to avoid curve-math overflow. Default ~$100M mirrors the live cluster's depth.
    uint112 constant VIRTUAL_RESERVE = 100_000_000e6;
    // 1e18 = constant-sum (flat 1:1, tightest routing, max depeg exposure). Lower = slippage cushion.
    uint64 constant CONCENTRATION = 1e18;
    // Static fee per direction. 1e18 = 100%. 1e14 = 0.01%.
    uint64 constant FEE = 1e14;

    // EulerSwap pools are Uniswap V4 hooks: the pool's CREATE2 address must encode the hook
    // permission flags (beforeInitialize|beforeAddLiquidity|beforeSwap|beforeDonate|
    // beforeSwapReturnDelta = 0x28A8 in the low 14 bits), so the salt must be mined.
    uint160 constant HOOK_MASK = 0x3FFF;
    uint160 constant HOOK_FLAGS = 0x28A8;

    function run() external {
        address acct = vm.envOr("EULER_ACCOUNT", msg.sender); // sub-account holding the collateral

        IEulerSwap.StaticParams memory sp = IEulerSwap.StaticParams({
            supplyVault0: USDC_VAULT,
            supplyVault1: USDT_VAULT,
            borrowVault0: USDC_VAULT,
            borrowVault1: USDT_VAULT,
            eulerAccount: acct,
            feeRecipient: address(0)
        });
        IEulerSwap.DynamicParams memory dp = IEulerSwap.DynamicParams({
            equilibriumReserve0: VIRTUAL_RESERVE,
            equilibriumReserve1: VIRTUAL_RESERVE,
            minReserve0: 0,
            minReserve1: 0,
            priceX: 1e18,
            priceY: 1e18,
            concentrationX: CONCENTRATION,
            concentrationY: CONCENTRATION,
            fee0: FEE,
            fee1: FEE,
            expiration: 0,
            swapHookedOperations: 0,
            swapHook: address(0)
        });
        // InitialState must sit exactly on the curve; equilibrium point satisfies activate()'s checks.
        IEulerSwap.InitialState memory init =
            IEulerSwap.InitialState({reserve0: VIRTUAL_RESERVE, reserve1: VIRTUAL_RESERVE});

        // (3a) mine a salt -> deterministic hook-valid pool address (depends only on static params)
        (bytes32 salt, address predicted) = _mineSalt(sp);
        console2.log("euler account:    ", acct);
        console2.log("mined salt:       ", uint256(salt));
        console2.log("predicted pool:   ", predicted);

        vm.startBroadcast();
        // (2) enable both vaults as collateral = the amplification switch (also done idempotently by activate)
        if (!EVC.isCollateralEnabled(acct, USDC_VAULT)) EVC.enableCollateral(acct, USDC_VAULT);
        if (!EVC.isCollateralEnabled(acct, USDT_VAULT)) EVC.enableCollateral(acct, USDT_VAULT);
        // (3) install the not-yet-deployed pool as operator BEFORE deploy (factory requires it)
        if (!EVC.isAccountOperatorAuthorized(acct, predicted)) EVC.setAccountOperator(acct, predicted, true);
        // (4) deploy. Factory requires _msgSender()==eulerAccount: call direct if owner==account, else route via EVC.
        address pool;
        if (acct == msg.sender) {
            pool = FACTORY.deployPool(sp, dp, init, salt);
        } else {
            bytes memory ret =
                EVC.call(address(FACTORY), acct, 0, abi.encodeCall(IEulerSwapFactory.deployPool, (sp, dp, init, salt)));
            pool = abi.decode(ret, (address));
        }
        vm.stopBroadcast();

        require(pool == predicted, "pool address mismatch");
        console2.log("DEPLOYED pool:    ", pool);
        _report(pool, acct);
    }

    function _mineSalt(IEulerSwap.StaticParams memory sp) internal view returns (bytes32 salt, address addr) {
        bytes32 initHash = keccak256(FACTORY.creationCode(sp));
        for (uint256 i = 0; i < 200_000; i++) {
            bytes32 s = bytes32(i);
            address a =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(FACTORY), s, initHash)))));
            if (uint160(a) & HOOK_MASK == HOOK_FLAGS) return (s, a);
        }
        revert("no salt found");
    }

    /// @dev Read-only post-deploy report. NOTE: getLimits() is an UPPER bound (cash/caps/reserves);
    ///      it does NOT apply your account's LTV/health, so the true fill cap (~16.7x of NAV) is
    ///      lower and is proven by the fork test (ForkDeploy.t.sol), which executes real swaps.
    function _report(address pool, address acct) internal view {
        (uint112 r0, uint112 r1,) = IEulerSwap(pool).getReserves();
        console2.log("reserve0 USDC(6dp):", uint256(r0));
        console2.log("reserve1 USDT(6dp):", uint256(r1));
        (, uint256 outUSDT) = IEulerSwap(pool).getLimits(USDC, USDT);
        (, uint256 outUSDC) = IEulerSwap(pool).getLimits(USDT, USDC);
        console2.log("getLimits max USDT out (upper bound):", outUSDT);
        console2.log("getLimits max USDC out (upper bound):", outUSDC);
        console2.log("USDC debt:", IEVault(USDC_VAULT).debtOf(acct));
        console2.log("USDT debt (0 at deploy -> HF = inf):", IEVault(USDT_VAULT).debtOf(acct));
    }
}
