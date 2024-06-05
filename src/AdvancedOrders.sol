// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BaseHook } from "v4-periphery/BaseHook.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { CurrencyLibrary, Currency } from "v4-core/types/Currency.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/**
 * @title AdvancedOrders
 * @dev A Uniswap V4 hook contract for advanced order types: stop loss, buy stop, buy limit, and take profit.
 *      It also supports execution aggregation via EigenLayer AVS.
 */
contract AdvancedOrders is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    enum OrderType {
        STOP_LOSS,
        BUY_STOP,
        BUY_LIMIT,
        TAKE_PROFIT
    }
    enum OrderStatus {
        OPEN,
        EXECUTED,
        CANCELED
    }

    struct Order {
        bytes32 id;
        address user;
        OrderType orderType;
        uint256 amountIn;
        int24 triggerTick;
        OrderStatus status;
        bool zeroForOne;
    }

    // IPoolManager public pool;
    // EigenLayerAVS public avs; // TODO: integrate avs
    uint256 public orderCount;
    PoolKey public poolKey;
    mapping(bytes32 => Order) public orders;
    mapping(int24 tick => mapping(bool zeroForOne => Order[])) public orderPositions;
    mapping(PoolId => int24) public tickLowerLasts;
    mapping(address userAddress => Order[]) public userOrders;

    event OrderPlaced(
        bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, int24 triggerPrice
    );
    event OrderExecuted(
        bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, int24 triggerPrice
    );
    event OrderCanceled(
        bytes32 indexed orderId, address indexed user, OrderType orderType);

    event OrdersProcessed(bytes32[] orderIds);

    constructor(IPoolManager _manager) BaseHook(_manager) { }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        poolManagerOnly
        override
        returns (bytes4)
    {
        poolKey = key;
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));

        return AdvancedOrders.afterInitialize.selector;
    }

    function placeOrder(
        OrderType orderType,
        uint256 amountIn,
        int24 _triggerTick,
        PoolKey calldata _poolKey,
        int24 tickLower
    ) external returns (bytes32 orderId) {
        require(amountIn > 0, "Amount must be greater than 0");

        orderId = keccak256(abi.encodePacked(orderCount, msg.sender, block.timestamp));
        bool zeroForOne = (orderType == OrderType.BUY_STOP) || (orderType == OrderType.STOP_LOSS);
        orders[orderId] = Order({ 
            id: orderId,
            user: msg.sender, 
            orderType: orderType, 
            amountIn: amountIn, 
            triggerTick: 
            _triggerTick, 
            status: OrderStatus.OPEN, 
            zeroForOne: zeroForOne 
        });
        int24 tick = getTickLower(tickLower, _poolKey.tickSpacing);
        orderPositions[tick][zeroForOne].push(orders[orderId]);
        userOrders[msg.sender].push(orders[orderId]);
        orderCount++;

        // Transfer token0 to this contract
        address token = zeroForOne ? Currency.unwrap(_poolKey.currency0) : Currency.unwrap(_poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
        emit OrderPlaced(orderId, msg.sender, orderType, amountIn, _triggerTick);
    }

    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function cancelOrder(bytes32 orderId) external {
        Order storage order = orders[orderId];
        require(order.user == msg.sender, "Only the order creator can cancel the order");
        require(order.status == OrderStatus.OPEN, "Order can only be canceled if it is open");

        // Update order status to canceled
        order.status = OrderStatus.CANCELED;

        // Transfer the tokens back to the user
        address token = order.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IERC20(token).transfer(order.user, order.amountIn);

        emit OrderCanceled(orderId, msg.sender, order.orderType);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        int24 prevTick = tickLowerLasts[key.toId()];
        int24 tick = getTick(key.toId());
        int24 currentTick = getTickLower(tick, key.tickSpacing);
        tick = prevTick;

        Order[] memory validOrders;
        // fill orders in the opposite direction of the swap
        bool orderZeroForOne = !params.zeroForOne;

        if (prevTick < currentTick) {
            for (; tick < currentTick;) {
                validOrders = orderPositions[tick][orderZeroForOne];
                
                bytes32[] memory orderIds = new bytes32[](validOrders.length);
                uint256 index = 0;
                for (uint256 i = 0; i < validOrders.length; i++) {
                    orderIds[index] = validOrders[i].id;
                    index++;
                }
                emit OrdersProcessed(orderIds);
                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; currentTick < tick;) {
                validOrders = orderPositions[tick][orderZeroForOne];
                bytes32[] memory orderIds = new bytes32[](validOrders.length);
                uint256 index = 0;
                for (uint256 i = 0; i < validOrders.length; i++) {
                    orderIds[index] = validOrders[i].id;
                    index++;
                }
                emit OrdersProcessed(orderIds);
                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }
        return (AdvancedOrders.afterSwap.selector, 0);
    }

    function settleOrder(bytes32 orderId, bytes calldata _extraData) external { // TODO: add modifier
        Order storage order = orders[orderId];
        int24 currentTick = getTick(poolKey.toId());

        if(shouldExecuteOrder(order, currentTick)) {
            address tokenIn = order.zeroForOne ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);
            address tokenOut = order.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
            IERC20(tokenIn).transfer(msg.sender, order.amountIn);

            (bool success,) = msg.sender.call(
                abi.encodeWithSignature("settleCallback(address,address,bytes)", tokenIn, tokenOut, _extraData)
            );
            require(success, "Settle callback failed");
            // TODO: Validate fullfilment? (checkOrder fn based on the tick)

            order.status = OrderStatus.EXECUTED;
            IERC20(tokenOut).transfer(order.user, IERC20(tokenOut).balanceOf(address(this)));
        }
    }

     function shouldExecuteOrder(Order storage order, int24 currentTick) internal view returns (bool) {
        if (order.orderType == OrderType.STOP_LOSS && currentTick <= order.triggerTick) {
            return true;
        } else if (order.orderType == OrderType.BUY_STOP && currentTick >= order.triggerTick) {
            return true;
        } else if (order.orderType == OrderType.BUY_LIMIT && currentTick <= order.triggerTick) {
            return true;
        } else if (order.orderType == OrderType.TAKE_PROFIT && currentTick >= order.triggerTick) {
            return true;
        }
        return false;
    }

    // -- Util functions -- //
    function getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }
}
