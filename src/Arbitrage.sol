// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title MEV Arbitrage Bot Contract
 * @notice 다양한 DEX 프로토콜과 상호작용하는 차익거래 봇
 * @dev Uniswap V2/V3/V4, Flash Loans 지원
 */
contract ArbitrageBot {
    
    // ============ State Variables ============
    
    uint256 public minAmount;
    address private constant OWNER = 0xc221b31C31e6e064BBDa9a9C0ED0B955e9837d12;
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
        uint24 mode;             // 0: V4 swap, 1: simple transfer, 2: complex swap
        address token0;          // First token
        address token1;          // Second token
        uint24 fee;              // Fee tier
        int24 tickSpacing;       // Tick spacing
        address recipient;       // Recipient address
        bool zeroForOne;         // Swap direction
        uint256 amountSpecified; // Amount to swap
        bytes extraData;         // Additional data
    }
    
    // ============ Modifiers ============
    
    modifier onlyOwner() {
        require(msg.sender == OWNER, "403");
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
    ) external {
        _executeBatch(data);
    }
    
    /**
     * @notice Uniswap V3 swap 콜백
     */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _executeBatch(data);
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
    ) external returns (bytes32) {
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
    ) external {
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
     * @param gasPrice 가스 가격
     */
    function executeArbitrage(
        Transaction[] calldata transactions,
        address token
    ) external payable {
        uint256 gasStart = gasleft();
        // 초기 잔액 저장
        uint256 balanceBefore = _getBalance(token);
        
        // 모든 트랜잭션 실행
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
        
        // 올바른 가스 비용 계산
        uint256 gasUsed = gasStart - gasleft();
        uint256 gasCost = gasUsed * tx.gasprice;
        
        require(profit > gasCost, "Not profitable");
        
        uint256 netProfit = profit - gasCost;
        
        console.log("Gas used:", gasleft());
        console.log("Gas cost:", gasCost);
        
        // WETH를 ETH로 변환
        if (token == WETH) {
            IWETH(WETH).withdraw(balanceAfter);
        }
        
        // 수익 분배
        _distributeProfits(netProfit);
    }
    
    /**
     * @notice Uniswap V4 unlock 콜백
     */
    function unlockCallback(bytes calldata rawData) 
        external 
        returns (bytes memory) 
    {
        SwapParams memory params = abi.decode(rawData, (SwapParams));
        
        require(msg.sender == params.poolManager, "Invalid caller");
        
        if (params.mode == 0) {
            // Mode 0: V4 Swap 실행
            return _executeV4Swap(params);
            
        } else if (params.mode == 1) {
            // Mode 1: 단순 토큰 이동
            _executeSimpleTransfer(params);
            return "";
            
        } else if (params.mode == 2) {
            // Mode 2: 복잡한 스왑 로직
            _executeComplexSwap(params);
            return "";
        }
        
        revert("Invalid mode");
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
            // ETH 출금
            (bool success, ) = _toUser.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // ERC20 출금
            IERC20(tokenAddress).transfer(_toUser, amount);
        }
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice 트랜잭션 배치 실행
     */
    function _executeBatch(bytes calldata data) internal {
        Transaction[] memory transactions = abi.decode(data, (Transaction[]));
        
        for (uint256 i = 0; i < transactions.length; i++) {
            (bool success, bytes memory returnData) = transactions[i].target.call{
                value: transactions[i].value
            }(transactions[i].data);
            
            require(success, string(returnData));
        }
    }
    
    /**
     * @notice V4 스왑 실행 (Flash Accounting 방식)
     * @dev 출력 토큰을 먼저 가져간 후 입력 토큰을 나중에 정산
     */
    function _executeV4Swap(SwapParams memory params)
        internal
        returns (bytes memory)
    {
        // Swap 전 delta 확인 (선택사항 - 디버깅용)
        int256 deltaBefore0 = _getCurrencyDelta(address(this), params.token0, params.poolManager);
        int256 deltaBefore1 = _getCurrencyDelta(address(this), params.token1, params.poolManager);

        // PoolKey 구성
        bytes memory poolKey = abi.encode(
            params.token0,      // currency0
            params.token1,      // currency1
            params.fee,         // fee
            params.tickSpacing, // tickSpacing
            address(0)          // hooks (no hook)
        );

        // SwapParams 구성
        bytes memory swapParams = abi.encode(
            params.zeroForOne,       // zeroForOne
            int256(params.amountSpecified),  // amountSpecified
            params.zeroForOne
                ? uint160(4295128740)  // sqrtPriceLimitX96 for zeroForOne
                : uint160(1461446703485210103287273052203988822378723970341)  // sqrtPriceLimitX96 for oneForZero
        );

        // Swap 실행
        (bool success, bytes memory result) = params.poolManager.call(
            abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)",
                poolKey,
                swapParams,
                ""  // hookData (empty)
            )
        );

        require(success, "V4 Swap failed");

        // Swap 후 delta 확인
        int256 deltaAfter0 = _getCurrencyDelta(address(this), params.token0, params.poolManager);
        int256 deltaAfter1 = _getCurrencyDelta(address(this), params.token1, params.poolManager);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // 🔥 FLASH: 출력 토큰을 먼저 가져감!
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        (address inputToken, address outputToken, int256 inputDelta, int256 outputDelta) = params.zeroForOne
            ? (params.token0, params.token1, deltaAfter0, deltaAfter1)
            : (params.token1, params.token0, deltaAfter1, deltaAfter0);

        if (outputDelta > 0) {
            uint256 amountOut = uint256(outputDelta);

            // take() 호출 - 토큰 인출
            (bool takeSuccess,) = params.poolManager.call(
                abi.encodeWithSignature(
                    "take(address,address,uint256)",
                    outputToken,
                    params.recipient,
                    amountOut
                )
            );
            require(takeSuccess, "Take failed");
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // 추가 작업 실행 (extraData)
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        if (params.extraData.length > 0) {
            _executeBatch(params.extraData);
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // 입력 토큰 정산 (나중에!)
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        if (inputDelta < 0) {
            uint256 amountOwed = uint256(-inputDelta);

            // Native ETH 여부 확인
            bool isNative = (inputToken == address(0));

            // 1. sync() 호출 - 잔액 동기화 (DoS 공격 방지 - Native/ERC20 모두 필수!)
            (bool syncSuccess,) = params.poolManager.call(
                abi.encodeWithSignature("sync(address)", inputToken)
            );
            require(syncSuccess, "Sync failed");

            // 2. 토큰 전송
            if (isNative) {
                // Native ETH: settle()에 value 전달
                // (토큰 전송 단계 생략 - settle()에서 msg.value 사용)
            } else {
                // ERC20: 직접 전송
                if (address(this) == params.sender) {
                    IERC20(inputToken).transfer(params.poolManager, amountOwed);
                } else {
                    IERC20(inputToken).transferFrom(params.sender, params.poolManager, amountOwed);
                }
            }

            // 3. settle() 호출 - delta 정산
            (bool settleSuccess,) = isNative
                ? params.poolManager.call{value: amountOwed}(
                    abi.encodeWithSignature("settle()")
                )
                : params.poolManager.call(
                    abi.encodeWithSignature("settle()")
                );
            require(settleSuccess, "Settle failed");
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // 최종 delta 검증
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        int256 finalDelta0 = _getCurrencyDelta(address(this), params.token0, params.poolManager);
        int256 finalDelta1 = _getCurrencyDelta(address(this), params.token1, params.poolManager);

        require(finalDelta0 == 0 && finalDelta1 == 0, "Delta not settled");

        return result;
    }
    
    /**
     * @notice 단순 토큰 이동
     */
    function _executeSimpleTransfer(SwapParams memory params) internal {
        address token = params.zeroForOne ? params.token0 : params.token1;
        
        // Take tokens
        _mintOrTake(0, params.amountSpecified, params.sender, token, params.poolManager);
        
        // 추가 로직 실행
        _executeBatch(params.extraData);
        
        // Settle tokens
        _settle(0, params.amountSpecified, params.sender, token, params.poolManager);
    }
    
    /**
     * @notice 복잡한 스왑 실행
     */
    function _executeComplexSwap(SwapParams memory params) internal {
        address token = params.zeroForOne ? params.token1 : params.token0;
        
        // Take initial tokens
        _mintOrTake(0, params.amountSpecified, params.sender, token, params.poolManager);
        
        // 차익거래 로직 실행
        _executeBatch(params.extraData);
        
        // Settle
        _settle(0, params.amountSpecified, params.sender, token, params.poolManager);
    }
    
    /**
     * @notice Mint 또는 Take 실행
     */
    function _mintOrTake(
        uint256 mode,
        uint256 amount,
        address sender,
        address token,
        address poolManager
    ) internal {
        if (mode == 1) {
            // Mint
            IPoolManager(poolManager).mint(sender, token, amount);
        } else {
            // Take
            IPoolManager(poolManager).take(token, sender, amount);
        }
    }
    
    /**
     * @notice Burn 또는 Settle 실행
     */
    function _settle(
        uint256 mode,
        uint256 amount,
        address sender,
        address token,
        address poolManager
    ) internal {
        if (mode == 1) {
            // Burn
            IPoolManager(poolManager).burn(sender, token, amount);
        } else {
            // Settle
            if (token == address(0)) {
                // ETH settle
                IPoolManager(poolManager).settle{value: amount}();
            } else {
                // Token settle
                IPoolManager(poolManager).sync(token);
                
                if (address(this) == sender) {
                    IERC20(token).transfer(poolManager, amount);
                } else {
                    IERC20(token).transferFrom(sender, poolManager, amount);
                }
                
                IPoolManager(poolManager).settle();
            }
        }
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
     * @notice 수익 분배
     */
    function _distributeProfits(
        uint256 netProfit
    ) internal {
        address recipient = 0x9d45eCAE5277D58aFEDd587C2DB208Ab7BD4c253;
        
        if (msg.value == 0) {
            payable(recipient).transfer(netProfit);
        } else if (msg.value < 1000) {
            uint256 tip = (netProfit * msg.value) / 1000;
            block.coinbase.transfer(tip);
            payable(recipient).transfer(netProfit - tip);
        } else {
            revert("invalid");
        }
        
        console.log("Profit distributed:", netProfit);
    }
    
    // ============ Fallback ============
    
    receive() external payable {}
    
    fallback() external payable {
        // 추가 콜백 처리 (예: 다른 sender로부터의 호출)
        if (msg.sender != address(this)) {
            _executeBatch(msg.data[4:]);
        }
    }
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
        uint256 amountSpecified,
        address hookData,
        bytes calldata data
    ) external returns (bytes memory);
    
    function mint(address to, address token, uint256 amount) external;
    function burn(address from, address token, uint256 amount) external;
    function take(address token, address to, uint256 amount) external;
    function sync(address token) external;
    function settle() external payable returns (uint256);
}

library console {
    function log(string memory message, uint256 value) internal view {
        // Console logging placeholder
    }
}
