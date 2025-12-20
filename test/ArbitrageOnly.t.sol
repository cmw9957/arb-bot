// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../src/Arbitrage.sol";

contract ArbitrageOnlyTest is Test {
    uint256 mainnetFork;
    ArbitrageBot public arbitrageBot;

    // 주소 정보
    address constant TRIGGER = 0xc221b31C31e6e064BBDa9a9C0ED0B955e9837d12;
    address constant RECEIVER = 0x9d45eCAE5277D58aFEDd587C2DB208Ab7BD4c253;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Block number (TARGET_TX가 이미 실행된 블록)
    uint256 constant BLOCK_NUMBER = 24020124;

    // Arbitrage transaction만 테스트
    address constant ARB_TX_FROM = TRIGGER;
    bytes constant ARB_TX_CALLDATA = hex"ae16c3570000000000000000000000000000000000000000000000000000000000000040000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000360000000000000000000000000d46ba6d942050d489dbd938a2c909a5d5039a161000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044a9059cbb000000000000000000000000c5be99a02c6857f9eac67bbce58df5572498f40c000000000000000000000000000000000000000000000000000000155f1189dd00000000000000000000000000000000000000000000000000000000000000000000000000000000c5be99a02c6857f9eac67bbce58df5572498f40c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a4022c0d9f000000000000000000000000000000000000000000000000008563af47b2bac000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008aa06bb850ad5c603483a972f1282ef61a0ae8930000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000242e1a7d4d0000000000000000000000000000000000000000000000000076d710ff774b8a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004444c5dc75cb358380d2e3de08a900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e448c89491000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000004444c5dc75cb358380d2e3de08a900000000000000000000000008aa06bb850ad5c603483a972f1282ef61a0ae8930000000000000000000000008aa06bb850ad5c603483a972f1282ef61a0ae8930000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d46ba6d942050d489dbd938a2c909a5d5039a1610000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001ffffffffffffffffffffffffffffffffffffffffffffffffff8928ef0088b4760000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    function setUp() public {
        // Block N에서 fork (TARGET_TX 이미 실행된 상태)
        mainnetFork = vm.createFork(
            "https://eth-mainnet.g.alchemy.com/v2/Aj5RHrooceIbmkhMmdratqUaB_KSx1Oo",
            BLOCK_NUMBER
        );
        vm.selectFork(mainnetFork);

        // TRIGGER 주소에 1 ETH 설정 (가스비 충분히 확보)
        vm.deal(TRIGGER, 1 ether);

        // ArbitrageBot 배포 (TRIGGER 주소로)
        vm.prank(TRIGGER);
        arbitrageBot = new ArbitrageBot();

        console.log("===========================================");
        console.log("Forked at block:", BLOCK_NUMBER);
        console.log("Current block.number:", block.number);
        console.log("TRIGGER balance:", TRIGGER.balance / 1 ether, "ETH");
        console.log("ArbitrageBot deployed at:", address(arbitrageBot));
        console.log("===========================================");
    }

    // wei를 ETH 형식으로 출력 (소수점 18자리)
    function formatEther(uint256 weiAmount) internal pure returns (string memory) {
        uint256 integerPart = weiAmount / 1e18;
        uint256 decimalPart = weiAmount % 1e18;

        bytes memory decimalBytes = new bytes(18);
        for (uint256 i = 18; i > 0; i--) {
            decimalBytes[i - 1] = bytes1(uint8(48 + decimalPart % 10));
            decimalPart /= 10;
        }

        return string(abi.encodePacked(
            vm.toString(integerPart),
            ".",
            string(decimalBytes),
            " ETH"
        ));
    }

    function testArbitrageOnly() public {
        console.log("\n=== Arbitrage Transaction Test ===\n");

        // 초기 잔액 확인
        uint256 ethBalanceBefore = RECEIVER.balance;
        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(RECEIVER);

        console.log("--- Initial Balances (Profit Recipient) ---");
        console.log("Address:", RECEIVER);
        console.log("ETH Balance:", ethBalanceBefore, "wei =", formatEther(ethBalanceBefore));
        console.log("WETH Balance:", wethBalanceBefore, "wei =", formatEther(wethBalanceBefore));
        console.log("");

        // Arbitrage 트랜잭션 실행
        vm.prank(ARB_TX_FROM);
        (bool success, bytes memory returnData) = address(arbitrageBot).call{gas: 0x2dc6c0}(ARB_TX_CALLDATA);

        console.log("Arbitrage success:", success);
        if (!success) {
            console.log("Arbitrage failed:");
            console.logBytes(returnData);
        }
        require(success, "Arbitrage transaction failed");

        // 최종 잔액 확인
        uint256 ethBalanceAfter = RECEIVER.balance;
        uint256 wethBalanceAfter = IERC20(WETH).balanceOf(RECEIVER);

        console.log("\n--- Final Balances (Profit Recipient) ---");
        console.log("Address:", RECEIVER);
        console.log("ETH Balance:", ethBalanceAfter, "wei =", formatEther(ethBalanceAfter));
        console.log("WETH Balance:", wethBalanceAfter, "wei =", formatEther(wethBalanceAfter));
        console.log("");

        // 잔액 변화 계산
        console.log("--- Balance Changes ---");
        if (ethBalanceAfter > ethBalanceBefore) {
            console.log("ETH Profit:", ethBalanceAfter - ethBalanceBefore, "wei =", formatEther(ethBalanceAfter - ethBalanceBefore));
        } else if (ethBalanceAfter < ethBalanceBefore) {
            console.log("ETH Loss:", ethBalanceBefore - ethBalanceAfter, "wei =", formatEther(ethBalanceBefore - ethBalanceAfter));
        } else {
            console.log("ETH: No change");
        }

        if (wethBalanceAfter > wethBalanceBefore) {
            console.log("WETH Profit:", wethBalanceAfter - wethBalanceBefore, "wei =", formatEther(wethBalanceAfter - wethBalanceBefore));
        } else if (wethBalanceAfter < wethBalanceBefore) {
            console.log("WETH Loss:", wethBalanceBefore - wethBalanceAfter, "wei =", formatEther(wethBalanceBefore - wethBalanceAfter));
        } else {
            console.log("WETH: No change");
        }

        console.log("\n=== Test Completed Successfully ===\n");
    }
}
