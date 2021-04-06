// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../LPToken.sol";
import "../interfaces/ISwap.sol";
import "../MathUtils.sol";
import "hardhat/console.sol";

/**
 * @title SwapUtils library
 * @notice A library to be used within Swap.sol. Contains functions responsible for custody and AMM functionalities.
 * @dev Contracts relying on this library must initialize SwapUtils.Swap struct then use this library
 * for SwapUtils.Swap struct. Note that this library contains both functions called by users and admins.
 * Admin functions should be protected within contracts using this library.
 */
library MetaSwapUtils {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using MathUtils for uint256;

    /*** EVENTS ***/

    event TokenSwap(
        address indexed buyer,
        uint256 tokensSold,
        uint256 tokensBought,
        uint128 soldId,
        uint128 boughtId
    );
    event TokenSwapUnderlying(
        address indexed buyer,
        uint256 tokensSold,
        uint256 tokensBought,
        uint128 soldId,
        uint128 boughtId
    );
    event AddLiquidity(
        address indexed provider,
        uint256[] tokenAmounts,
        uint256[] fees,
        uint256 invariant,
        uint256 lpTokenSupply
    );
    event RemoveLiquidity(
        address indexed provider,
        uint256[] tokenAmounts,
        uint256 lpTokenSupply
    );
    event RemoveLiquidityOne(
        address indexed provider,
        uint256 lpTokenAmount,
        uint256 lpTokenSupply,
        uint256 boughtId,
        uint256 tokensBought
    );
    event RemoveLiquidityImbalance(
        address indexed provider,
        uint256[] tokenAmounts,
        uint256[] fees,
        uint256 invariant,
        uint256 lpTokenSupply
    );
    event NewAdminFee(uint256 newAdminFee);
    event NewSwapFee(uint256 newSwapFee);
    event NewWithdrawFee(uint256 newWithdrawFee);
    event RampA(
        uint256 oldA,
        uint256 newA,
        uint256 initialTime,
        uint256 futureTime
    );
    event StopRampA(uint256 currentA, uint256 time);

    struct Swap {
        // variables around the ramp management of A,
        // the amplification coefficient * n * (n - 1)
        // see https://www.curve.fi/stableswap-paper.pdf for details
        uint256 initialA;
        uint256 futureA;
        uint256 initialATime;
        uint256 futureATime;
        // fee calculation
        uint256 swapFee;
        uint256 adminFee;
        uint256 defaultWithdrawFee;
        LPToken lpToken;
        // contract references for all tokens being pooled
        IERC20[] pooledTokens;
        // multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS
        // for example, TBTC has 18 decimals, so the multiplier should be 1. WBTC
        // has 8, so the multiplier should be 10 ** 18 / 10 ** 8 => 10 ** 10
        uint256[] tokenPrecisionMultipliers;
        // the pool balance of each token, in the token's precision
        // the contract's actual token balance might differ
        uint256[] balances;
        mapping(address => uint256) depositTimestamp;
        mapping(address => uint256) withdrawFeeMultiplier;
        // Meta-Swap related parameters
        ISwap baseSwap;
        uint256 baseVirtualPrice;
        uint256 baseCacheLastUpdated;
        IERC20[] baseTokens;
    }

    // Struct storing variables used in calculations in the
    // calculateWithdrawOneTokenDY function to avoid stack too deep errors
    struct CalculateWithdrawOneTokenDYInfo {
        uint256 d0;
        uint256 d1;
        uint256 newY;
        uint256 feePerToken;
        uint256 preciseA;
    }

    // Struct storing variables used in calculation in addLiquidity function
    // to avoid stack too deep error
    struct AddLiquidityInfo {
        uint256 d0;
        uint256 d1;
        uint256 d2;
        uint256 preciseA;
    }

    // Struct storing variables used in calculation in removeLiquidityImbalance function
    // to avoid stack too deep error
    struct RemoveLiquidityImbalanceInfo {
        uint256 d0;
        uint256 d1;
        uint256 d2;
        uint256 preciseA;
        uint256 baseVirtualPrice;
    }

    struct SwapUnderlyingInfo {
        uint256 x;
        uint256 dx;
        uint256 dy;
        uint8 metaIndexFrom;
        uint8 metaIndexTo;
        uint256[] oldBalances;
        IERC20[] baseTokens;
        IERC20 tokenFrom;
        IERC20 tokenTo;
    }

    struct CalculateSwapUnderlyingInfo {
        uint256 baseVirtualPrice;
        ISwap baseSwap;
        uint8 baseLPTokenIndex;
        uint8 baseTokensLength;
        uint256 x;
        uint256 dy;
    }

    // the precision all pools tokens will be converted to
    uint8 public constant POOL_PRECISION_DECIMALS = 18;

    // the denominator used to calculate admin and LP fees. For example, an
    // LP fee might be something like tradeAmount.mul(fee).div(FEE_DENOMINATOR)
    uint256 private constant FEE_DENOMINATOR = 10**10;

    // Max swap fee is 1% or 100bps of each swap
    uint256 public constant MAX_SWAP_FEE = 10**8;

    // Max adminFee is 100% of the swapFee
    // adminFee does not add additional fee on top of swapFee
    // Instead it takes a certain % of the swapFee. Therefore it has no impact on the
    // users but only on the earnings of LPs
    uint256 public constant MAX_ADMIN_FEE = 10**10;

    // Max withdrawFee is 1% of the value withdrawn
    // Fee will be redistributed to the LPs in the pool, rewarding
    // long term providers.
    uint256 public constant MAX_WITHDRAW_FEE = 10**8;

    // Constant value used as max loop limit
    uint256 private constant MAX_LOOP_LIMIT = 256;

    // Constant values used in ramping A calculations
    uint256 public constant A_PRECISION = 100;
    uint256 public constant MAX_A = 10**6;
    uint256 private constant MAX_A_CHANGE = 2;
    uint256 private constant MIN_RAMP_TIME = 14 days;

    uint256 public constant BASE_CACHE_EXPIRE_TIME = 10 minutes;
    uint256 public constant BASE_VIRTUAL_PRICE_PRECISION = 10**18;

    /*** VIEW & PURE FUNCTIONS ***/

    /**
     * @notice Return A, the amplification coefficient * n * (n - 1)
     * @dev See the StableSwap paper for details
     * @param self Swap struct to read from
     * @return A parameter
     */
    function getA(Swap storage self) external view returns (uint256) {
        return _getA(self);
    }

    /**
     * @notice Return A, the amplification coefficient * n * (n - 1)
     * @dev See the StableSwap paper for details
     * @param self Swap struct to read from
     * @return A parameter
     */
    function _getA(Swap storage self) internal view returns (uint256) {
        return _getAPrecise(self).div(A_PRECISION);
    }

    /**
     * @notice Return A in its raw precision
     * @dev See the StableSwap paper for details
     * @param self Swap struct to read from
     * @return A parameter in its raw precision form
     */
    function getAPrecise(Swap storage self) external view returns (uint256) {
        return _getAPrecise(self);
    }

    /**
     * @notice Calculates and returns A based on the ramp settings
     * @dev See the StableSwap paper for details
     * @param self Swap struct to read from
     * @return A parameter in its raw precision form
     */
    function _getAPrecise(Swap storage self) internal view returns (uint256) {
        uint256 t1 = self.futureATime; // time when ramp is finished
        uint256 a1 = self.futureA; // final A value when ramp is finished

        if (block.timestamp < t1) {
            uint256 t0 = self.initialATime; // time when ramp is started
            uint256 a0 = self.initialA; // initial A value when ramp is started
            if (a1 > a0) {
                // a0 + (a1 - a0) * (block.timestamp - t0) / (t1 - t0)
                return
                    a0.add(
                        a1.sub(a0).mul(block.timestamp.sub(t0)).div(t1.sub(t0))
                    );
            } else {
                // a0 - (a0 - a1) * (block.timestamp - t0) / (t1 - t0)
                return
                    a0.sub(
                        a0.sub(a1).mul(block.timestamp.sub(t0)).div(t1.sub(t0))
                    );
            }
        } else {
            return a1;
        }
    }

    function _updateBaseVirtualPrice(Swap storage self)
        internal
        returns (uint256)
    {
        if (
            block.timestamp > self.baseCacheLastUpdated + BASE_CACHE_EXPIRE_TIME
        ) {
            uint256 baseVirtualPrice = ISwap(self.baseSwap).getVirtualPrice();
            self.baseVirtualPrice = baseVirtualPrice;
            self.baseCacheLastUpdated = block.timestamp;
            return baseVirtualPrice;
        } else {
            return self.baseVirtualPrice;
        }
    }

    function _getBaseVirtualPrice(Swap storage self)
        internal
        view
        returns (uint256)
    {
        if (
            block.timestamp > self.baseCacheLastUpdated + BASE_CACHE_EXPIRE_TIME
        ) {
            return ISwap(self.baseSwap).getVirtualPrice();
        } else {
            return self.baseVirtualPrice;
        }
    }

    /**
     * @notice Retrieves the timestamp of last deposit made by the given address
     * @param self Swap struct to read from
     * @return timestamp of last deposit
     */
    function getDepositTimestamp(Swap storage self, address user)
        external
        view
        returns (uint256)
    {
        return self.depositTimestamp[user];
    }

    /**
     * @notice Calculate the dy, the amount of selected token that user receives.
     * @param account the address that is withdrawing
     * @param tokenAmount the amount to withdraw in the pool's precision
     * @param tokenIndex which token will be withdrawn
     * @param self Swap struct to read from
     * @return dy the amount of token user will receive
     */
    function calculateWithdrawOneToken(
        Swap storage self,
        address account,
        uint256 tokenAmount,
        uint8 tokenIndex
    ) external view returns (uint256 dy) {
        (dy, ) = calculateWithdrawOneToken(
            self,
            account,
            tokenAmount,
            tokenIndex,
            _getBaseVirtualPrice(self)
        );
    }

    function calculateWithdrawOneToken(
        Swap storage self,
        address account,
        uint256 tokenAmount,
        uint8 tokenIndex,
        uint256 baseVirtualPrice
    ) internal view returns (uint256, uint256) {
        uint256 dy;
        uint256 dySwapFee;

        {
            uint256 y;
            uint256 newY;

            (dy, newY) = calculateWithdrawOneTokenDY(
                self,
                tokenIndex,
                tokenAmount,
                baseVirtualPrice
            );

            // dy_0 (without fees)
            // dy, dy_0 - dy
            y = _xp(self, baseVirtualPrice)[tokenIndex];

            dySwapFee = y
                .sub(newY)
                .div(self.tokenPrecisionMultipliers[tokenIndex])
                .sub(dy);
        }

        dy = dy
            .mul(
            FEE_DENOMINATOR.sub(calculateCurrentWithdrawFee(self, account))
        )
            .div(FEE_DENOMINATOR);

        return (dy, dySwapFee);
    }

    /**
     * @notice Calculate the dy of withdrawing in one token
     * @param self Swap struct to read from
     * @param tokenIndex which token will be withdrawn
     * @param tokenAmount the amount to withdraw in the pools precision
     * @return the d and the new y after withdrawing one token
     */
    function calculateWithdrawOneTokenDY(
        Swap storage self,
        uint8 tokenIndex,
        uint256 tokenAmount,
        uint256 baseVirtualPrice
    ) internal view returns (uint256, uint256) {
        require(
            tokenIndex < self.pooledTokens.length,
            "Token index out of range"
        );

        // Get the current D, then solve the stableswap invariant
        // y_i for D - tokenAmount
        uint256[] memory xp = _xp(self, baseVirtualPrice);
        CalculateWithdrawOneTokenDYInfo memory v =
            CalculateWithdrawOneTokenDYInfo(0, 0, 0, 0, 0);
        v.preciseA = _getAPrecise(self);
        v.d0 = getD(xp, v.preciseA);
        v.d1 = v.d0.sub(tokenAmount.mul(v.d0).div(self.lpToken.totalSupply()));

        require(tokenAmount <= xp[tokenIndex], "Withdraw exceeds available");

        v.newY = getYD(v.preciseA, tokenIndex, xp, v.d1);

        uint256[] memory xpReduced = new uint256[](xp.length);

        v.feePerToken = _feePerToken(self);
        for (uint256 i = 0; i < self.pooledTokens.length; i++) {
            uint256 xpi = xp[i];
            // if i == tokenIndex, dxExpected = xp[i] * d1 / d0 - newY
            // else dxExpected = xp[i] - (xp[i] * d1 / d0)
            // xpReduced[i] -= dxExpected * fee / FEE_DENOMINATOR
            xpReduced[i] = xpi.sub(
                (
                    (i == tokenIndex)
                        ? xpi.mul(v.d1).div(v.d0).sub(v.newY)
                        : xpi.sub(xpi.mul(v.d1).div(v.d0))
                )
                    .mul(v.feePerToken)
                    .div(FEE_DENOMINATOR)
            );
        }

        uint256 dy =
            xpReduced[tokenIndex].sub(
                getYD(v.preciseA, tokenIndex, xpReduced, v.d1)
            );
        dy = dy.sub(1).div(self.tokenPrecisionMultipliers[tokenIndex]);

        if (tokenIndex == xp.length - 1) {
            dy = dy.mul(BASE_VIRTUAL_PRICE_PRECISION).div(baseVirtualPrice);
        }

        return (dy, v.newY);
    }

    /**
     * @notice Calculate the price of a token in the pool with given
     * precision-adjusted balances and a particular D.
     *
     * @dev This is accomplished via solving the invariant iteratively.
     * See the StableSwap paper and Curve.fi implementation for further details.
     *
     * x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
     * x_1**2 + b*x_1 = c
     * x_1 = (x_1**2 + c) / (2*x_1 + b)
     *
     * @param a the amplification coefficient * n * (n - 1). See the StableSwap paper for details.
     * @param tokenIndex Index of token we are calculating for.
     * @param xp a precision-adjusted set of pool balances. Array should be
     * the same cardinality as the pool.
     * @param d the stableswap invariant
     * @return the price of the token, in the same precision as in xp
     */
    function getYD(
        uint256 a,
        uint8 tokenIndex,
        uint256[] memory xp,
        uint256 d
    ) internal pure returns (uint256) {
        uint256 numTokens = xp.length;
        require(tokenIndex < numTokens, "Token not found");

        uint256 c = d;
        uint256 s;
        uint256 nA = a.mul(numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            if (i != tokenIndex) {
                s = s.add(xp[i]);
                c = c.mul(d).div(xp[i].mul(numTokens));
                // If we were to protect the division loss we would have to keep the denominator separate
                // and divide at the end. However this leads to overflow with large numTokens or/and D.
                // c = c * D * D * D * ... overflow!
            }
        }
        c = c.mul(d).mul(A_PRECISION).div(nA.mul(numTokens));

        uint256 b = s.add(d.mul(A_PRECISION).div(nA));
        uint256 yPrev;
        uint256 y = d;
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            yPrev = y;
            y = y.mul(y).add(c).div(y.mul(2).add(b).sub(d));
            if (y.within1(yPrev)) {
                return y;
            }
        }
        revert("Approximation did not converge");
    }

    /**
     * @notice Get D, the StableSwap invariant, based on a set of balances and a particular A.
     * @param xp a precision-adjusted set of pool balances. Array should be the same cardinality
     * as the pool.
     * @param a the amplification coefficient * n * (n - 1) in A_PRECISION.
     * See the StableSwap paper for details
     * @return the invariant, at the precision of the pool
     */
    function getD(uint256[] memory xp, uint256 a)
        internal
        pure
        returns (uint256)
    {
        uint256 numTokens = xp.length;
        uint256 s;
        for (uint256 i = 0; i < numTokens; i++) {
            s = s.add(xp[i]);
        }
        if (s == 0) {
            return 0;
        }

        uint256 prevD;
        uint256 d = s;
        uint256 nA = a.mul(numTokens);

        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            uint256 dP = d;
            for (uint256 j = 0; j < numTokens; j++) {
                dP = dP.mul(d).div(xp[j].mul(numTokens));
                // If we were to protect the division loss we would have to keep the denominator separate
                // and divide at the end. However this leads to overflow with large numTokens or/and D.
                // dP = dP * D * D * D * ... overflow!
            }
            prevD = d;
            d = nA.mul(s).div(A_PRECISION).add(dP.mul(numTokens)).mul(d).div(
                nA.sub(A_PRECISION).mul(d).div(A_PRECISION).add(
                    numTokens.add(1).mul(dP)
                )
            );
            if (d.within1(prevD)) {
                return d;
            }
        }

        // Convergence should occur in 4 loops or less. If this is reached, there may be something wrong
        // with the pool. If this were to occur repeatedly, LPs should withdraw via `removeLiquidity()`
        // function which does not rely on D.
        revert("D does not converge");
    }

    /**
     * @notice Given a set of balances and precision multipliers, return the
     * precision-adjusted balances.
     *
     * @param balances an array of token balances, in their native precisions.
     * These should generally correspond with pooled tokens.
     *
     * @param precisionMultipliers an array of multipliers, corresponding to
     * the amounts in the balances array. When multiplied together they
     * should yield amounts at the pool's precision.
     *
     * @return an array of amounts "scaled" to the pool's precision
     */
    function _xp(
        uint256[] memory balances,
        uint256[] memory precisionMultipliers,
        uint256 baseVirtualPrice
    ) internal pure returns (uint256[] memory) {
        uint256 numTokens = balances.length;
        require(
            numTokens == precisionMultipliers.length,
            "Balances must match multipliers"
        );
        uint256[] memory xp = new uint256[](numTokens);
        for (uint256 i = 0; i < numTokens; i++) {
            xp[i] = balances[i].mul(precisionMultipliers[i]);
        }
        uint256 baseLPTokenIndex = numTokens - 1;
        xp[baseLPTokenIndex] = xp[baseLPTokenIndex].mul(baseVirtualPrice).div(
            BASE_VIRTUAL_PRICE_PRECISION
        );
        return xp;
    }

    /**
     * @notice Return the precision-adjusted balances of all tokens in the pool
     * @param self Swap struct to read from
     * @param balances array of balances to scale
     * @return balances array "scaled" to the pool's precision, allowing
     * them to be more easily compared.
     */
    function _xp(
        Swap storage self,
        uint256[] memory balances,
        uint256 baseVirtualPrice
    ) internal view returns (uint256[] memory) {
        return _xp(balances, self.tokenPrecisionMultipliers, baseVirtualPrice);
    }

    /**
     * @notice Return the precision-adjusted balances of all tokens in the pool
     * @param self Swap struct to read from
     * @return the pool balances "scaled" to the pool's precision, allowing
     * them to be more easily compared.
     */
    function _xp(Swap storage self, uint256 baseVirtualPrice)
        internal
        view
        returns (uint256[] memory)
    {
        return
            _xp(
                self.balances,
                self.tokenPrecisionMultipliers,
                baseVirtualPrice
            );
    }

    /**
     * @notice Get the virtual price, to help calculate profit
     * @param self Swap struct to read from
     * @return the virtual price, scaled to precision of POOL_PRECISION_DECIMALS
     */
    function getVirtualPrice(Swap storage self)
        external
        view
        returns (uint256)
    {
        uint256 d =
            getD(_xp(self, _getBaseVirtualPrice(self)), _getAPrecise(self));
        uint256 supply = self.lpToken.totalSupply();
        if (supply != 0) {
            return
                d.mul(10**uint256(ERC20(self.lpToken).decimals())).div(supply);
        }
        return 0;
    }

    /**
     * @notice Calculate the new balances of the tokens given the indexes of the token
     * that is swapped from (FROM) and the token that is swapped to (TO).
     * This function is used as a helper function to calculate how much TO token
     * the user should receive on swap.
     *
     * @param self Swap struct to read from
     * @param tokenIndexFrom index of FROM token
     * @param tokenIndexTo index of TO token
     * @param x the new total amount of FROM token
     * @param xp balances of the tokens in the pool
     * @return the amount of TO token that should remain in the pool
     */
    function getY(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 x,
        uint256[] memory xp
    ) internal view returns (uint256) {
        uint256 numTokens = self.pooledTokens.length;
        require(
            tokenIndexFrom != tokenIndexTo,
            "Can't compare token to itself"
        );
        require(
            tokenIndexFrom < numTokens && tokenIndexTo < numTokens,
            "Tokens must be in pool"
        );

        uint256 a = _getAPrecise(self);
        uint256 d = getD(xp, a);
        uint256 c = d;
        uint256 s;
        uint256 nA = numTokens.mul(a);

        uint256 _x;
        for (uint256 i = 0; i < numTokens; i++) {
            if (i == tokenIndexFrom) {
                _x = x;
            } else if (i != tokenIndexTo) {
                _x = xp[i];
            } else {
                continue;
            }
            s = s.add(_x);
            c = c.mul(d).div(_x.mul(numTokens));
            // If we were to protect the division loss we would have to keep the denominator separate
            // and divide at the end. However this leads to overflow with large numTokens or/and D.
            // c = c * D * D * D * ... overflow!
        }
        c = c.mul(d).mul(A_PRECISION).div(nA.mul(numTokens));
        uint256 b = s.add(d.mul(A_PRECISION).div(nA));
        uint256 yPrev;
        uint256 y = d;

        // iterative approximation
        for (uint256 i = 0; i < MAX_LOOP_LIMIT; i++) {
            yPrev = y;
            y = y.mul(y).add(c).div(y.mul(2).add(b).sub(d));
            if (y.within1(yPrev)) {
                return y;
            }
        }
        revert("Approximation did not converge");
    }

    /**
     * @notice Externally calculates a swap between two tokens.
     * @param self Swap struct to read from
     * @param tokenIndexFrom the token to sell
     * @param tokenIndexTo the token to buy
     * @param dx the number of tokens to sell. If the token charges a fee on transfers,
     * use the amount that gets transferred after the fee.
     * @return dy the number of tokens the user will get
     */
    function calculateSwap(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx
    ) external view returns (uint256 dy) {
        (dy, ) = _calculateSwap(self, tokenIndexFrom, tokenIndexTo, dx);
    }

    /**
     * @notice Internally calculates a swap between two tokens.
     *
     * @dev The caller is expected to transfer the actual amounts (dx and dy)
     * using the token contracts.
     *
     * @param self Swap struct to read from
     * @param tokenIndexFrom the token to sell
     * @param tokenIndexTo the token to buy
     * @param dx the number of tokens to sell. If the token charges a fee on transfers,
     * use the amount that gets transferred after the fee.
     * @return dy the number of tokens the user will get
     * @return dyFee the associated fee
     */
    function _calculateSwap(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx
    ) internal view returns (uint256 dy, uint256 dyFee) {
        uint256[] memory xp = _xp(self, _getBaseVirtualPrice(self));
        require(
            tokenIndexFrom < xp.length && tokenIndexTo < xp.length,
            "Token index out of range"
        );
        uint256 x =
            dx.mul(self.tokenPrecisionMultipliers[tokenIndexFrom]).add(
                xp[tokenIndexFrom]
            );
        uint256 y = getY(self, tokenIndexFrom, tokenIndexTo, x, xp);
        dy = xp[tokenIndexTo].sub(y).sub(1);
        dyFee = dy.mul(self.swapFee).div(FEE_DENOMINATOR);
        dy = dy.sub(dyFee).div(self.tokenPrecisionMultipliers[tokenIndexTo]);
    }

    function calculateSwapUnderlying(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx
    ) external view returns (uint256) {
        CalculateSwapUnderlyingInfo memory v =
            CalculateSwapUnderlyingInfo(
                _getBaseVirtualPrice(self),
                self.baseSwap,
                0,
                uint8(self.baseTokens.length),
                0,
                0
            );

        uint256[] memory xp = _xp(self, v.baseVirtualPrice);
        v.baseLPTokenIndex = uint8(xp.length) - 1;
        {
            uint8 maxRange = v.baseLPTokenIndex + v.baseTokensLength;
            require(
                tokenIndexFrom < maxRange && tokenIndexTo < maxRange,
                "Token index out of range"
            );
        }

        if (tokenIndexFrom < v.baseLPTokenIndex) {
            // tokenFrom is from this pool
            v.x = xp[tokenIndexFrom].add(
                dx.mul(self.tokenPrecisionMultipliers[tokenIndexFrom])
            );
        } else {
            // tokenFrom is from the base pool
            tokenIndexFrom = tokenIndexFrom - v.baseLPTokenIndex;
            if (tokenIndexTo < v.baseLPTokenIndex) {
                uint256[] memory baseInputs = new uint256[](v.baseTokensLength);
                baseInputs[tokenIndexFrom] = dx;
                v.x = v
                    .baseSwap
                    .calculateTokenAmount(address(this), baseInputs, true)
                    .mul(v.baseVirtualPrice)
                    .div(BASE_VIRTUAL_PRICE_PRECISION)
                    .add(xp[v.baseLPTokenIndex]);
            } else {
                // both from and to are from the base pool
                return
                    v.baseSwap.calculateSwap(
                        tokenIndexFrom,
                        tokenIndexTo - v.baseLPTokenIndex,
                        dx
                    );
            }
            tokenIndexFrom = v.baseLPTokenIndex;
        }

        uint8 metaIndexTo = v.baseLPTokenIndex;
        if (tokenIndexTo < v.baseLPTokenIndex) {
            metaIndexTo = tokenIndexTo;
        }

        {
            uint256 y = getY(self, tokenIndexFrom, metaIndexTo, v.x, xp);
            v.dy = xp[metaIndexTo].sub(y).sub(1);
            uint256 dyFee = v.dy.mul(self.swapFee).div(FEE_DENOMINATOR);
            v.dy = v.dy.sub(dyFee);
        }

        if (tokenIndexTo < v.baseLPTokenIndex) {
            // tokenTo is from this pool
            v.dy = v.dy.div(self.tokenPrecisionMultipliers[metaIndexTo]);
        } else {
            // tokenTo is from the base pool
            v.dy = v.baseSwap.calculateRemoveLiquidityOneToken(
                address(this),
                v.dy.mul(BASE_VIRTUAL_PRICE_PRECISION).div(v.baseVirtualPrice),
                tokenIndexTo - v.baseLPTokenIndex
            );
        }

        return v.dy;
    }

    /**
     * @notice A simple method to calculate amount of each underlying
     * tokens that is returned upon burning given amount of
     * LP tokens
     *
     * @param account the address that is removing liquidity. required for withdraw fee calculation
     * @param amount the amount of LP tokens that would to be burned on
     * withdrawal
     * @return array of amounts of tokens user will receive
     */
    function calculateRemoveLiquidity(
        Swap storage self,
        address account,
        uint256 amount
    ) external view returns (uint256[] memory) {
        return _calculateRemoveLiquidity(self, account, amount);
    }

    function _calculateRemoveLiquidity(
        Swap storage self,
        address account,
        uint256 amount
    ) internal view returns (uint256[] memory) {
        uint256 totalSupply = self.lpToken.totalSupply();
        require(amount <= totalSupply, "Cannot exceed total supply");

        uint256 feeAdjustedAmount =
            amount
                .mul(
                FEE_DENOMINATOR.sub(calculateCurrentWithdrawFee(self, account))
            )
                .div(FEE_DENOMINATOR);

        uint256[] memory amounts = new uint256[](self.pooledTokens.length);

        for (uint256 i = 0; i < self.pooledTokens.length; i++) {
            amounts[i] = self.balances[i].mul(feeAdjustedAmount).div(
                totalSupply
            );
        }
        return amounts;
    }

    /**
     * @notice Calculate the fee that is applied when the given user withdraws.
     * Withdraw fee decays linearly over 4 weeks.
     * @param user address you want to calculate withdraw fee of
     * @return current withdraw fee of the user
     */
    function calculateCurrentWithdrawFee(Swap storage self, address user)
        public
        view
        returns (uint256)
    {
        uint256 endTime = self.depositTimestamp[user].add(4 weeks);
        if (endTime > block.timestamp) {
            uint256 timeLeftover = endTime.sub(block.timestamp);
            return
                self
                    .defaultWithdrawFee
                    .mul(self.withdrawFeeMultiplier[user])
                    .mul(timeLeftover)
                    .div(4 weeks)
                    .div(FEE_DENOMINATOR);
        }
        return 0;
    }

    /**
     * @notice A simple method to calculate prices from deposits or
     * withdrawals, excluding fees but including slippage. This is
     * helpful as an input into the various "min" parameters on calls
     * to fight front-running
     *
     * @dev This shouldn't be used outside frontends for user estimates.
     *
     * @param self Swap struct to read from
     * @param account address of the account depositing or withdrawing tokens
     * @param amounts an array of token amounts to deposit or withdrawal,
     * corresponding to pooledTokens. The amount should be in each
     * pooled token's native precision. If a token charges a fee on transfers,
     * use the amount that gets transferred after the fee.
     * @param deposit whether this is a deposit or a withdrawal
     * @return if deposit was true, total amount of lp token that will be minted and if
     * deposit was false, total amount of lp token that will be burned
     */
    function calculateTokenAmount(
        Swap storage self,
        address account,
        uint256[] calldata amounts,
        bool deposit
    ) external view returns (uint256) {
        uint256 numTokens = self.pooledTokens.length;
        uint256 a = _getAPrecise(self);
        uint256 baseVirtualPrice = _getBaseVirtualPrice(self);
        uint256[] memory balances1 = self.balances;
        uint256 d0 = getD(_xp(self, balances1, baseVirtualPrice), a);
        for (uint256 i = 0; i < numTokens; i++) {
            if (deposit) {
                balances1[i] = balances1[i].add(amounts[i]);
            } else {
                balances1[i] = balances1[i].sub(
                    amounts[i],
                    "Cannot withdraw more than available"
                );
            }
        }
        uint256 d1 = getD(_xp(self, balances1, baseVirtualPrice), a);
        uint256 totalSupply = self.lpToken.totalSupply();

        if (deposit) {
            return d1.sub(d0).mul(totalSupply).div(d0);
        } else {
            return
                d0.sub(d1).mul(totalSupply).div(d0).mul(FEE_DENOMINATOR).div(
                    FEE_DENOMINATOR.sub(
                        calculateCurrentWithdrawFee(self, account)
                    )
                );
        }
    }

    /**
     * @notice return accumulated amount of admin fees of the token with given index
     * @param self Swap struct to read from
     * @param index Index of the pooled token
     * @return admin balance in the token's precision
     */
    function getAdminBalance(Swap storage self, uint256 index)
        external
        view
        returns (uint256)
    {
        require(index < self.pooledTokens.length, "Token index out of range");
        return
            self.pooledTokens[index].balanceOf(address(this)).sub(
                self.balances[index]
            );
    }

    /**
     * @notice internal helper function to calculate fee per token multiplier used in
     * swap fee calculations
     * @param self Swap struct to read from
     */
    function _feePerToken(Swap storage self) internal view returns (uint256) {
        return
            self.swapFee.mul(self.pooledTokens.length).div(
                self.pooledTokens.length.sub(1).mul(4)
            );
    }

    /*** STATE MODIFYING FUNCTIONS ***/

    /**
     * @notice swap two tokens in the pool
     * @param self Swap struct to read from and write to
     * @param tokenIndexFrom the token the user wants to sell
     * @param tokenIndexTo the token the user wants to buy
     * @param dx the amount of tokens the user wants to sell
     * @param minDy the min amount the user would like to receive, or revert.
     * @return amount of token user received on swap
     */
    function swap(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256 minDy
    ) external returns (uint256) {
        require(
            dx <= self.pooledTokens[tokenIndexFrom].balanceOf(msg.sender),
            "Cannot swap more than you own"
        );

        // Transfer tokens first to see if a fee was charged on transfer
        uint256 beforeBalance =
            self.pooledTokens[tokenIndexFrom].balanceOf(address(this));
        self.pooledTokens[tokenIndexFrom].safeTransferFrom(
            msg.sender,
            address(this),
            dx
        );

        // Use the actual transferred amount for AMM math
        uint256 transferredDx =
            self.pooledTokens[tokenIndexFrom].balanceOf(address(this)).sub(
                beforeBalance
            );

        (uint256 dy, uint256 dyFee) =
            _calculateSwap(self, tokenIndexFrom, tokenIndexTo, transferredDx);
        require(dy >= minDy, "Swap didn't result in min tokens");

        uint256 dyAdminFee =
            dyFee.mul(self.adminFee).div(FEE_DENOMINATOR).div(
                self.tokenPrecisionMultipliers[tokenIndexTo]
            );

        self.balances[tokenIndexFrom] = self.balances[tokenIndexFrom].add(
            transferredDx
        );
        self.balances[tokenIndexTo] = self.balances[tokenIndexTo].sub(dy).sub(
            dyAdminFee
        );

        self.pooledTokens[tokenIndexTo].safeTransfer(msg.sender, dy);

        emit TokenSwap(
            msg.sender,
            transferredDx,
            dy,
            tokenIndexFrom,
            tokenIndexTo
        );

        return dy;
    }

    function swapUnderlying(
        Swap storage self,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256 minDy
    ) external returns (uint256) {
        SwapUnderlyingInfo memory v =
            SwapUnderlyingInfo(
                0,
                0,
                0,
                0,
                0,
                self.balances,
                self.baseTokens,
                IERC20(address(0)),
                IERC20(address(0))
            );

        uint256 baseVirtualPrice = _getBaseVirtualPrice(self);
        uint8 baseLPTokenIndex = uint8(v.oldBalances.length) - 1;

        {
            uint8 maxRange = baseLPTokenIndex + uint8(v.baseTokens.length);
            require(
                tokenIndexFrom < maxRange && tokenIndexTo < maxRange,
                "Token index out of range"
            );
        }

        ISwap baseSwap = self.baseSwap;

        // Find the address of the token swapping from
        if (tokenIndexFrom < baseLPTokenIndex) {
            v.tokenFrom = self.pooledTokens[tokenIndexFrom];
            v.metaIndexFrom = tokenIndexFrom;
        } else {
            v.tokenFrom = v.baseTokens[tokenIndexFrom - baseLPTokenIndex];
            v.metaIndexFrom = baseLPTokenIndex;
        }

        // Find the address of the token swapping to
        if (tokenIndexTo < baseLPTokenIndex) {
            v.tokenTo = self.pooledTokens[tokenIndexTo];
            v.metaIndexTo = tokenIndexTo;
        } else {
            v.tokenTo = v.baseTokens[tokenIndexTo - baseLPTokenIndex];
            v.metaIndexTo = baseLPTokenIndex;
        }

        v.tokenFrom.safeTransferFrom(msg.sender, address(this), dx);
        v.dx = v.tokenFrom.balanceOf(address(this));

        if (
            tokenIndexFrom < baseLPTokenIndex || tokenIndexTo < baseLPTokenIndex
        ) {
            uint256[] memory xp = _xp(self, v.oldBalances, baseVirtualPrice);

            if (tokenIndexFrom < baseLPTokenIndex) {
                v.x =
                    xp[tokenIndexFrom] +
                    dx.mul(self.tokenPrecisionMultipliers[tokenIndexFrom]);
            } else {
                // tokenFrom is in the base pool
                uint256[] memory baseAmounts =
                    new uint256[](v.baseTokens.length);
                baseAmounts[tokenIndexFrom - baseLPTokenIndex] = v.dx;
                IERC20 baseLPToken = self.pooledTokens[baseLPTokenIndex];
                v.x = baseLPToken.balanceOf(address(this));
                // Add liquidity to the underlying swap contract
                baseSwap.addLiquidity(baseAmounts, 0, block.timestamp);
                // Now we have more of the base LP token
                v.dx = baseLPToken.balanceOf(address(this)).sub(v.x);
                v.x = v
                    .dx
                    .mul(baseVirtualPrice)
                    .div(BASE_VIRTUAL_PRICE_PRECISION)
                    .add(xp[baseLPTokenIndex]);
            }

            uint256 dyFee;
            {
                uint256 y = getY(self, v.metaIndexFrom, v.metaIndexTo, v.x, xp);
                v.dy = xp[v.metaIndexTo].sub(y).sub(1);
                dyFee = v.dy.mul(self.swapFee).div(FEE_DENOMINATOR);
                v.dy = v.dy.sub(dyFee);
            }

            if (tokenIndexTo >= baseLPTokenIndex) {
                v.dy = v.dy.mul(BASE_VIRTUAL_PRICE_PRECISION).div(
                    baseVirtualPrice
                );
            }
            v.dy = v.dy.mul(self.tokenPrecisionMultipliers[v.metaIndexTo]);

            {
                uint256 dyAdminFee =
                    dyFee.mul(self.adminFee).div(FEE_DENOMINATOR);
                self.balances[v.metaIndexFrom] = v.oldBalances[v.metaIndexFrom]
                    .add(v.dx);
                self.balances[v.metaIndexTo] = v.oldBalances[v.metaIndexTo]
                    .sub(v.dy)
                    .sub(dyAdminFee);
            }

            if (tokenIndexTo >= baseLPTokenIndex) {
                // tokenTo is from the base pool
                // burn the LP token and withdraw the desired token from the base pool
                uint256 oldBalance = v.tokenTo.balanceOf(address(this));
                baseSwap.removeLiquidityOneToken(
                    v.dy,
                    tokenIndexTo - baseLPTokenIndex,
                    0,
                    block.timestamp
                );
                v.dy = v.tokenTo.balanceOf(address(this)) - oldBalance;
            }
        } else {
            // Both tokens are from the base swap pool
            v.dy = v.tokenTo.balanceOf(address(this));
            baseSwap.swap(
                tokenIndexFrom - baseLPTokenIndex,
                tokenIndexTo - baseLPTokenIndex,
                dx,
                minDy,
                block.timestamp
            );
            v.dy = v.tokenTo.balanceOf(address(this)).sub(v.dy);
        }

        require(v.dy >= minDy, "Swap didn't result in min tokens");

        v.tokenTo.safeTransfer(msg.sender, v.dy);

        emit TokenSwapUnderlying(
            msg.sender,
            dx,
            v.dy,
            tokenIndexFrom,
            tokenIndexTo
        );

        return v.dy;
    }

    /**
     * @notice Add liquidity to the pool
     * @param self Swap struct to read from and write to
     * @param amounts the amounts of each token to add, in their native precision
     * @param minToMint the minimum LP tokens adding this amount of liquidity
     * should mint, otherwise revert. Handy for front-running mitigation
     * allowed addresses. If the pool is not in the guarded launch phase, this parameter will be ignored.
     * @return amount of LP token user received
     */
    function addLiquidity(
        Swap storage self,
        uint256[] memory amounts,
        uint256 minToMint
    ) external returns (uint256) {
        require(
            amounts.length == self.pooledTokens.length,
            "Amounts must match pooled tokens"
        );

        uint256[] memory fees = new uint256[](self.pooledTokens.length);

        // current state
        AddLiquidityInfo memory v = AddLiquidityInfo(0, 0, 0, 0);
        uint256 totalSupply = self.lpToken.totalSupply();
        uint256[] memory newBalances = self.balances;
        uint256 baseVirtualPrice = _getBaseVirtualPrice(self);
        v.preciseA = _getAPrecise(self);

        if (totalSupply != 0) {
            v.d0 = getD(_xp(self, newBalances, baseVirtualPrice), v.preciseA);
        }

        for (uint256 i = 0; i < self.pooledTokens.length; i++) {
            require(
                totalSupply != 0 || amounts[i] > 0,
                "Must supply all tokens in pool"
            );

            // Transfer tokens first to see if a fee was charged on transfer
            if (amounts[i] != 0) {
                uint256 beforeBalance =
                    self.pooledTokens[i].balanceOf(address(this));
                self.pooledTokens[i].safeTransferFrom(
                    msg.sender,
                    address(this),
                    amounts[i]
                );

                // Update the amounts[] with actual transfer amount
                amounts[i] = self.pooledTokens[i].balanceOf(address(this)).sub(
                    beforeBalance
                );
            }

            newBalances[i] = self.balances[i].add(amounts[i]);
        }

        // invariant after change
        v.d1 = getD(_xp(self, newBalances, baseVirtualPrice), v.preciseA);
        require(v.d1 > v.d0, "D should increase");

        // updated to reflect fees and calculate the user's LP tokens
        v.d2 = v.d1;
        if (totalSupply != 0) {
            uint256 feePerToken = _feePerToken(self);
            for (uint256 i = 0; i < self.pooledTokens.length; i++) {
                uint256 idealBalance = v.d1.mul(self.balances[i]).div(v.d0);
                fees[i] = feePerToken
                    .mul(idealBalance.difference(newBalances[i]))
                    .div(FEE_DENOMINATOR);
                self.balances[i] = newBalances[i].sub(
                    fees[i].mul(self.adminFee).div(FEE_DENOMINATOR)
                );
                newBalances[i] = newBalances[i].sub(fees[i]);
            }
            v.d2 = getD(_xp(self, newBalances, baseVirtualPrice), v.preciseA);
        } else {
            // the initial depositor doesn't pay fees
            self.balances = newBalances;
        }

        uint256 toMint;
        if (totalSupply == 0) {
            toMint = v.d1;
        } else {
            toMint = v.d2.sub(v.d0).mul(totalSupply).div(v.d0);
        }

        require(toMint >= minToMint, "Couldn't mint min requested");

        // mint the user's LP tokens
        self.lpToken.mint(msg.sender, toMint);

        emit AddLiquidity(
            msg.sender,
            amounts,
            fees,
            v.d1,
            totalSupply.add(toMint)
        );

        return toMint;
    }

    /**
     * @notice Update the withdraw fee for `user`. If the user is currently
     * not providing liquidity in the pool, sets to default value. If not, recalculate
     * the starting withdraw fee based on the last deposit's time & amount relative
     * to the new deposit.
     *
     * @param self Swap struct to read from and write to
     * @param user address of the user depositing tokens
     * @param toMint amount of pool tokens to be minted
     */
    function updateUserWithdrawFee(
        Swap storage self,
        address user,
        uint256 toMint
    ) external {
        _updateUserWithdrawFee(self, user, toMint);
    }

    function _updateUserWithdrawFee(
        Swap storage self,
        address user,
        uint256 toMint
    ) internal {
        // If token is transferred to address 0 (or burned), don't update the fee.
        if (user == address(0)) {
            return;
        }
        if (self.defaultWithdrawFee == 0) {
            // If current fee is set to 0%, set multiplier to FEE_DENOMINATOR
            self.withdrawFeeMultiplier[user] = FEE_DENOMINATOR;
        } else {
            // Otherwise, calculate appropriate discount based on last deposit amount
            uint256 currentFee = calculateCurrentWithdrawFee(self, user);
            uint256 currentBalance = self.lpToken.balanceOf(user);

            // ((currentBalance * currentFee) + (toMint * defaultWithdrawFee)) * FEE_DENOMINATOR /
            // ((toMint + currentBalance) * defaultWithdrawFee)
            self.withdrawFeeMultiplier[user] = currentBalance
                .mul(currentFee)
                .add(toMint.mul(self.defaultWithdrawFee))
                .mul(FEE_DENOMINATOR)
                .div(toMint.add(currentBalance).mul(self.defaultWithdrawFee));
        }
        self.depositTimestamp[user] = block.timestamp;
    }

    /**
     * @notice Burn LP tokens to remove liquidity from the pool.
     * @dev Liquidity can always be removed, even when the pool is paused.
     * @param self Swap struct to read from and write to
     * @param amount the amount of LP tokens to burn
     * @param minAmounts the minimum amounts of each token in the pool
     * acceptable for this burn. Useful as a front-running mitigation
     * @return amounts of tokens the user received
     */
    function removeLiquidity(
        Swap storage self,
        uint256 amount,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory) {
        require(amount <= self.lpToken.balanceOf(msg.sender), ">LP.balanceOf");
        require(
            minAmounts.length == self.pooledTokens.length,
            "minAmounts must match poolTokens"
        );

        uint256[] memory amounts =
            _calculateRemoveLiquidity(self, msg.sender, amount);

        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] >= minAmounts[i], "amounts[i] < minAmounts[i]");
            self.balances[i] = self.balances[i].sub(amounts[i]);
            self.pooledTokens[i].safeTransfer(msg.sender, amounts[i]);
        }

        self.lpToken.burnFrom(msg.sender, amount);

        emit RemoveLiquidity(msg.sender, amounts, self.lpToken.totalSupply());

        return amounts;
    }

    /**
     * @notice Remove liquidity from the pool all in one token.
     * @param self Swap struct to read from and write to
     * @param tokenAmount the amount of the lp tokens to burn
     * @param tokenIndex the index of the token you want to receive
     * @param minAmount the minimum amount to withdraw, otherwise revert
     * @return amount chosen token that user received
     */
    function removeLiquidityOneToken(
        Swap storage self,
        uint256 tokenAmount,
        uint8 tokenIndex,
        uint256 minAmount
    ) external returns (uint256) {
        uint256 totalSupply = self.lpToken.totalSupply();
        uint256 numTokens = self.pooledTokens.length;
        require(
            tokenAmount <= self.lpToken.balanceOf(msg.sender),
            ">LP.balanceOf"
        );
        require(tokenIndex < numTokens, "Token not found");

        uint256 dyFee;
        uint256 dy;

        (dy, dyFee) = calculateWithdrawOneToken(
            self,
            msg.sender,
            tokenAmount,
            tokenIndex,
            _updateBaseVirtualPrice(self)
        );

        require(dy >= minAmount, "dy < minAmount");

        self.balances[tokenIndex] = self.balances[tokenIndex].sub(
            dy.add(dyFee.mul(self.adminFee).div(FEE_DENOMINATOR))
        );
        self.lpToken.burnFrom(msg.sender, tokenAmount);
        self.pooledTokens[tokenIndex].safeTransfer(msg.sender, dy);

        emit RemoveLiquidityOne(
            msg.sender,
            tokenAmount,
            totalSupply,
            tokenIndex,
            dy
        );

        return dy;
    }

    /**
     * @notice Remove liquidity from the pool, weighted differently than the
     * pool's current balances.
     *
     * @param self Swap struct to read from and write to
     * @param amounts how much of each token to withdraw
     * @param maxBurnAmount the max LP token provider is willing to pay to
     * remove liquidity. Useful as a front-running mitigation.
     * @return actual amount of LP tokens burned in the withdrawal
     */
    function removeLiquidityImbalance(
        Swap storage self,
        uint256[] memory amounts,
        uint256 maxBurnAmount
    ) public returns (uint256) {
        require(
            amounts.length == self.pooledTokens.length,
            "Amounts should match pool tokens"
        );
        require(
            maxBurnAmount <= self.lpToken.balanceOf(msg.sender) &&
                maxBurnAmount != 0,
            ">LP.balanceOf"
        );

        RemoveLiquidityImbalanceInfo memory v =
            RemoveLiquidityImbalanceInfo(0, 0, 0, 0, 0);

        uint256 tokenSupply = self.lpToken.totalSupply();
        uint256 feePerToken = _feePerToken(self);
        v.baseVirtualPrice = _updateBaseVirtualPrice(self);

        uint256[] memory balances1 = self.balances;

        v.preciseA = _getAPrecise(self);
        v.d0 = getD(_xp(self, balances1, v.baseVirtualPrice), v.preciseA);
        for (uint256 i = 0; i < self.pooledTokens.length; i++) {
            balances1[i] = balances1[i].sub(
                amounts[i],
                "Cannot withdraw more than available"
            );
        }
        v.d1 = getD(_xp(self, balances1, v.baseVirtualPrice), v.preciseA);
        uint256[] memory fees = new uint256[](balances1.length);

        for (uint256 i = 0; i < self.pooledTokens.length; i++) {
            uint256 idealBalance = v.d1.mul(self.balances[i]).div(v.d0);
            uint256 difference = idealBalance.difference(balances1[i]);
            fees[i] = feePerToken.mul(difference).div(FEE_DENOMINATOR);
            self.balances[i] = balances1[i].sub(
                fees[i].mul(self.adminFee).div(FEE_DENOMINATOR)
            );
            balances1[i] = balances1[i].sub(fees[i]);
        }

        v.d2 = getD(_xp(self, balances1, v.baseVirtualPrice), v.preciseA);

        uint256 tokenAmount = v.d0.sub(v.d2).mul(tokenSupply).div(v.d0);
        require(tokenAmount != 0, "Burnt amount cannot be zero");
        tokenAmount = tokenAmount.add(1).mul(FEE_DENOMINATOR).div(
            FEE_DENOMINATOR.sub(calculateCurrentWithdrawFee(self, msg.sender))
        );

        require(tokenAmount <= maxBurnAmount, "tokenAmount > maxBurnAmount");

        self.lpToken.burnFrom(msg.sender, tokenAmount);

        for (uint256 i = 0; i < self.pooledTokens.length; i++) {
            self.pooledTokens[i].safeTransfer(msg.sender, amounts[i]);
        }

        emit RemoveLiquidityImbalance(
            msg.sender,
            amounts,
            fees,
            v.d1,
            tokenSupply.sub(tokenAmount)
        );

        return tokenAmount;
    }

    /**
     * @notice withdraw all admin fees to a given address
     * @param self Swap struct to withdraw fees from
     * @param to Address to send the fees to
     */
    function withdrawAdminFees(Swap storage self, address to) external {
        for (uint256 i = 0; i < self.pooledTokens.length; i++) {
            IERC20 token = self.pooledTokens[i];
            uint256 balance =
                token.balanceOf(address(this)).sub(self.balances[i]);
            if (balance != 0) {
                token.safeTransfer(to, balance);
            }
        }
    }

    /**
     * @notice Sets the admin fee
     * @dev adminFee cannot be higher than 100% of the swap fee
     * @param self Swap struct to update
     * @param newAdminFee new admin fee to be applied on future transactions
     */
    function setAdminFee(Swap storage self, uint256 newAdminFee) external {
        require(newAdminFee <= MAX_ADMIN_FEE, "Fee is too high");
        self.adminFee = newAdminFee;

        emit NewAdminFee(newAdminFee);
    }

    /**
     * @notice update the swap fee
     * @dev fee cannot be higher than 1% of each swap
     * @param self Swap struct to update
     * @param newSwapFee new swap fee to be applied on future transactions
     */
    function setSwapFee(Swap storage self, uint256 newSwapFee) external {
        require(newSwapFee <= MAX_SWAP_FEE, "Fee is too high");
        self.swapFee = newSwapFee;

        emit NewSwapFee(newSwapFee);
    }

    /**
     * @notice update the default withdraw fee. This also affects deposits made in the past as well.
     * @param self Swap struct to update
     * @param newWithdrawFee new withdraw fee to be applied
     */
    function setDefaultWithdrawFee(Swap storage self, uint256 newWithdrawFee)
        external
    {
        require(newWithdrawFee <= MAX_WITHDRAW_FEE, "Fee is too high");
        self.defaultWithdrawFee = newWithdrawFee;

        emit NewWithdrawFee(newWithdrawFee);
    }

    /**
     * @notice Start ramping up or down A parameter towards given futureA_ and futureTime_
     * Checks if the change is too rapid, and commits the new A value only when it falls under
     * the limit range.
     * @param self Swap struct to update
     * @param futureA_ the new A to ramp towards
     * @param futureTime_ timestamp when the new A should be reached
     */
    function rampA(
        Swap storage self,
        uint256 futureA_,
        uint256 futureTime_
    ) external {
        require(
            block.timestamp >= self.initialATime.add(1 days),
            "Wait 1 day before starting ramp"
        );
        require(
            futureTime_ >= block.timestamp.add(MIN_RAMP_TIME),
            "Insufficient ramp time"
        );
        require(
            futureA_ > 0 && futureA_ < MAX_A,
            "futureA_ must be > 0 and < MAX_A"
        );

        uint256 initialAPrecise = _getAPrecise(self);
        uint256 futureAPrecise = futureA_.mul(A_PRECISION);

        if (futureAPrecise < initialAPrecise) {
            require(
                futureAPrecise.mul(MAX_A_CHANGE) >= initialAPrecise,
                "futureA_ is too small"
            );
        } else {
            require(
                futureAPrecise <= initialAPrecise.mul(MAX_A_CHANGE),
                "futureA_ is too large"
            );
        }

        self.initialA = initialAPrecise;
        self.futureA = futureAPrecise;
        self.initialATime = block.timestamp;
        self.futureATime = futureTime_;

        emit RampA(
            initialAPrecise,
            futureAPrecise,
            block.timestamp,
            futureTime_
        );
    }

    /**
     * @notice Stops ramping A immediately. Once this function is called, rampA()
     * cannot be called for another 24 hours
     * @param self Swap struct to update
     */
    function stopRampA(Swap storage self) external {
        require(self.futureATime > block.timestamp, "Ramp is already stopped");
        uint256 currentA = _getAPrecise(self);

        self.initialA = currentA;
        self.futureA = currentA;
        self.initialATime = block.timestamp;
        self.futureATime = block.timestamp;

        emit StopRampA(currentA, block.timestamp);
    }
}
