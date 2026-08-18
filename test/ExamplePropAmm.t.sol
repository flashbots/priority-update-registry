// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ExamplePropAmm.sol";
import "../src/PrioUpdateRegistryV2.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20Burnable {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ExamplePropAmmTest is Test {
    PrioUpdateRegistryV2 public registry;
    ExamplePropAmm public amm;
    MockERC20 public weth;
    MockERC20 public usdc;

    address public owner = address(this);
    address public marketMaker = address(0x1);
    address public trader = address(0x2);

    bytes32 public wethUsdcPairId;

    uint256 constant MAX_PARAMETER_AGE = 12;

    uint256 constant WETH_DECIMALS = 18;
    uint256 constant USDC_DECIMALS = 6;
    uint256 constant INITIAL_WETH_LIQUIDITY = 100 * 10 ** WETH_DECIMALS;
    uint256 constant INITIAL_USDC_LIQUIDITY = 400000 * 10 ** USDC_DECIMALS;
    uint256 constant WETH_PRICE = 4000;

    function setUp() public {
        vm.warp(1_700_000_000);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        registry = new PrioUpdateRegistryV2();
        amm = new ExamplePropAmm(marketMaker, registry, MAX_PARAMETER_AGE);

        weth.mint(marketMaker, INITIAL_WETH_LIQUIDITY);
        usdc.mint(marketMaker, INITIAL_USDC_LIQUIDITY);

        weth.mint(trader, 10 * 10 ** WETH_DECIMALS);
        usdc.mint(trader, 50000 * 10 ** USDC_DECIMALS);
    }

    function _publishParameters(bytes32 pairId, uint256 concentration, uint256 multX, uint256 multY) internal {
        _publishParametersAt(pairId, block.timestamp, concentration, multX, multY);
    }

    function _publishParametersAt(
        bytes32 pairId,
        uint256 updateTimestamp,
        uint256 concentration,
        uint256 multX,
        uint256 multY
    ) internal {
        uint256[] memory slots = amm.encodeParameterSlots(updateTimestamp, concentration, multX, multY);
        vm.prank(marketMaker);
        registry.updateState(address(amm), uint256(pairId), slots);
    }

    function test_CreatePair() public {
        vm.startPrank(marketMaker);

        bytes32 pairId = amm.createPair(
            address(weth),
            address(usdc),
            100, // initial concentration
            0, // xRetainDecimals
            12 // yRetainDecimals
        );

        vm.stopPrank();

        ExamplePropAmm.TradingPair memory pair = amm.getPair(pairId);
        assertEq(address(pair.tokenX), address(weth));
        assertEq(address(pair.tokenY), address(usdc));
        assertTrue(pair.exists);
    }

    function test_SwapWETHForUSDC() public {
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 1, 0, 12);

        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        vm.stopPrank();

        // Publish parameters via the registry.
        _publishParameters(wethUsdcPairId, 1, 4000, 10 ** 12);

        vm.startPrank(trader);

        uint256 amountWETHIn = 1 * 10 ** WETH_DECIMALS;
        uint256 quotedAmount = amm.quoteXtoY(wethUsdcPairId, amountWETHIn);

        uint256 expectedUSDCOut = 4000 * 10 ** USDC_DECIMALS;

        weth.approve(address(amm), amountWETHIn);

        uint256 traderWETHBefore = weth.balanceOf(trader);
        uint256 traderUSDCBefore = usdc.balanceOf(trader);

        uint256 minUSDCOut = (expectedUSDCOut * 99) / 100;
        uint256 actualUSDCOut = amm.swapXtoY(wethUsdcPairId, amountWETHIn, minUSDCOut);

        uint256 traderWETHAfter = weth.balanceOf(trader);
        uint256 traderUSDCAfter = usdc.balanceOf(trader);

        assertEq(traderWETHBefore - traderWETHAfter, amountWETHIn, "WETH not deducted correctly");
        assertEq(traderUSDCAfter - traderUSDCBefore, actualUSDCOut, "USDC not received correctly");
        assertEq(actualUSDCOut, quotedAmount, "Actual output doesn't match quote");

        assertGe(actualUSDCOut, (expectedUSDCOut * 98) / 100, "Should receive at least 98% of expected");
        assertLe(actualUSDCOut, (expectedUSDCOut * 102) / 100, "Should not receive more than 102% of expected");

        vm.stopPrank();
    }

    function test_SwapUSDCForWETH() public {
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 1, 0, 12);

        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        vm.stopPrank();

        _publishParameters(wethUsdcPairId, 1, 4000, 10 ** 12);

        vm.startPrank(trader);

        uint256 amountUSDCIn = 4000 * 10 ** USDC_DECIMALS;
        uint256 quotedWETH = amm.quoteYtoX(wethUsdcPairId, amountUSDCIn);

        usdc.approve(address(amm), amountUSDCIn);
        uint256 actualWETHOut = amm.swapYtoX(wethUsdcPairId, amountUSDCIn, 0);

        assertEq(actualWETHOut, quotedWETH, "Actual output doesn't match quote");
        assertGt(actualWETHOut, 0, "Should receive some WETH");

        vm.stopPrank();
    }

    function test_OnlyMarketMakerCanDeposit() public {
        vm.startPrank(marketMaker);
        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);
        vm.stopPrank();

        vm.startPrank(trader);
        weth.approve(address(amm), 1 ether);
        vm.expectRevert(ExamplePropAmm.OnlyMarketMaker.selector);
        amm.deposit(wethUsdcPairId, 1 ether, 0);
        vm.stopPrank();
    }

    function test_SlippageProtection() public {
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);
        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        vm.stopPrank();

        _publishParameters(wethUsdcPairId, 100, 4000 * 10 ** 6, 10 ** 18);

        vm.startPrank(trader);
        uint256 amountWETHIn = 1 * 10 ** WETH_DECIMALS;
        uint256 unrealisticMinOut = 5000 * 10 ** USDC_DECIMALS;

        weth.approve(address(amm), amountWETHIn);
        vm.expectRevert(ExamplePropAmm.SlippageExceeded.selector);
        amm.swapXtoY(wethUsdcPairId, amountWETHIn, unrealisticMinOut);
        vm.stopPrank();
    }

    function test_ParameterUpdate() public {
        vm.startPrank(marketMaker);
        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);
        vm.stopPrank();

        uint256 newConcentration = 150;
        uint256 newMultX = 3500 * 10 ** 6;
        uint256 newMultY = 10 ** 18;

        _publishParameters(wethUsdcPairId, newConcentration, newMultX, newMultY);

        ExamplePropAmm.PairParameters memory params = amm.getParameters(wethUsdcPairId);
        assertEq(params.concentration, newConcentration);
        assertEq(params.multX, newMultX);
        assertEq(params.multY, newMultY);
    }

    function test_WithdrawLiquidity() public {
        vm.startPrank(marketMaker);

        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 100, 0, 12);

        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);

        uint256 withdrawWETH = 10 * 10 ** WETH_DECIMALS;
        uint256 withdrawUSDC = 40000 * 10 ** USDC_DECIMALS;

        uint256 balanceBefore = weth.balanceOf(marketMaker);
        amm.withdraw(wethUsdcPairId, withdrawWETH, withdrawUSDC);
        uint256 balanceAfter = weth.balanceOf(marketMaker);

        assertEq(balanceAfter - balanceBefore, withdrawWETH);

        vm.stopPrank();
    }

    // Registry-specific tests.

    function test_StaleParametersRevertsSwap() public {
        vm.startPrank(marketMaker);
        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 1, 0, 12);
        weth.approve(address(amm), INITIAL_WETH_LIQUIDITY);
        usdc.approve(address(amm), INITIAL_USDC_LIQUIDITY);
        amm.deposit(wethUsdcPairId, INITIAL_WETH_LIQUIDITY, INITIAL_USDC_LIQUIDITY);
        vm.stopPrank();

        _publishParameters(wethUsdcPairId, 1, 4000, 10 ** 12);

        vm.warp(block.timestamp + MAX_PARAMETER_AGE + 1);

        vm.startPrank(trader);
        weth.approve(address(amm), 1 ether);
        vm.expectRevert(ExamplePropAmm.StaleParameters.selector);
        amm.swapXtoY(wethUsdcPairId, 1 ether, 0);
        vm.stopPrank();
    }

    function test_FutureParametersRevert() public {
        vm.prank(marketMaker);
        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 1, 0, 12);

        _publishParametersAt(wethUsdcPairId, block.timestamp + 1, 1, 4000, 10 ** 12);

        vm.expectRevert(ExamplePropAmm.StaleParameters.selector);
        amm.getParameters(wethUsdcPairId);
    }

    function test_ZeroTimestampParametersAreNotSet() public {
        vm.prank(marketMaker);
        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 1, 0, 12);

        _publishParametersAt(wethUsdcPairId, 0, 1, 4000, 10 ** 12);

        vm.expectRevert(ExamplePropAmm.ParametersNotSet.selector);
        amm.getParameters(wethUsdcPairId);
    }

    function test_ParameterAgeBoundaryIsAccepted() public {
        vm.prank(marketMaker);
        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 1, 0, 12);

        _publishParametersAt(wethUsdcPairId, block.timestamp - MAX_PARAMETER_AGE, 2, 3000, 10 ** 12);

        ExamplePropAmm.PairParameters memory params = amm.getParameters(wethUsdcPairId);
        assertEq(params.concentration, 2);
        assertEq(params.multX, 3000);
        assertEq(params.multY, 10 ** 12);
    }

    function test_EncodeParameterSlotsIncludesTimestamp() public view {
        uint256[] memory slots = amm.encodeParameterSlots(123, 2, 3000, 10 ** 12);

        assertEq(slots.length, 4);
        assertEq(slots[0], 123);
        assertEq(slots[1], 2);
        assertEq(slots[2], 3000);
        assertEq(slots[3], 10 ** 12);
    }

    function test_UnauthorizedCannotPublishParameters() public {
        vm.prank(marketMaker);
        wethUsdcPairId = amm.createPair(address(weth), address(usdc), 1, 0, 12);

        uint256[] memory slots = amm.encodeParameterSlots(block.timestamp, 1, 4000, 10 ** 12);
        vm.prank(trader);
        vm.expectRevert(PrioUpdateRegistryV2.NotAuthorized.selector);
        registry.updateState(address(amm), uint256(wethUsdcPairId), slots);
    }

    function test_SetMarketMakerRotatesUpdater() public {
        address newMM = address(0xBEEF);
        amm.setMarketMaker(newMM);

        assertFalse(registry.isUpdater(address(amm), marketMaker));
        assertTrue(registry.isUpdater(address(amm), newMM));
        assertEq(amm.marketMaker(), newMM);
    }
}
