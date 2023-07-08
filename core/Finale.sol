// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../utils/ReentrancyGuard.sol";
import "../interfaces/Interfaces.sol";
import "./ContractErrors.sol";
import "../utils/Ownable.sol";
import "../utils/Math.sol";

/**
 * @title Finale Contract
 * @dev The Finale contract allows users to perform token swaps using the ISyncRouter and IMuteRouter interfaces.
 * It provides functions for approving tokens, executing swaps, and handling token transfers.
 * The contract also includes reentrancy guard, contract error handling, and ownership functionality.
 */
contract Finale is ReentrancyGuard, ContractErrors, Ownable {
    using Math for uint;
    event SwapExecuted(
        address indexed user, 
        address tokenIn, 
        address tokenOut, 
        uint amountIn, 
        uint amountOut, 
        uint swapType
    );
    event PathsExecuted(
        address indexed user,
        Params.SwapParam[] swapParams,
        uint minTotalAmountOut,
        uint finalTokenAmount
    );

    ISyncRouter syncRouter;
    address public _syncrouterAddress = 0xB3b7fCbb8Db37bC6f572634299A58f51622A847e;
    IMuteRouter muteRouter;
    address public _muteRouterAddress = 0x96c2Cf9edbEA24ce659EfBC9a6e3942b7895b5e8;
    address public _fee_address = 0x41dA10bc38436cd3f555f3a7fDe6A257F5c5EbbB;

    constructor() ReentrancyGuard() Ownable(msg.sender) {
        syncRouter = ISyncRouter(_syncrouterAddress);
        muteRouter = IMuteRouter(_muteRouterAddress);
    }

    /**
     * @notice Sets the maximum allowances for the specified tokens to the syncRouter and muteRouter addresses.
     * @dev Only the contract owner can call this function.
     * @param tokens Array of token addresses.
     */
    function maxApprovals(address[] calldata tokens) external onlyOwner {
        for(uint i = 0; i < tokens.length; i++) {
            IERC20 token = IERC20(tokens[i]);
            if(!token.approve(_syncrouterAddress, type(uint256).max)) revert ApprovalFailedError(tokens[i], _syncrouterAddress);
            if(!token.approve(_muteRouterAddress, type(uint256).max)) revert ApprovalFailedError(tokens[i], _muteRouterAddress);
        }
    }

    /**
     * @notice Revokes the allowances for the specified tokens from the syncRouter and muteRouter addresses.
     * @dev Only the contract owner can call this function.
     * @param tokens Array of token addresses.
     */
    function revokeApprovals(address[] calldata tokens) external onlyOwner {
        for(uint i = 0; i < tokens.length; i++) {
            IERC20 token = IERC20(tokens[i]);
            if(!token.approve(_syncrouterAddress, 0)) revert RevokeApprovalFailedError(tokens[i], _syncrouterAddress);
            if(!token.approve(_muteRouterAddress, 0)) revert RevokeApprovalFailedError(tokens[i], _muteRouterAddress);
        }
    }

    /**
     * @notice Executes a token swap using the specified pool, tokenIn, amountIn, and amountOutMin.
     * @dev Internal function used by syncswap and muteswap.
     * @param poolAddress Address of the pool to swap tokens in.
     * @param tokenIn Address of the input token.
     * @param amountIn Amount of input token to swap.
     * @param amountOutMin Minimum amount of output token expected.
     * @return TokenAmount structure containing the output token and amount.
     */
    function syncswap(
        address poolAddress,
        address tokenIn,
        uint amountIn,
        uint amountOutMin
    ) internal returns (IPool.TokenAmount memory) {
        bytes memory swapData = abi.encode(tokenIn, address(this), uint8(2));
        ISyncRouter.SwapStep memory step = ISyncRouter.SwapStep({
            pool: poolAddress,
            data: swapData,  
            callback: address(0),  
            callbackData: "0x"  
        });

        ISyncRouter.SwapPath[] memory paths = new ISyncRouter.SwapPath[](1);
        paths[0] = ISyncRouter.SwapPath({
            steps: new ISyncRouter.SwapStep[](1),
            tokenIn: tokenIn,
            amountIn: amountIn
        });

        paths[0].steps[0] = step;
        uint deadline = block.timestamp + 20 minutes; 
        IPool.TokenAmount memory amountOut = syncRouter.swap(
            paths,
            amountOutMin,
            deadline
        );
        emit SwapExecuted(msg.sender, tokenIn, amountOut.token, amountIn, amountOut.amount, 1);
        return amountOut;
    }

    /**
     * @notice Executes a token swap using the specified tokenIn, tokenOut, amountIn, and amountOutMin.
     * @dev Internal function used by executeSwaps.
     * @param tokenIn Address of the input token.
     * @param tokenOut Address of the output token.
     * @param amountIn Amount of input token to swap.
     * @param amountOutMin Minimum amount of output token expected.
     * @return TokenAmount structure containing the output token and amount.
     */
    function muteswap(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint amountOutMin
    ) internal returns (IPool.TokenAmount memory) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        bool[] memory stable = new bool[](2);
        stable[0] = false;
        stable[1] = false;
        uint deadline = block.timestamp + 20 minutes; 
        uint[] memory amounts = muteRouter.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            deadline,
            stable
        );

        IPool.TokenAmount memory tokenOutAmount;
        tokenOutAmount.token = tokenOut;
        tokenOutAmount.amount = amounts[amounts.length - 1];
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amounts[amounts.length - 1], 2);
        return tokenOutAmount;
    }

    /**
     * @notice Executes a series of swap operations based on the provided swapParams.
     * @dev This function performs chained swaps using syncswap and muteswap functions.
     * @param swapParams Array of SwapParam structures containing swap details.
     * @param minTotalAmountOut Minimum total amount of output token expected.
     */
    function executeSwaps(Params.SwapParam[] memory swapParams, uint minTotalAmountOut) nonReentrant() external {
        address tokenG = swapParams[0].tokenIn;
        IERC20 token = IERC20(tokenG);
        uint256 amountIn = swapParams[0].amountIn;
        if (!token.transferFrom(msg.sender ,address(this), amountIn)) revert TransferFromFailedError(msg.sender, address(this), amountIn);
        address finalTokenAddress;
        uint finalTokenAmount;
        for(uint i = 0; i < swapParams.length; i++) {
            Params.SwapParam memory param = swapParams[i];
            if(param.swapType == 1) {
                IPool.TokenAmount memory result = syncswap(
                    param.poolAddress, 
                    param.tokenIn, 
                    amountIn, 
                    param.amountOutMin
                );
                finalTokenAddress = result.token;
                finalTokenAmount = result.amount;
            } else if(param.swapType == 2) {
                IPool.TokenAmount memory result = muteswap(
                    param.tokenIn, 
                    param.tokenOut, 
                    amountIn, 
                    param.amountOutMin
                );
                finalTokenAddress = result.token;
                finalTokenAmount = result.amount;
            } else {
                revert("Invalid swap type");
            }
            amountIn = finalTokenAmount;
        }
        if(finalTokenAmount < minTotalAmountOut) revert AmountLessThanMinRequiredError(finalTokenAmount, minTotalAmountOut);
        IERC20 finalToken = IERC20(finalTokenAddress);
        uint fee = (finalTokenAmount * 3) / 1000;
        uint amountToTransfer = finalTokenAmount - fee;
        if(!finalToken.transfer(_fee_address, fee)) revert TransferFailedError(finalTokenAddress, _fee_address, fee);
        if(!finalToken.transfer(msg.sender, amountToTransfer)) revert TransferFailedError(finalTokenAddress, msg.sender, amountToTransfer);
    
        emit PathsExecuted(msg.sender, swapParams, minTotalAmountOut, finalTokenAmount);
    }
}
