// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

// Boundaries of the Robinhood copy of the audited factory, `VaultFactory(imd_ = 0, feeRecipient_ = 0)`, deployed here
// exactly as the brief names it. Each test pins the last value the audited code still handles correctly; the values
// one step past these limits fail, and those failures are reported in .imd-findings.json rather than asserted here.

contract BdToken is ERC20 {
    constructor() ERC20("BD", "BD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token whose `balanceOf` reverts once broken, to show an ETH withdrawal never reads tracked tokens.
contract BdBreakable is BdToken {
    bool public broken;

    function breakIt() external {
        broken = true;
    }

    function balanceOf(address a) public view override returns (uint256) {
        require(!broken, "broken");
        return super.balanceOf(a);
    }
}

contract RobinhoodBoundariesTest is Test {
    uint256 constant ROBINHOOD = 4663;

    VaultFactory f;
    BdToken token;
    address project = makeAddr("project");
    address team = makeAddr("team");
    address dest = makeAddr("dest");

    function setUp() public {
        vm.chainId(ROBINHOOD);
        vm.warp(1_760_000_000);
        f = new VaultFactory(IERC20(address(0)), address(0));
        token = new BdToken();
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _treasury(uint16 rate) internal returns (TreasuryVault t) {
        vm.prank(project);
        t = f.createTreasury(address(token), team, 1 days, rate, new address[](0));
    }

    // ---------------------------------------------------------------- the factory exactly as briefed

    function test_BriefedArgumentsGiveAFactoryThatChargesNothing() public view {
        assertEq(address(f.imd()), address(0));
        assertEq(f.feeRecipient(), address(0));
        assertEq(f.FEE(), 5e18, "the fee constant is the audited one even where it is not charged");
        assertEq(f.vaultCount(), 0);
    }

    function test_FreeCreationNeedsNoApprovalOfAnythingButTheVestedToken() public {
        token.mint(project, 100e18);
        vm.startPrank(project);
        token.approve(address(f), 100e18);
        VestingVault v = f.createVesting(token, team, 100e18, _now(), 0, 28 days);
        vm.stopPrank();
        assertEq(token.balanceOf(address(v)), 100e18);
        assertEq(token.allowance(project, address(f)), 0, "the factory took exactly the amount");
        assertFalse(f.feePaid(ROBINHOOD, address(token)));
        assertFalse(f.feePaid(1, address(token)));
    }

    function test_SameProjectCanCreateManyVaultsAndEveryOneIsRegistered() public {
        vm.startPrank(project);
        address a = address(f.createTreasury(address(token), team, 1 days, 1, new address[](0)));
        address b = address(f.createTreasury(address(token), team, 30 days, 2500, new address[](0)));
        address c = address(f.createLaunchVesting(team, _now(), 0, 28 days));
        vm.stopPrank();
        address[] memory byToken = f.vaultsByToken(address(token));
        assertEq(byToken.length, 2);
        assertEq(byToken[0], a);
        assertEq(byToken[1], b);
        assertEq(f.vaultsByToken(address(0))[0], c);
        assertEq(f.allVaults(2), c);
        vm.expectRevert();
        f.allVaults(3);
        for (uint256 i; i < 3; ++i) {
            assertEq(f.creatorOf(f.allVaults(i)), project);
            assertTrue(f.isVault(f.allVaults(i)));
        }
    }

    function test_TreasuryWithDelayOneSecondShortOfADayIsRefused() public {
        vm.expectRevert(VaultFactory.BadDelay.selector);
        f.createTreasury(address(token), team, 1 days - 1, 2500, new address[](0));
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        f.createTreasury(address(token), team, 30 days + 1, 2500, new address[](0));
        vm.expectRevert(TreasuryVault.BadRate.selector);
        f.createTreasury(address(token), team, 1 days, 2501, new address[](0));
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        f.createTreasury(address(token), address(0), 1 days, 2500, new address[](0));
        assertEq(f.vaultCount(), 0);
    }

    // ---------------------------------------------------------------- treasury cap arithmetic at its edges

    /// @dev The largest balance whose weekly cap `balance * rateBps` still fits in uint256 withdraws normally. One
    ///      token above it overflows and locks the token (reported, not asserted).
    function test_TreasuryLargestSafeBalanceStillWithdraws() public {
        TreasuryVault t = _treasury(2500);
        uint256 bal = type(uint256).max / 2500;
        token.mint(address(t), bal);
        assertEq(t.availableThisWeek(address(token)), bal / 4);
        vm.prank(team);
        uint256 id = t.queue(address(token), dest, bal / 4);
        skip(1 days);
        t.execute(id);
        assertEq(token.balanceOf(dest), bal / 4);
        assertEq(t.availableThisWeek(address(token)), 0);
    }

    /// @dev A balance too small for the rate to round above zero has a zero cap: nothing leaves, not one wei.
    function test_TreasuryDustBalanceHasZeroCap() public {
        TreasuryVault t = _treasury(1);
        token.mint(address(t), 9_999);
        assertEq(t.availableThisWeek(address(token)), 0);
        vm.prank(team);
        uint256 id = t.queue(address(token), dest, 1);
        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(id);
        token.mint(address(t), 1); // 10_000 * 1 / 10_000 = 1
        t.execute(id);
        assertEq(token.balanceOf(dest), 1);
    }

    /// @dev What the view promises is exactly what `execute` lets out, one wei more is refused.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_AvailableThisWeekIsExactlyWhatExecutes(uint256 bal, uint16 rate) public {
        rate = uint16(bound(rate, 1, 2500));
        bal = bound(bal, 10_000, type(uint256).max / 2500);
        TreasuryVault t = _treasury(rate);
        token.mint(address(t), bal);
        uint256 avail = t.availableThisWeek(address(token));
        assertEq(avail, bal * rate / 10_000);
        vm.startPrank(team);
        uint256 over = t.queue(address(token), dest, avail + 1);
        uint256 exact = t.queue(address(token), dest, avail);
        vm.stopPrank();
        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, avail));
        t.execute(over);
        t.execute(exact);
        assertEq(token.balanceOf(dest), avail);
        assertEq(t.availableThisWeek(address(token)), 0);
    }

    function test_EthWithdrawalNeverReadsTrackedTokens() public {
        BdBreakable bad = new BdBreakable();
        TreasuryVault t = _treasury(2500);
        vm.deal(address(t), 4 ether);
        vm.startPrank(team);
        t.queue(address(bad), dest, 1); // tracks `bad`
        uint256 id = t.queue(address(0), dest, 1 ether);
        vm.stopPrank();
        bad.breakIt();
        skip(1 days);
        t.execute(id);
        assertEq(dest.balance, 1 ether);
        assertEq(t.trackedAssets().length, 1, "ETH is never tracked");
    }

    function test_SameWithdrawalCanNotExecuteTwiceOrAfterCancel() public {
        TreasuryVault t = _treasury(2500);
        token.mint(address(t), 100e18);
        vm.startPrank(team);
        uint256 a = t.queue(address(token), dest, 1e18);
        uint256 b = t.queue(address(token), dest, 1e18);
        t.cancel(b);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.cancel(b);
        vm.stopPrank();
        skip(1 days);
        t.execute(a);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.execute(a);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.execute(b);
        vm.prank(team);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.cancel(a);
        assertEq(token.balanceOf(dest), 1e18);
    }

    function test_StrangerCanNotTouchTheRules() public {
        TreasuryVault t = _treasury(2500);
        address s = makeAddr("stranger");
        vm.startPrank(s);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.queue(address(token), dest, 1);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.increaseDelay(2 days);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.decreaseRate(1);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.restrictDestinations(new address[](1));
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.removeDestination(dest);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.proposeManager(s);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.cancelManager();
        vm.expectRevert(TreasuryVault.NoProposal.selector);
        t.acceptManager();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- vesting arithmetic at its edges

    /// @dev `total * elapsed` stays in range for every elapsed below `duration` as long as `total` is at most
    ///      `type(uint256).max / (duration - 1)`; at that size the vault still releases linearly.
    function test_VestingLargestSafeAllocationReleasesLinearly() public {
        uint64 dur = 28 days;
        uint256 total = type(uint256).max / (dur - 1);
        token.mint(project, total);
        vm.startPrank(project);
        token.approve(address(f), total);
        VestingVault v = f.createVesting(token, team, total, _now(), 0, dur);
        vm.stopPrank();
        skip(dur - 1);
        assertEq(v.releasable(address(token)), total * (dur - 1) / dur);
        v.release(address(token));
        skip(1);
        v.release(address(token));
        assertEq(token.balanceOf(team), total);
        assertEq(token.balanceOf(address(v)), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));
    }

    /// @dev The schedule may end exactly at `type(uint64).max`; one second more is refused at creation.
    function test_VestingScheduleMayEndExactlyAtUint64Max() public {
        uint64 dur = 28 days;
        uint64 cliff = type(uint64).max - _now() - dur;
        VestingVault v = f.createLaunchVesting(team, _now(), cliff, dur);
        assertEq(uint256(v.start()) + v.cliff() + v.duration(), type(uint64).max);
        vm.prank(team);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        v.extendDuration(dur + 1);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        f.createLaunchVesting(team, _now(), cliff + 1, dur);
    }

    /// @dev Exactly one wei of the bound token vests and is released at the end, never before.
    function test_VestingOneWeiReleasesOnlyAtTheEnd() public {
        token.mint(project, 1);
        vm.startPrank(project);
        token.approve(address(f), 1);
        VestingVault v = f.createVesting(token, team, 1, _now(), 7 days, 28 days);
        vm.stopPrank();
        skip(7 days + 28 days - 1);
        assertEq(v.releasable(address(token)), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));
        skip(1);
        v.release(address(token));
        assertEq(token.balanceOf(team), 1);
    }

    function test_VestingReleaseOfZeroAddressOrForeignTokenIsRefused() public {
        token.mint(project, 1e18);
        vm.startPrank(project);
        token.approve(address(f), 1e18);
        VestingVault bound = f.createVesting(token, team, 1e18, _now(), 0, 28 days);
        vm.stopPrank();
        VestingVault open = f.createLaunchVesting(team, _now(), 0, 28 days);
        BdToken other = new BdToken();
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(0)));
        bound.release(address(0));
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(other)));
        bound.release(address(other));
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(0)));
        open.release(address(0));
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(0)));
        open.sync(address(0));
        assertEq(bound.releasable(address(other)), 0);
        assertEq(open.releasable(address(0)), 0);
    }

    function test_VestingBeneficiaryRulesFailurePaths() public {
        VestingVault v = f.createLaunchVesting(team, _now(), 0, 28 days);
        address next = makeAddr("next");
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.proposeBeneficiary(next);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.extendDuration(29 days);
        vm.startPrank(team);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        v.proposeBeneficiary(address(0));
        vm.expectRevert(VestingVault.NoProposal.selector);
        v.cancelBeneficiary();
        vm.expectRevert(VestingVault.NotLonger.selector);
        v.extendDuration(28 days);
        v.proposeBeneficiary(next);
        vm.stopPrank();
        vm.expectRevert(VestingVault.NotPendingBeneficiary.selector);
        v.acceptBeneficiary();
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.TooEarly.selector, _now() + 7 days));
        v.acceptBeneficiary();
        skip(7 days);
        vm.prank(next);
        v.acceptBeneficiary();
        assertEq(v.beneficiary(), next);
        vm.prank(team);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.proposeBeneficiary(team);
    }
}
