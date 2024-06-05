// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";
import { CurrencyLibrary, Currency } from "v4-core/types/Currency.sol";
import {AdvancedOrders} from "../src/AdvancedOrders.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {Deployers} from "v4-core-tests/utils/Deployers.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

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
            token1 = TestERC20(Currency.unwrap(_tokenB));             
        }

        hook = new AdvancedOrders(manager);

        // Create the pool
        poolKey = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(hook));
        manager.initialize(poolKey, SQRT_PRICE_1_1, ZERO_BYTES);

        (poolKey, poolId) = initPoolAndAddLiquidity(
            _tokenA, 
            _tokenB, 
            hook, 
            3000, 
            SQRT_PRICE_1_1, 
            ZERO_BYTES);

        // Approve for swapping
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 100e18;
        AdvancedOrders.OrderType orderType = AdvancedOrders.OrderType.BUY_STOP;
        uint256 balanceBefore = token0.balanceOf(address(this));
        token0.approve(address(hook), amount);

        bytes32 orderId = hook.placeOrder(orderType, amount, tick, poolKey, tick);
        assertEq(token0.balanceOf(address(this)), balanceBefore - amount);

        AdvancedOrders.Order memory order = hook.orders(orderId);
        assertEq(order.user, address(this));
        assertEq(order.amountIn, amount);
        assertEq(order.triggerTick, tick);
        assertEq(uint(order.status), uint(AdvancedOrders.OrderStatus.OPEN));
    }

    function test_cancelOrder() public {
        int24 tick = 100;
        uint256 amount = 100e18;
        AdvancedOrders.OrderType orderType = AdvancedOrders.OrderType.BUY_STOP;
        token0.approve(address(hook), amount);

        bytes32 orderId = hook.placeOrder(orderType, amount, tick, poolKey, tick);
        hook.cancelOrder(orderId);

        AdvancedOrders.Order memory order = hook.orders(orderId);
        assertEq(uint(order.status), uint(AdvancedOrders.OrderStatus.CANCELED));
        assertEq(token0.balanceOf(address(this)), amount);
    }

    function test_afterSwap() public {
        int24 tick = 100;
        uint256 amount = 10e18;
        AdvancedOrders.OrderType orderType = AdvancedOrders.OrderType.BUY_STOP;
        token0.approve(address(hook), amount);
        bytes32 orderId = hook.placeOrder(orderType, amount, tick, poolKey, tick);

        // Perform a test swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1
        });
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true,
            settleUsingBurn: true
        });
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Check if the order was executed
        AdvancedOrders.Order memory order = hook.orders(orderId);
        assertEq(uint(order.status), uint(AdvancedOrders.OrderStatus.EXECUTED));
    }
}
