// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title MEV Arbitrage Bot Contract
 * @notice 다양한 DEX 프로토콜과 상호작용하는 차익거래 봇
 * @dev Uniswap V2/V3/V4, Flash Loans 지원
 */
contract ArbitrageBot {
    
    // ============ State Variables ============
    
    address private constant OWNER = 0xc221b31C31e6e064BBDa9a9C0ED0B955e9837d12;
    address private constant RECEIVER = 0x9d45eCAE5277D58aFEDd587C2DB208Ab7BD4c253;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    // ============ Structs ============
    
    struct Transaction {
        address target;
        uint256 value;
        bytes data;
    }
    
    struct SwapParams {
        address poolManager;      // Pool manager address
        address sender;           // Original sender
        address recipient;       // Recipient address
        address token0;          // First token
        address token1;          // Second token
        uint24 fee;              // Fee tier
        int24 tickSpacing;       // Tick spacing
        address hooks;           // hook address
        bool zeroForOne;         // Swap direction
        int256 amountSpecified; // Amount to swap
        bytes extraData;         // Additional data
    }
    
    // ============ Modifiers ============

    modifier onlyOwner() {
        require(msg.sender == OWNER, "403");
        _;
    }

    modifier onlyOwnerOrigin() {
        require(tx.origin == OWNER, "Unauthorized origin");
        _;
    }
    
    // ============ External Functions ============
    
    /**
     * @notice Uniswap V2 flash swap 콜백
     */
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external onlyOwnerOrigin {
        _executeBatch(data);
    }
    
    /**
     * @notice Uniswap V3 swap 콜백
     */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external onlyOwnerOrigin {
        _executeBatch(data);
    }

    /**
     * @notice Uniswap V4 unlock 콜백
     */
    function unlockCallback(bytes calldata rawData)
        external
        onlyOwnerOrigin
        returns (bytes memory)
    {
        SwapParams memory params = abi.decode(rawData, (SwapParams));

        return _executeV4Swap(params);
    }
    
    /**
     * @notice ERC3156 flash loan 콜백
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external onlyOwnerOrigin returns (bytes32) {
        _executeBatch(data);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
    
    /**
     * @notice Balancer flash loan 콜백
     */
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external onlyOwnerOrigin {
        _executeBatch(userData);
    }
    
    /**
     * @notice 배치 트랜잭션 실행 (Owner 전용)
     */
    function batchExecute(Transaction[] calldata transactions) 
        external 
        payable 
        onlyOwner 
    {
        for (uint256 i = 0; i < transactions.length; i++) {
            Transaction calldata txn = transactions[i];
            
            (bool success, bytes memory returnData) = txn.target.call{
                value: txn.value
            }(txn.data);
            
            require(success, string(returnData));
        }
    }
    
    /**
     * @notice 메인 차익거래 실행 함수
     * @param transactions 실행할 트랜잭션 배열
     * @param token 이익을 측정할 토큰
     * @return netProfit 팁을 제외한 순수익 (RECEIVER에게 전송되는 금액)
     */
    function executeArbitrage(
        Transaction[] calldata transactions,
        address token
    ) external payable onlyOwner returns (uint256 netProfit) {
        uint256 gasStart = gasleft();
        uint256 balanceBefore = _getBalance(token);

        for (uint256 i = 0; i < transactions.length; i++) {
            Transaction calldata txn = transactions[i];

            (bool success, bytes memory returnData) = txn.target.call{
                value: txn.value
            }(txn.data);

            require(success, string(returnData));
        }

        // 최종 잔액 및 이익 계산
        uint256 balanceAfter = _getBalance(token);
        uint256 profit = balanceAfter > balanceBefore
            ? balanceAfter - balanceBefore
            : 0;

        // 팁 계산 (msg.value가 있을 경우)
        uint256 tip = 0;
        if (msg.value > 0 && msg.value < 1000) {
            tip = (profit * msg.value) / 1000;
        }

        // 순수익 계산
        netProfit = profit - tip;

        if (token == WETH) {
            IWETH(WETH).withdraw(profit);
        }

        // 팁과 순수익 분배
        if (tip > 0) {
            block.coinbase.transfer(tip);
        }

        payable(RECEIVER).transfer(netProfit);

        require(netProfit > ((gasStart - gasleft()) * tx.gasprice), "Not profitable");

        return netProfit;
    }
    
    /**
     * @notice 범용 실행 함수 (Owner 전용)
     */
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external payable onlyOwner returns (bool) {
        (bool success, ) = _to.call{value: _value}(_data);
        return success;
    }
    
    /**
     * @notice 토큰/ETH 출금 (Owner 전용)
     */
    function withdraw(
        address tokenAddress,
        address _toUser,
        uint256 amount
    ) external onlyOwner {
        if (tokenAddress == address(0)) {
            (bool success, ) = _toUser.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            _safeTransfer(tokenAddress, _toUser, amount);
        }
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice 트랜잭션 배치 실행
     */
    function _executeBatch(bytes memory data) internal {
        Transaction[] memory transactions = abi.decode(data, (Transaction[]));
        for (uint256 i = 0; i < transactions.length; i++) {
            (bool success, bytes memory returnData) = transactions[i].target.call{
                value: transactions[i].value
            }(transactions[i].data);
            require(success, string(returnData));
        }
    }
    
    /**
     * @notice V4 스왑 실행
     * @dev settle 후에 take
     */
    function _executeV4Swap(SwapParams memory params)
        internal
        returns (bytes memory)
    {
        bytes memory result = _performV4Swap(params);

        (int256 deltaAfter0, int256 deltaAfter1) = _getSwapDeltas(params);
        
        _settleInputToken(params, deltaAfter0, deltaAfter1);
        
        _handleOutputToken(params, deltaAfter0, deltaAfter1);

        _verifyDeltaSettled(params);

        if (params.extraData.length > 0) {
            _executeBatch(params.extraData);
        }

        return result;
    }

    /**
     * @notice V4 Swap 실행
     */
    function _performV4Swap(SwapParams memory params)
        internal
        returns (bytes memory)
    {
        bytes memory callData = abi.encodeWithSelector(
            bytes4(keccak256("swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)")),
            // PoolKey (tuple)
            params.token0,
            params.token1,
            params.fee,
            params.tickSpacing,
            params.hooks,
            // SwapParams (tuple)
            params.zeroForOne,
            params.amountSpecified,
            params.zeroForOne
                ? uint160(4295128740)
                : uint160(1461446703485210103287273052203988822378723970341),
            // hookData (빈 bytes)
            ""
        );

        (bool success, bytes memory result) = params.poolManager.call(callData);
        require(success, "V4 Swap failed");
        return result;
    }

    /**
     * @notice Swap 후 Delta 조회
     */
    function _getSwapDeltas(SwapParams memory params)
        internal
        view
        returns (int256, int256)
    {
        return (
            _getCurrencyDelta(address(this), params.token0, params.poolManager),
            _getCurrencyDelta(address(this), params.token1, params.poolManager)
        );
    }

    /**
     * @notice 출력 토큰 처리 (take)
     */
    function _handleOutputToken(
        SwapParams memory params,
        int256 deltaAfter0,
        int256 deltaAfter1
    ) internal {
        int256 outputDelta = params.zeroForOne ? deltaAfter1 : deltaAfter0;

        if (outputDelta > 0) {
            address outputToken = params.zeroForOne ? params.token1 : params.token0;

            (bool success,) = params.poolManager.call(
                abi.encodeWithSignature(
                    "take(address,address,uint256)",
                    outputToken,
                    params.recipient,
                    uint256(outputDelta)
                )
            );
            require(success, "Take failed");
        }
    }

    /**
     * @notice 입력 토큰 정산 (settle)
     */
    function _settleInputToken(
        SwapParams memory params,
        int256 deltaAfter0,
        int256 deltaAfter1
    ) internal {
        int256 inputDelta = params.zeroForOne ? deltaAfter0 : deltaAfter1;

        if (inputDelta >= 0) return;

        address inputToken = params.zeroForOne ? params.token0 : params.token1;
        uint256 amountOwed = uint256(-inputDelta);
        bool isNative = (inputToken == address(0));

        // 1. Sync
        (bool syncSuccess,) = params.poolManager.call(
            abi.encodeWithSignature("sync(address)", inputToken)
        );
        require(syncSuccess, "Sync failed");

        // 2. Transfer (ERC20만)
        if (!isNative) {
            if (address(this) == params.sender) {
                _safeTransfer(inputToken, params.poolManager, amountOwed);
            } else {
                _safeTransferFrom(inputToken, params.sender, params.poolManager, amountOwed);
            }
        }

        // 3. Settle
        (bool settleSuccess,) = isNative
            ? params.poolManager.call{value: amountOwed}(
                abi.encodeWithSignature("settle()")
            )
            : params.poolManager.call(
                abi.encodeWithSignature("settle()")
            );
        require(settleSuccess, "Settle failed");
    }

    /**
     * @notice Delta 정산 검증
     */
    function _verifyDeltaSettled(SwapParams memory params) internal view {
        (int256 delta0, int256 delta1) = _getSwapDeltas(params);
        require(delta0 == 0 && delta1 == 0, "Delta not settled");
    }
    
    /**
     * @notice 토큰 잔액 조회
     */
    function _getBalance(address token) internal view returns (uint256) {
        if (token == NATIVE_ETH) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }
    
    /**
     * @notice Currency delta 조회 (V4)
     */
    function _getCurrencyDelta(
        address owner,
        address currency,
        address poolManager
    ) internal view returns (int256) {
        bytes32 slot = keccak256(abi.encode(owner, currency));
        
        (bool success, bytes memory result) = poolManager.staticcall(
            abi.encodeWithSignature("exttload(bytes32)", slot)
        );
        
        require(success, "Delta read failed");
        return abi.decode(result, (int256));
    }
    
    /**
     * @notice Safe transfer for ERC20 tokens (USDT 호환)
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed"
        );
    }

    /**
     * @notice Safe transferFrom for ERC20 tokens (USDT 호환)
     */
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount) // transferFrom(address,address,uint256)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferFrom failed"
        );
    }
    
    // ============ Fallback ============
    
    receive() external payable {}
}

// ============ Interfaces ============

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function withdraw(uint256 amount) external;
}

interface IPoolManager {
    function swap(
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        address hookData,
        bytes calldata data
    ) external returns (bytes memory);
    
    function mint(address to, address token, uint256 amount) external;
    function burn(address from, address token, uint256 amount) external;
    function take(address token, address to, uint256 amount) external;
    function sync(address token) external;
    function settle() external payable returns (uint256);
}
