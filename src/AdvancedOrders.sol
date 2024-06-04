// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/**
 * @title AdvancedOrders
 * @dev A Uniswap V4 hook contract for advanced order types: stop loss, buy stop, buy limit, and take profit.
 *      It also supports execution aggregation via EigenLayer AVS.
 */
contract AdvancedOrders is BaseHook, ERC1155 {
    using FixedPointMathLib for uint256;

    enum OrderType { STOP_LOSS, BUY_STOP, BUY_LIMIT, TAKE_PROFIT }
    enum OrderStatus { OPEN, EXECUTED, CANCELED }
    struct Order {
        address user;
        OrderType orderType;
        uint256 amountIn;
        uint256 triggerTick;
        bool OrderStatus;
        bool zeroForOne;
    }

    IPoolManager public pool;
    EigenLayerAVS public avs; // TODO: integrate avs
    uint256 public orderCount;
    mapping(bytes32 => Order) public orders;
    mapping(int24 tick => mapping(bool zeroForOne => orders)) public orderPositions;
    mapping(PoolId => int24) public tickLowerLasts;

    // constants for sqrtPriceLimitX96 which allow for unlimited impact
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;

    event OrderPlaced(bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, uint256 triggerPrice);
    event OrderExecuted(bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, uint256 triggerPrice);

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterInitialize(address, IPoolManager.PoolKey calldata key, uint160, int24 tick)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));
        return AdvancedOrders.afterInitialize.selector;
    }

    /**
     * @notice Places an order of a specified type.
     * @param orderType The type of the order.
     * @param amountIn The amount of tokens involved in the order.
     * @param triggerPrice The price at which the order should be triggered.
     */
    function placeOrder(OrderType orderType, uint256 amountIn, uint256 triggerPrice, PoolId poolId) external returns (bytes32 orderId) {
        require(amountIn > 0, "Amount must be greater than 0");
        require(triggerPrice > 0, "Trigger price must be greater than 0");

        IERC20(pool.token0()).safeTransferFrom(msg.sender, address(this), amountIn);

        orderId = keccak256(abi.encodePacked(orderCount, msg.sender, block.timestamp));
        bool zeroForOne = OrderType.BUY_STOP ||  OrderType.STOP_LOSS;
        orders[orderId] = Order(msg.sender, orderType, amountIn, triggerPrice, false, zeroForOne);
        int24 tick = getTick(poolId);
        orderPositions[tick][zeroForOne][orderId] = orders[orderId];
        orderCount++;

        emit OrderPlaced(orderId, msg.sender, orderType, amountIn, triggerPrice);
    }

    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override returns (bytes4) {
        int24 prevTick = tickLowerLasts[key.toId()];
        (, int24 tick,) = poolManager.getSlot0(key.toId());
        int24 currentTick = getTickLower(tick, key.tickSpacing);
        tick = prevTick;

        Order[] memory orders;
        // fill orders in the opposite direction of the swap
        bool orderZeroForOne = !params.zeroForOne;

        if (prevTick < currentTick) {
            for (; tick < currentTick;) {
                orders = orderPositions[key.toId()][tick][orderZeroForOne];
                // TODO: Implement avs for order processing
                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; currentTick < tick;) {
                orders = orderPositions[key.toId()][tick][orderZeroForOne];
                // TODO: Implement avs for order processing
                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }
        return AdvancedOrders.afterSwap.selector;
    }


    /**
     * @dev Placeholder function to perform token swaps 
     * @param order The order to execute.
     */
    function performSwap(IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params, address receiver)
    internal
    returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encodeCall(this.handleSwap, (key, params, receiver))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    // -- 1155 -- //
    function uri(uint256) public pure override returns (string memory) {
        return "https://uniswap-advanced-orders.com/";
    }

    function getTokenId(IPoolManager.PoolKey calldata poolKey, int24 tickLower, bool zeroForOne)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)));
    }

    function redeem(uint256 tokenId, uint256 amountIn, address destination) external {
        require(claimable[tokenId] > 0, "StopLoss: no claimable amount");
        uint256 receiptBalance = balanceOf[msg.sender][tokenId];
        require(amountIn <= receiptBalance, "StopLoss: not enough tokens to redeem");

        TokenIdData memory data = tokenIdIndex[tokenId];
        address token =
            data.zeroForOne ? Currency.unwrap(data.poolKey.currency1) : Currency.unwrap(data.poolKey.currency0);

        uint256 amountOut = amountIn.mulDivDown(claimable[tokenId], totalSupply[tokenId]);
        claimable[tokenId] -= amountOut;
        _burn(msg.sender, tokenId, amountIn);
        totalSupply[tokenId] -= amountIn;

        IERC20(token).transfer(destination, amountOut);
    }
    // ---------- //

    // -- Util functions -- //
    function setTickLowerLast(bytes32 poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }
}
