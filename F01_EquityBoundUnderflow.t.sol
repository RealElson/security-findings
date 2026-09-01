// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILeverageManager} from "src/interfaces/ILeverageManager.sol";
import {ILeverageToken} from "src/interfaces/ILeverageToken.sol";
import {ILendingAdapter} from "src/interfaces/ILendingAdapter.sol";
import {IPreLiquidationLendingAdapter} from "src/interfaces/IPreLiquidationLendingAdapter.sol";
import {IPreLiquidationRebalanceAdapter} from "src/interfaces/IPreLiquidationRebalanceAdapter.sol";
import {IDutchAuctionRebalanceAdapter} from "src/interfaces/IDutchAuctionRebalanceAdapter.sol";
import {ICollateralRatiosRebalanceAdapter} from "src/interfaces/ICollateralRatiosRebalanceAdapter.sol";
import {RebalanceAction, ActionType, LeverageTokenState} from "src/types/DataTypes.sol";

/// @dev Fork verification of F-01: the unchecked `stateBefore.equity - maxEquityLoss` at
///      PreLiquidationRebalanceAdapter.sol:116.
///
///      Target is the live RLP-USDC-6.75x LeverageToken on Ethereum mainnet, which at the pinned
///      block is insolvent: collateralRatio 0.0517, getEquityInDebtAsset() == 0.
///
///      Run: ETH_RPC_URL=https://eth.drpc.org FOUNDRY_PROFILE=lite \
///           forge test --match-path test/poc/F01_EquityBoundUnderflow.t.sol -vv
contract F01_EquityBoundUnderflow is Test {
    uint256 constant FORK_BLOCK = 25881451;

    ILeverageManager constant LM = ILeverageManager(0x5C37EB148D4a261ACD101e2B997A0F163Fb3E351);
    ILeverageToken constant LT = ILeverageToken(0x6426811fF283Fa7c78F0BC5D71858c2f79c0Fc3d);
    ILendingAdapter constant LA = ILendingAdapter(0xe33Eaf6EE64f4B9353ff2ce3748FA05EEb9bd809);
    address constant RA = 0x5E6b01ca7a604F0C7b5A97B7dE6D2D46d9C30110;

    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant RLP = IERC20(0x4956b52aE2fF65D74CA2d61207523288e4528f96);

    uint256 constant WAD = 1e18;

    address keeper = makeAddr("keeper");
    address rescuer = makeAddr("rescuer");

    uint256 r; // liquidationPenalty * rebalanceReward / REWARD_BASE, WAD-scaled
    uint256 target;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        uint256 penalty = IPreLiquidationLendingAdapter(address(LA)).getLiquidationPenalty();
        uint256 reward = IPreLiquidationRebalanceAdapter(RA).getRebalanceReward();
        r = penalty * reward / 1e4;
        target = ICollateralRatiosRebalanceAdapter(RA).getLeverageTokenTargetCollateralRatio();

        vm.label(address(LM), "LeverageManager");
        vm.label(address(LA), "MorphoLendingAdapter");
        vm.label(RA, "RebalanceAdapter");
    }

    /* ------------------------------------------------------------------ helpers */

    function _state() internal view returns (LeverageTokenState memory) {
        return LM.getLeverageTokenState(LT);
    }

    function _log(string memory tag) internal view {
        LeverageTokenState memory s = _state();
        console.log(tag);
        console.log("  collateralInDebtAsset", s.collateralInDebtAsset);
        console.log("  debt                 ", s.debt);
        console.log("  equity               ", s.equity);
        console.log("  collateralRatio      ", s.collateralRatio);
    }

    function _fund(uint256 amount) internal {
        deal(address(USDC), keeper, amount);
        vm.prank(keeper);
        USDC.approve(address(LM), amount);
    }

    function _repayAction(uint256 amount) internal pure returns (RebalanceAction[] memory a) {
        a = new RebalanceAction[](1);
        a[0] = RebalanceAction({actionType: ActionType.Repay, amount: amount});
    }

    /// @dev A pure-repay rebalance: keeper hands over USDC and takes nothing back. This is the
    ///      shape of a good-faith deleveraging, and the only shape Morpho permits while the
    ///      position is unhealthy (any RemoveCollateral reverts on the health check).
    function repayOnlyRebalance(uint256 amount) external {
        _fund(amount);
        vm.prank(keeper);
        LM.rebalance(LT, _repayAction(amount), USDC, IERC20(address(0)), amount, 0);
    }

    /// @dev Repay straight on the lending adapter, bypassing LeverageManager entirely.
    function _donateRepay(uint256 amount) internal {
        deal(address(USDC), rescuer, amount);
        vm.startPrank(rescuer);
        USDC.approve(address(LA), amount);
        LA.repay(amount);
        vm.stopPrank();
    }

    function _rescueToRatio(uint256 ratio) internal {
        uint256 c = LA.getCollateralInDebtAsset();
        uint256 d = LA.getDebt();
        _donateRepay(d - (c * WAD / ratio));
    }

    /// @dev The two competing caps on a pure repay, both in debt-asset units.
    function _caps() internal view returns (uint256 ratioCap, uint256 equityCap) {
        LeverageTokenState memory s = _state();
        ratioCap = s.debt - (s.collateralInDebtAsset * WAD / target); // CR_after <= target
        equityCap = s.equity * WAD / r; // debtDelta * r <= equity
    }

    /* --------------------------------------------- 1. is the underflow reachable? */

    function test_F01_realRebalanceRevertsWithPanic() public {
        _log("BEFORE (live mainnet state)");
        assertEq(_state().equity, 0, "precondition: equity clamped to zero");
        assertTrue(
            IPreLiquidationRebalanceAdapter(RA).isEligibleForRebalance(LT, _state(), keeper),
            "eligible via the PreLiquidation branch"
        );

        // 1 USDC pure repay. Strictly improves the position, extracts nothing.
        vm.expectRevert(stdError.arithmeticError);
        this.repayOnlyRebalance(1e6);

        console.log("rebalance([Repay 1 USDC]) reverted with Panic(0x11)");
    }

    /// @dev Only repayments where maxEquityLoss floors to zero survive: debtDelta < WAD / r.
    function test_F01_boundaryIsFloorOfMaxEquityLoss() public {
        uint256 boundary = WAD / r;
        console.log("largest surviving repay, in wei of USDC:", boundary);
        assertEq(boundary, 45, "45 wei == 0.000045 USDC");

        this.repayOnlyRebalance(boundary); // maxEquityLoss == 0
        console.log("repay of 45 wei succeeded");

        vm.expectRevert(stdError.arithmeticError);
        this.repayOnlyRebalance(boundary + 1); // maxEquityLoss == 1
        console.log("repay of 46 wei reverted with Panic(0x11)");
    }

    /* ------------------------------------------- 2. does it actually brick take()? */

    /// @dev take() routes through the same LeverageManager.rebalance and would hit the same
    ///      check - but it also removes collateral, which Morpho refuses while unhealthy. This
    ///      records which revert actually fires first.
    function test_F01_takePathOnInsolventToken() public {
        IDutchAuctionRebalanceAdapter auction = IDutchAuctionRebalanceAdapter(RA);
        auction.createAuction();

        (bool eligible, bool over) = auction.getLeverageTokenRebalanceStatus();
        console.log("auction created. eligible:", eligible);
        console.log("isOverCollateralized:", over);

        uint256 amountOut = 1e18; // 1 RLP of collateral
        uint256 amountIn = auction.getAmountIn(amountOut);
        console.log("take(1 RLP) costs, in USDC:", amountIn);

        deal(address(USDC), keeper, amountIn);
        vm.startPrank(keeper);
        USDC.approve(RA, amountIn);
        (bool ok, bytes memory err) = RA.call(abi.encodeWithSignature("take(uint256)", amountOut));
        vm.stopPrank();

        assertFalse(ok, "take must fail on an insolvent token");
        bool isPanic = err.length == 36 && bytes4(err) == bytes4(0x4e487b71);
        console.log("take() reverted. arithmetic panic?", isPanic);
        console.log("revert data:");
        console.logBytes(err);
    }

    /* ------------------------------------------------ 3. is the brick zone real? */

    /// @dev Just above zero equity the equity bound is the tighter of the two caps, so a repay
    ///      that the ratio check would allow still underflows.
    function test_F01_brickZone_equityBoundBindsFirst() public {
        _rescueToRatio(1.002e18);
        _log("AFTER donating down to CR 1.002");

        (uint256 ratioCap, uint256 equityCap) = _caps();
        console.log("max repay allowed by ratio cap :", ratioCap);
        console.log("max repay allowed by equity cap:", equityCap);
        assertLt(equityCap, ratioCap, "equity bound binds first inside the zone");

        // Each probe must start from the same state, so snapshot around them.
        uint256 snap = vm.snapshotState();
        this.repayOnlyRebalance(equityCap / 2);
        console.log("repay under the equity cap succeeded. CR now:", _state().collateralRatio);
        vm.revertToState(snap);

        // Ratio-legal (CR_after stays under target) but over the equity cap.
        uint256 probe = (equityCap + ratioCap) / 2;
        uint256 crAfter = _state().collateralInDebtAsset * WAD / (_state().debt - probe);
        assertLt(crAfter, target, "probe is ratio-legal");
        assertGt(probe * r / WAD, _state().equity, "probe exceeds the equity bound");

        vm.expectRevert(stdError.arithmeticError);
        this.repayOnlyRebalance(probe);
        console.log("ratio-legal repay above the equity cap reverted with Panic(0x11)");
    }

    /// @dev Higher up, the ratio cap is tighter, so the underflow is unreachable by pure repay.
    function test_F01_brickZone_upperEdge() public {
        _rescueToRatio(1.01e18);
        _log("AFTER donating down to CR 1.01");

        (uint256 ratioCap, uint256 equityCap) = _caps();
        console.log("max repay allowed by ratio cap :", ratioCap);
        console.log("max repay allowed by equity cap:", equityCap);
        assertLt(ratioCap, equityCap, "ratio cap now binds first");

        this.repayOnlyRebalance(ratioCap - 1);
        _log("AFTER the largest ratio-legal repay");
    }

    /// @dev Locate the true edge: the largest CR at which the equity bound still binds first.
    function test_F01_brickZone_boundary() public {
        uint256 lo = 1.0000e18;
        uint256 hi = 1.0300e18;
        for (uint256 i = 0; i < 24; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            _rescueToRatio(mid);
            (uint256 ratioCap, uint256 equityCap) = _caps();
            bool bricked = equityCap < ratioCap;
            vm.revertToState(snap);
            if (bricked) lo = mid;
            else hi = mid;
        }
        console.log("underflow reachable for CR below:", lo);
        console.log("1 + r for reference           :", WAD + r);
        console.log("liquidation boundary 1/LLTV   :", uint256(1162790697674418604));
    }

    /* --------------------------------------------- 4. does the escape hatch work? */

    function test_F01_escapeHatch_directRepayThenRebalanceWorks() public {
        vm.expectRevert(stdError.arithmeticError);
        this.repayOnlyRebalance(1e6);
        console.log("BEFORE: rebalance([Repay 1 USDC]) reverts");

        uint256 debtBefore = LA.getDebt();

        // MorphoLendingAdapter.repay (line 197) carries no onlyLeverageManager modifier.
        vm.expectRevert(); // sanity: the gated side is not open
        vm.prank(rescuer);
        LA.removeCollateral(1);

        _rescueToRatio(1.165e18);

        assertLt(LA.getDebt(), debtBefore, "escape hatch reduced the debt");
        assertGt(_state().equity, 0, "position is solvent again");
        _log("AFTER escape-hatch rescue to CR 1.165");

        this.repayOnlyRebalance(1e6);
        console.log("AFTER: the identical rebalance succeeds");
        _log("AFTER the rebalance that previously reverted");
    }

    /// @dev And the full pre-liquidation mechanism - repay plus the rewarded collateral pull -
    ///      works normally once out of the zone, taking no more than maxEquityLoss.
    function test_F01_profitableRebalanceWorksAfterRescue() public {
        _rescueToRatio(1.165e18);

        LeverageTokenState memory bef = _state();
        uint256 repayAmount = 1_000e6;
        uint256 collateralOut = LA.convertDebtToCollateralAsset(repayAmount + (repayAmount * r / WAD));

        _fund(repayAmount);
        RebalanceAction[] memory actions = new RebalanceAction[](2);
        actions[0] = RebalanceAction({actionType: ActionType.Repay, amount: repayAmount});
        actions[1] = RebalanceAction({actionType: ActionType.RemoveCollateral, amount: collateralOut});

        vm.prank(keeper);
        LM.rebalance(LT, actions, USDC, RLP, repayAmount, collateralOut);

        LeverageTokenState memory aft = _state();
        uint256 equityLost = bef.equity - aft.equity;
        uint256 bound = repayAmount * r / WAD;
        console.log("keeper repaid (USDC)  :", repayAmount);
        console.log("keeper received (RLP) :", RLP.balanceOf(keeper));
        console.log("equity lost to keeper :", equityLost);
        console.log("maxEquityLoss bound   :", bound);
        assertLe(equityLost, bound, "keeper take is capped by the bound");
        assertGt(RLP.balanceOf(keeper), 0, "keeper was paid in collateral");
        assertLe(aft.collateralRatio, target, "ratio cap held");
    }
}
