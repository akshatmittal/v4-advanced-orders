// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { GasSnapshot } from "forge-gas-snapshot/GasSnapshot.sol";
import { TestERC20 } from "v4-core/test/TestERC20.sol";
import { IERC20Minimal } from "v4-core/interfaces/external/IERC20Minimal.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolDonateTest } from "v4-core/test/PoolDonateTest.sol";
import { CurrencyLibrary, Currency } from "v4-core/types/Currency.sol";
import { AdvancedOrders } from "../src/AdvancedOrders.sol";
import { OrderSettler } from "../src/OrderSettler.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { Deployers } from "v4-core-tests/utils/Deployers.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { HookMiner } from "./utils/HookMiner.sol";

contract AdvancedOrdersTest is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    AdvancedOrders hook;
    Currency _tokenA;
    Currency _tokenB;
    TestERC20 token0;
    TestERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
        // Deploy two test tokens
        (_tokenA, _tokenB) = deployMintAndApprove2Currencies();

        if (_tokenA < _tokenB) {
            token0 = TestERC20(Currency.unwrap(_tokenA));
            token1 = TestERC20(Currency.unwrap(_tokenB));
        } else {
            token0 = TestERC20(Currency.unwrap(_tokenB));
            token1 = TestERC20(Currency.unwrap(_tokenA));
        }

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(AdvancedOrders).creationCode, abi.encode(manager));

        hook = new AdvancedOrders{ salt: salt }(manager);

        // Create the pool and add liquidity
        (poolKey, poolId) = initPoolAndAddLiquidity(_tokenA, _tokenB, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Approve for swapping
        token0.approve(address(swapRouter), 100 ether);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(swapRouter), 100 ether);
        token1.approve(address(hook), type(uint256).max);
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 1 ether;
        AdvancedOrders.OrderType orderType = AdvancedOrders.OrderType.BUY_STOP;
        uint256 balanceBefore = token0.balanceOf(address(this));
        token0.approve(address(hook), amount);

        bytes32 orderId = hook.placeOrder(orderType, amount, tick, poolKey, tick);
        assertEq(token0.balanceOf(address(this)), balanceBefore - amount);

        AdvancedOrders.Order memory order = hook.getOrder(orderId);
        assertEq(order.user, address(this));
        assertEq(order.amountIn, amount);
        assertEq(order.triggerTick, tick);
        assertEq(uint256(order.status), uint256(AdvancedOrders.OrderStatus.OPEN));
    }

    function test_cancelOrder() public {
        int24 tick = 100;
        uint256 amount = 1 ether;
        AdvancedOrders.OrderType orderType = AdvancedOrders.OrderType.BUY_STOP;
        token0.approve(address(hook), amount);

        bytes32 orderId = hook.placeOrder(orderType, amount, tick, poolKey, tick);
        hook.cancelOrder(orderId);

        AdvancedOrders.Order memory order = hook.getOrder(orderId);
        assertEq(uint256(order.status), uint256(AdvancedOrders.OrderStatus.CANCELED));
    }

    function test_afterSwap() public {
        int24 tick = 100;
        uint256 amount = 1 ether;
        AdvancedOrders.OrderType orderType = AdvancedOrders.OrderType.BUY_STOP;
        token0.approve(address(hook), amount);
        bytes32 orderId = hook.placeOrder(orderType, amount, tick, poolKey, tick);

        // Perform a test swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 0.001 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({ takeClaims: true, settleUsingBurn: false });
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Check if the order was executed
        AdvancedOrders.Order memory order = hook.getOrder(orderId);
        assertEq(uint256(order.status), uint256(AdvancedOrders.OrderStatus.OPEN));
    }

    function test_fulfilOrder() public {
        address user = vm.addr(111);
        vm.startPrank(user);
        // Order placing
        token0.mint(user, 100 ether);
        int24 tick = 100;
        uint256 amount = 1 ether;
        AdvancedOrders.OrderType orderType = AdvancedOrders.OrderType.BUY_STOP;
        uint256 balanceBefore = token0.balanceOf(address(user));
        token0.approve(address(hook), amount);

        bytes32 orderId = hook.placeOrder(orderType, amount, tick, poolKey, tick);
        assertEq(token0.balanceOf(address(user)), balanceBefore - amount);
        vm.stopPrank();

        AdvancedOrders.Order memory order = hook.getOrder(orderId);

        // Change pool price to allow this trade to happen
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({ takeClaims: true, settleUsingBurn: false });
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Prepare settlement
        address filler = vm.addr(123);
        vm.startPrank(filler);
        OrderSettler settler = new OrderSettler();
        // This test ignores where the settler got the funds in the first place.
        token0.mint(address(settler), 10_000 * 10 ** 18);
        token1.mint(address(settler), 10_000 * 10 ** 18);

        uint256 balancePre = token1.balanceOf(address(order.user));
        OrderSettler.Call[] memory calls = new OrderSettler.Call[](1);
        calls[0] = OrderSettler.Call({
            target: address(token1),
            value: 0,
            callData: abi.encodeWithSelector(TestERC20.transfer.selector, address(order.user), 1 * 10 ** 18) // Just an example settlement.
         });
        settler.initiateSettle(address(hook), order.id, calls);
        uint256 balancePost = token1.balanceOf(address(order.user));

        assertEq(balancePost - balancePre, 1 * 10 ** 18);
        vm.stopPrank();
    }
}
