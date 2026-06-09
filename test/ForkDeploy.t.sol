// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {IEulerSwap} from "euler-swap/interfaces/IEulerSwap.sol";
import {IEulerSwapFactory} from "euler-swap/interfaces/IEulerSwapFactory.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

/// @dev Minimal token interface tolerant of USDT's no-return approve/transfer.
interface IToken {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
}

/// @notice Forked-mainnet dry run. This is NOT a deploy script — it proves, on a fork, that the
///         pool deploys, that the REAL fill cap is the LTV-bound credit limit (~16.7x of NAV, far
///         below getLimits' upper bound), and prints the resulting health factor. Run with:
///         forge test --mc ForkDeploy -vv --fork-url $MAINNET_RPC_URL
contract ForkDeploy is Test {
    IEVC constant EVC = IEVC(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);
    IEulerSwapFactory constant FACTORY = IEulerSwapFactory(0xD05213331221fAB8a3C387F2affBb605Bb04DF5F);
    address constant USDC_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address constant USDT_VAULT = 0x313603FA690301b0CaeEf8069c065862f9162162;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // mirror the deploy script's tunables
    uint112 constant VIRTUAL_RESERVE = 100_000_000e6;
    uint64 constant CONCENTRATION = 1e18;
    uint64 constant FEE = 1e14;

    address pool;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function _staticParams() internal view returns (IEulerSwap.StaticParams memory sp) {
        sp = IEulerSwap.StaticParams({
            supplyVault0: USDC_VAULT,
            supplyVault1: USDT_VAULT,
            borrowVault0: USDC_VAULT,
            borrowVault1: USDT_VAULT,
            eulerAccount: address(this),
            feeRecipient: address(0)
        });
    }

    function _deploy() internal {
        // Step 1: fund this account ($100 each) and deposit as the euler account's collateral.
        deal(USDC, address(this), 100e6, true);
        deal(USDT, address(this), 100e6, true);
        IToken(USDC).approve(USDC_VAULT, 100e6);
        IToken(USDT).approve(USDT_VAULT, 100e6);
        IEVault(USDC_VAULT).deposit(100e6, address(this));
        IEVault(USDT_VAULT).deposit(100e6, address(this));

        IEulerSwap.StaticParams memory sp = _staticParams();
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
        IEulerSwap.InitialState memory init =
            IEulerSwap.InitialState({reserve0: VIRTUAL_RESERVE, reserve1: VIRTUAL_RESERVE});

        (bytes32 salt, address predicted) = _mineSalt(sp);

        // Steps 2-4
        EVC.enableCollateral(address(this), USDC_VAULT);
        EVC.enableCollateral(address(this), USDT_VAULT);
        EVC.setAccountOperator(address(this), predicted, true);
        pool = FACTORY.deployPool(sp, dp, init, salt);
        assertEq(pool, predicted, "address mismatch");
    }

    /// @dev EulerSwap pools are Uniswap V4 hooks: the pool address must encode the hook permission
    ///      flags (beforeInitialize|beforeAddLiquidity|beforeSwap|beforeDonate|beforeSwapReturnDelta
    ///      = 0x28A8 in the low 14 bits). Mine a salt whose CREATE2 address matches.
    uint160 constant HOOK_MASK = 0x3FFF;
    uint160 constant HOOK_FLAGS = 0x28A8;

    function _mineSalt(IEulerSwap.StaticParams memory sp) internal view returns (bytes32 salt, address addr) {
        bytes32 initHash = keccak256(FACTORY.creationCode(sp));
        for (uint256 i = 0; i < 200_000; i++) {
            bytes32 s = bytes32(i);
            address a = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(FACTORY), s, initHash))))
            );
            if (uint160(a) & HOOK_MASK == HOOK_FLAGS) return (s, a);
        }
        revert("no salt found");
    }

    /// @dev Try to buy `usdtOut` USDT from the pool (selling USDC). Returns true if the swap succeeds.
    ///      State is snapshotted and rolled back so probes don't accumulate.
    function _probeUsdtOut(uint256 usdtOut) internal returns (bool ok, uint256 usdcIn) {
        uint256 snap = vm.snapshotState();
        usdcIn = IEulerSwap(pool).computeQuote(USDC, USDT, usdtOut, false); // exact-out -> required USDC in
        deal(USDC, address(this), usdcIn, true);
        IToken(USDC).transfer(pool, usdcIn); // pre-fund the optimistic swap
        try IEulerSwap(pool).swap(0, usdtOut, address(this), "") {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToState(snap);
    }

    function test_deploy_and_real_depth_and_hf() public {
        _deploy();

        (uint112 r0, uint112 r1,) = IEulerSwap(pool).getReserves();
        (, uint256 outUSDTupper) = IEulerSwap(pool).getLimits(USDC, USDT);
        console2.log("--- post-deploy ---");
        console2.log("reserve0 USDC(6dp):", uint256(r0));
        console2.log("reserve1 USDT(6dp):", uint256(r1));
        console2.log("getLimits USDT-out UPPER bound (ignores LTV):", outUSDTupper);

        // Probe the REAL fill cap (LTV-bound). $200 NAV, 0.94 borrow LTV -> expect ~3233 USDT.
        uint256[10] memory sizes =
            [uint256(1000e6), 2000e6, 3000e6, 3200e6, 3233e6, 3300e6, 3500e6, 4000e6, 4500e6, 4900e6];
        uint256 maxOk;
        console2.log("--- probing real max USDT out (sell USDC) ---");
        for (uint256 i; i < sizes.length; i++) {
            (bool ok,) = _probeUsdtOut(sizes[i]);
            console2.log(ok ? "  OK    USDT out:" : "  REVERT USDT out:", sizes[i] / 1e6);
            if (ok && sizes[i] > maxOk) maxOk = sizes[i];
        }
        console2.log("largest succeeding USDT out (6dp):", maxOk);
        assertGt(maxOk, 3000e6, "expected >3000 USDT real depth");
        assertLt(maxOk, 4900e6, "expected <4900 (25x edge unreachable)");

        // Execute one real swap at a safe size and report the health factor.
        uint256 safeOut = (maxOk * 80) / 100;
        uint256 usdcIn = IEulerSwap(pool).computeQuote(USDC, USDT, safeOut, false);
        deal(USDC, address(this), usdcIn, true);
        IToken(USDC).transfer(pool, usdcIn);
        IEulerSwap(pool).swap(0, safeOut, address(this), "");

        (uint112 nr0, uint112 nr1,) = IEulerSwap(pool).getReserves();
        uint256 usdtDebt = IEVault(USDT_VAULT).debtOf(address(this));
        // controller (USDT vault) reports risk-adjusted collateral vs liability for the account
        (uint256 col, uint256 liab) = IEVault(USDT_VAULT).accountLiquidity(address(this), false);
        console2.log("--- after a real swap of (USDT out, 6dp):", safeOut);
        console2.log("reserve0 USDC(6dp):", uint256(nr0));
        console2.log("reserve1 USDT(6dp):", uint256(nr1));
        console2.log("USDT debt (6dp):", usdtDebt);
        console2.log("risk-adj collateral value:", col);
        console2.log("liability value:", liab);
        console2.log("health factor (1e18=1.0):", liab == 0 ? type(uint256).max : col * 1e18 / liab);
        assertGe(col, liab, "account must be healthy after swap");
    }

    /// @dev Verifies the production path used by the deploy script when eulerAccount is a non-zero
    ///      sub-account: deployPool must be ROUTED through EVC.call so _msgSender()==eulerAccount.
    function test_deploy_under_subaccount_via_evc_routing() public {
        address sub = address(uint160(address(this)) ^ 1); // sub-account id 1 of this owner

        deal(USDC, address(this), 100e6, true);
        deal(USDT, address(this), 100e6, true);
        IToken(USDC).approve(USDC_VAULT, 100e6);
        IToken(USDT).approve(USDT_VAULT, 100e6);
        IEVault(USDC_VAULT).deposit(100e6, sub); // collateral credited to the sub-account
        IEVault(USDT_VAULT).deposit(100e6, sub);

        IEulerSwap.StaticParams memory sp = _staticParams();
        sp.eulerAccount = sub;
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
        IEulerSwap.InitialState memory init =
            IEulerSwap.InitialState({reserve0: VIRTUAL_RESERVE, reserve1: VIRTUAL_RESERVE});
        (bytes32 salt, address predicted) = _mineSalt(sp);

        // owner (this) authorizes for its sub-account directly...
        EVC.enableCollateral(sub, USDC_VAULT);
        EVC.enableCollateral(sub, USDT_VAULT);
        EVC.setAccountOperator(sub, predicted, true);
        // ...but deployPool requires _msgSender()==eulerAccount, so it must go through EVC.call
        bytes memory ret =
            EVC.call(address(FACTORY), sub, 0, abi.encodeCall(IEulerSwapFactory.deployPool, (sp, dp, init, salt)));
        address routedPool = abi.decode(ret, (address));
        assertEq(routedPool, predicted, "routed deploy address mismatch");

        // sanity: pool is live and quotes for the sub-account
        uint256 quote = IEulerSwap(routedPool).computeQuote(USDC, USDT, 1000e6, true);
        assertGt(quote, 0, "routed pool should quote");
        console2.log("sub-account pool deployed via EVC.call:", routedPool);
    }
}
