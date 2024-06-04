// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ERC1155} from "solmate/tokens/ERC1155.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @title AdvancedOrders
 * @dev A Uniswap V4 hook contract for advanced order types: stop loss, buy stop, buy limit, and take profit.
 *      It also supports execution aggregation via EigenLayer AVS.
 */
contract AdvancedOrders is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;

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

    // IPoolManager public pool;
    // EigenLayerAVS public avs; // TODO: integrate avs
    uint256 public orderCount;
    mapping(bytes32 => Order) public orders;
    mapping(int24 tick => mapping(bool zeroForOne => Order[])) public orderPositions;
    mapping(PoolId => int24) public tickLowerLasts;

    event OrderPlaced(bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, uint256 triggerPrice);
    event OrderExecuted(bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, uint256 triggerPrice);

    // -- 1155 state -- //
    mapping(uint256 tokenId => TokenIdData) public tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public claimable;
    mapping(uint256 tokenId => uint256 supply) public totalSupply;

    struct TokenIdData {
        PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
    }

    constructor(
        IPoolManager _manager
    ) BaseHook(_manager) ERC1155() {}

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

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
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
    function placeOrder(OrderType orderType, uint256 amountIn, uint256 triggerPrice, PoolKey calldata poolKey, int24 tickLower) external returns (bytes32 orderId) {
        require(amountIn > 0, "Amount must be greater than 0");
        require(triggerPrice > 0, "Trigger price must be greater than 0");

        orderId = keccak256(abi.encodePacked(orderCount, msg.sender, block.timestamp));
        bool zeroForOne = (orderType == OrderType.BUY_STOP) || (orderType == OrderType.STOP_LOSS);
        orders[orderId] = Order(msg.sender, orderType, amountIn, triggerPrice, false, zeroForOne);
        int24 tick = getTickLower(tickLower, poolKey.tickSpacing);
        orderPositions[tick][zeroForOne].push(orders[orderId]);
        orderCount++;

        // Mint receipt token
        uint256 tokenId = getTokenId(poolKey, tick, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdIndex[tokenId] = TokenIdData({poolKey: poolKey, tickLower: tick, zeroForOne: zeroForOne});
        }
        _mint(msg.sender, tokenId, amountIn, "");
        totalSupply[tokenId] += amountIn;

        // Transfer token0 to this contract
        address token = zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
        emit OrderPlaced(orderId, msg.sender, orderType, amountIn, triggerPrice);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata data
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
                // TODO: Implement avs for order processing
                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; currentTick < tick;) {
                validOrders = orderPositions[tick][orderZeroForOne];
                // TODO: Implement avs for order processing
                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }
        return (AdvancedOrders.afterSwap.selector, tick); 
    }

    function performSwap(PoolKey memory key, IPoolManager.SwapParams memory params, address receiver)
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

    function getTokenId(PoolKey calldata poolKey, int24 tickLower, bool zeroForOne)
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
    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }
}
