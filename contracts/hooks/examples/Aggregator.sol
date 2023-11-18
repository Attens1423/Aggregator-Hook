// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {FeeLibrary} from "@uniswap/v4-core/contracts/libraries/FeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {BaseHook} from "../../BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "forge-std/Test.sol";

import "../../libraries/LiquidityAmounts.sol";

contract AggregatorHook is BaseHook, ILockCallback{
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;

    error SenderMustBeHook();
    error PriceDiffTooLarge();

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    int24 public tickLower;
    int24 public tickUpper;
    
    int256 public targetAmount;

    // record deposited into uni
    // todo maybe not necessary
    mapping(address => uint256) public depositedInPoolManager; 

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // Only for mocking
    function getAmountOut(
        uint256 fromAmount, 
        bool zeroForOne
    ) public returns(uint256 toAmount, int24 tickUp, int24 tickLow) {
        // todo change any price, current = 0.000921
        uint256 zeroForOneMockPrice = 9213376791555881;
        toAmount = zeroForOne ? 
            fromAmount * zeroForOneMockPrice / 1e18 :
            fromAmount * 1e36 / zeroForOneMockPrice;
        
        targetAmount = int256(toAmount);
        // calculate accrute tick
        uint160 midPriceSqrtQ = uint160(FullMath.mulDiv(Math.sqrt(zeroForOneMockPrice), Q96, 10 ** 9));
        tickLow = TickMath.getTickAtSqrtRatio(midPriceSqrtQ);
        tickUp = tickLow + 1;
    }

    function removeRemainingLiquidity(PoolKey calldata key) external {
        console.log("\n========= removeRemainingLiquidity ==========");
        PoolId poolId = key.toId();
        uint128 liquidity = poolManager.getLiquidity(poolId);

        _modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper, 
                liquidityDelta: -int128(liquidity)
            })
        );

        liquidity = poolManager.getLiquidity(poolId);
        console.log();
        console.log("after remove liq:", liquidity);

        (, int24 tick,,) = poolManager.getSlot0(poolId);
        console2.log("after remove tick:", tick);
    }

    // ------------ IHook ----------------

    // prevent user fill liquidity
    function beforeModifyPosition(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyPositionParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return AggregatorHook.beforeModifyPosition.selector;
    }

    // Add liquidity into pool before swap
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapData, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint256 fromAmount = uint256(swapData.amountSpecified);// decode swapParam
        bool zeroForOne = swapData.zeroForOne;
        uint256 toAmount;

        // query getAmountOut to generate fixed price
        (toAmount, tickUpper, tickLower) = getAmountOut(fromAmount, zeroForOne);

        {
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        console.log();
        console.log("round tick by tickSpacing:");
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);
        console2.log("slot0 tick:", tick);
        }

        // if zeroForOne, tick go up, from tickUpper to tickLower
        // if not, tick go down, from tickLower to tickUpper
        int24 calTick = zeroForOne ? tickUpper : tickLower;
        uint128 liquidity = _calJITLiquidity(calTick, fromAmount, toAmount, zeroForOne);
        console.log("before deposit:", liquidity);

        BalanceDelta delta = _modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int128(liquidity)
            })
        );

        depositedInPoolManager[token0] = uint128(delta.amount0());
        depositedInPoolManager[token1] = uint128(delta.amount1());

        return AggregatorHook.beforeSwap.selector;
    }

    // Remove all liquidity in pool after swap
    /// @notice since user transfer in after the whole swap in PoolSwapTest.sol, 
    /// actually it could not remove liquidty in afterSwap handle if filling liquidity
    /// accurately. So maybe it's no need to add afterSwap.
    /// In current condition, it only use to check price diff.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        uint128 liquidity = poolManager.getLiquidity(poolId);

        // todo fix this read balance, use poolManage
        uint256 balance0 = depositedInPoolManager[Currency.unwrap(key.currency0)];
        uint256 balance1 = depositedInPoolManager[Currency.unwrap(key.currency1)];

        (, int24 tick,,) = poolManager.getSlot0(poolId);

        uint24 fee = key.fee.getStaticFee();
        console.log("afterSwap fee:", fee);
        console2.log("delta amount1:", delta.amount1());
        console2.log("delta amount0:", delta.amount0());
        console.log("balance1:", balance1);
        console.log("balance0:", balance0);


        uint256 amount0;
        uint256 amount1;
        int256 priceDiff;

        if (delta.amount0() > 0 && delta.amount1() < 0) {
            amount0 = balance0 + uint128(delta.amount0())* (1000000 - fee) / 1000000; 
            amount1 = balance1 - uint128(-delta.amount1()) ;
            priceDiff = int256(targetAmount + delta.amount1()) * 1e18 / targetAmount;
        }

        if (delta.amount0() < 0 && delta.amount1() > 0) {
            amount0 = balance0 - uint128(-delta.amount0());
            amount1 = balance1 + uint128(delta.amount1()) * (1000000 - fee) / 1000000;
            priceDiff = int256(targetAmount + delta.amount0()) * 1e18 / targetAmount;
        }   
        if(uint256(priceDiff >= 0 ? priceDiff : -priceDiff) > 1e12) revert PriceDiffTooLarge();

        
        uint128 tickliquidity = poolManager.getLiquidity(poolId);
        console.log("all:", tickliquidity);
        
        /*
        _modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: -tickUpper,
                tickUpper: -tickLower,
                liquidityDelta: -int128(liquidity)
            })
        );
        
        */

        return AggregatorHook.afterSwap.selector;
    }

    // -------------- ILockCallback ----------------

    function lockAcquired(bytes calldata rawData)
        external
        override(ILockCallback, BaseHook)
        poolManagerOnly
        returns (bytes memory)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta <= 0) { //must contain 0
            delta = poolManager.modifyPosition(data.key, data.params, ZERO_BYTES);
            console.log("\ntake deltas");
            console2.log("delta amount0", delta.amount0());
            console2.log("delta amount1", delta.amount1());
            _takeDeltas(data.key, delta);
        } else {
            delta = poolManager.modifyPosition(data.key, data.params, ZERO_BYTES);
            console.log("\nsettle deltas");
            console2.log("delta amount0", delta.amount0());
            console2.log("delta amount1", delta.amount1());
            _settleDeltas(data.key, delta);
        }
        return abi.encode(delta);
    }

    // -------------- Internal Functions --------------

    function _calJITLiquidity(int24 curTick, uint256 fromAmount, uint256 toAmount, bool zeroForOne) internal view returns(uint128 liquidity) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(curTick);
        if(zeroForOne) {
            uint256 tmp1 = fromAmount * uint256(sqrtPriceX96) / Q96 *uint256(sqrtPriceX96) / Q96- toAmount;
            uint256 tmp2 = fromAmount * uint256(sqrtPriceX96) * toAmount / Q96;
            liquidity = uint128(tmp2 / tmp1);
        } else {

        }
    }

    function _modifyPosition(PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
    }

    function _settleDeltas(PoolKey memory key, BalanceDelta delta) internal {
        _settleDelta(key.currency0, uint128(delta.amount0()));
        _settleDelta(key.currency1, uint128(delta.amount1()));
    }

    function _settleDelta(Currency currency, uint128 amount) internal {
        if (currency.isNative()) {
            poolManager.settle{value: amount}(currency);
        } else {
            currency.transfer(address(poolManager), amount);
            poolManager.settle(currency);
        }
    }

    function _takeDeltas(PoolKey memory key, BalanceDelta delta) internal {
        uint256 amount0 = uint256(uint128(-delta.amount0()));
        uint256 amount1 = uint256(uint128(-delta.amount1()));
        poolManager.take(key.currency0, address(this), amount0);
        poolManager.take(key.currency1, address(this), amount1);
    }
}
