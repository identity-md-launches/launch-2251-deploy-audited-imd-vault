// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VaultFactoryNoFee} from "../src/VaultFactoryNoFee.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

contract AuditToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token with two entry points to one balance, like TrueUSD's legacy contract: `legacy` forwards transfers
///      into the main token on behalf of its caller.
contract DoubleEntryToken is AuditToken {
    address public legacy;

    constructor() AuditToken("DBL") {}

    function setLegacy(address legacy_) external {
        legacy = legacy_;
    }

    function transferFor(address from, address to, uint256 amount) external {
        require(msg.sender == legacy, "not legacy");
        _transfer(from, to, amount);
    }
}

contract LegacyEntry {
    DoubleEntryToken immutable main;

    constructor(DoubleEntryToken main_) {
        main = main_;
    }

    function balanceOf(address a) external view returns (uint256) {
        return main.balanceOf(a);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        main.transferFor(msg.sender, to, amount);
        return true;
    }
}

/// @dev Burns 1% of every transfer.
contract AuditFeeToken is AuditToken {
    constructor() AuditToken("FEE") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev A token with a uint256-max supply, as some meme tokens have.
contract MaxSupplyToken is ERC20 {
    constructor() ERC20("MAX", "MAX") {
        _mint(msg.sender, type(uint256).max);
    }
}

/// @dev A tracked token that turns hostile: while `hostile`, `balanceOf` burns every unit of gas it is given.
contract GasBurningToken is AuditToken {
    bool public hostile;

    constructor() AuditToken("BURN") {}

    function setHostile(bool h) external {
        hostile = h;
    }

    function balanceOf(address a) public view override returns (uint256) {
        if (hostile) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        return super.balanceOf(a);
    }
}

/// @dev A tracked token that turns hostile: while `hostile`, `balanceOf` tries to return a 1 MiB payload.
contract PayloadBombToken is AuditToken {
    bool public hostile;

    constructor() AuditToken("BOMB") {}

    function setHostile(bool h) external {
        hostile = h;
    }

    function balanceOf(address a) public view override returns (uint256) {
        if (hostile) {
            assembly {
                return(0, 0x100000)
            }
        }
        return super.balanceOf(a);
    }
}

/// @dev A second entry point whose `balanceOf` is expensive but honest (about 60k gas of work before it answers),
///      like a token that derives balances from several storage reads: it must still be read under the stipend.
contract SlowLegacyEntry {
    DoubleEntryToken immutable main;
    uint256[] private pad;

    constructor(DoubleEntryToken main_) {
        main = main_;
        for (uint256 i; i < 25; ++i) {
            pad.push(i + 1);
        }
    }

    function balanceOf(address a) external view returns (uint256) {
        uint256 sink;
        for (uint256 i; i < pad.length; ++i) {
            sink += pad[i]; // 25 cold reads, about 55k gas
        }
        return sink == 0 ? 0 : main.balanceOf(a);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        main.transferFor(msg.sender, to, amount);
        return true;
    }
}

/// @notice One test per audit finding fixed in ADAPTATION.md. Each reproduced on the code as it arrived.
contract AuditTest is Test {
    address radar = makeAddr("radar");
    address project = makeAddr("project");
    address team = makeAddr("team");
    address multisig = makeAddr("multisig");
    address stranger = makeAddr("stranger");

    AuditToken imd;
    AuditToken token;
    VaultFactory factory;

    function setUp() public {
        vm.warp(1_760_000_000);
        imd = new AuditToken("IMD");
        token = new AuditToken("PROJ");
        factory = new VaultFactory(IERC20(address(imd)), radar);
        imd.mint(project, 1000e18);
        token.mint(project, 10_000_000e18);
        vm.startPrank(project);
        imd.approve(address(factory), type(uint256).max);
        token.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function _open(uint64 start, uint64 cliff, uint64 duration) internal returns (VestingVault v) {
        vm.prank(project);
        v = factory.createLaunchVesting(team, start, cliff, duration);
    }

    // =================== 55055564: a start in the past unlocked everything at creation ===================

    function test_VestingRejectsStartInThePast() public {
        uint64 now_ = uint64(block.timestamp);
        vm.startPrank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1_000_000e18, now_ - 28 days, 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1_000_000e18, now_ - 1, 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createLaunchVesting(team, now_ - 1, 0, 28 days);
        // Now and later are fine, and nothing is moved by the refused calls.
        VestingVault v = factory.createVesting(IERC20(address(token)), team, 1_000_000e18, now_, 0, 28 days);
        factory.createLaunchVesting(team, now_ + 30 days, 0, 28 days);
        vm.stopPrank();
        assertEq(token.balanceOf(project), 9_000_000e18);
        assertEq(v.releasable(address(token)), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(v.releasable(address(token)), 250_000e18);
    }

    /// @dev The audit's proof, kept as a regression: whatever the start, at most 25% leaves in the first week.
    function testFuzz_VestingNeverMoreThan25PercentInFirstWeek(uint64 start, uint64 cliff, uint64 duration) public {
        duration = uint64(bound(duration, 28 days, 4 * 365 days));
        cliff = uint64(bound(cliff, 0, 365 days));
        start = uint64(bound(start, 0, block.timestamp + 365 days));
        vm.prank(project);
        try factory.createVesting(IERC20(address(token)), team, 1_000_000e18, start, cliff, duration) returns (
            VestingVault v
        ) {
            assertGe(start, block.timestamp);
            vm.warp(block.timestamp + 7 days);
            assertLe(v.releasable(address(token)), 250_000e18 + 1);
        } catch (bytes memory err) {
            assertEq(bytes4(err), VestingVault.BadSchedule.selector);
            assertLt(start, block.timestamp);
        }
    }

    // =================== 5dbb3b32: tokens that reach an open vault late unlocked on arrival ===================

    function test_LateArrivalVestsFromArrival() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        vm.warp(block.timestamp + 28 days); // the launch slips past the whole schedule
        token.mint(address(v), 1_000_000e18);

        // Nothing vests until the arrival is recorded, and nothing on the arrival itself.
        assertEq(v.unlockStart(address(token)), 0);
        assertEq(v.releasable(address(token)), 0);
        vm.prank(stranger);
        v.sync(address(token));
        assertEq(v.arrivedAt(address(token)), uint64(block.timestamp));
        assertEq(v.unlockStart(address(token)), uint64(block.timestamp));
        assertEq(v.releasable(address(token)), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));

        // Then the chosen schedule, from the arrival: 25% a week over four weeks.
        vm.warp(block.timestamp + 7 days);
        assertEq(v.releasable(address(token)), 250_000e18);
        v.release(address(token));
        assertEq(token.balanceOf(team), 250_000e18);
        vm.warp(block.timestamp + 21 days);
        v.release(address(token));
        assertEq(token.balanceOf(team), 1_000_000e18);
    }

    function test_ArrivalInsideTheCliffKeepsTheSchedule() public {
        uint64 start = uint64(block.timestamp);
        VestingVault v = _open(start, 14 days, 28 days);
        vm.warp(block.timestamp + 3 days); // the launch is a little late but still inside the cliff
        token.mint(address(v), 1000e18);
        v.sync(address(token));
        assertEq(v.unlockStart(address(token)), start + 14 days);
        vm.warp(start + 14 days);
        assertEq(v.releasable(address(token)), 0);
        vm.warp(start + 21 days);
        assertEq(v.releasable(address(token)), 250e18);
    }

    function test_FirstReleaseOfANewTokenOnlyStartsItsClock() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        vm.warp(block.timestamp + 10 days);
        token.mint(address(v), 1000e18);
        vm.expectEmit(true, false, false, true, address(v));
        emit VestingVault.Arrived(address(token), uint64(block.timestamp));
        v.release(address(token)); // records the arrival, pays nothing, and keeps the record (no revert)
        assertEq(token.balanceOf(team), 0);
        assertEq(v.arrivedAt(address(token)), uint64(block.timestamp));
        vm.warp(block.timestamp + 7 days);
        v.release(address(token));
        assertEq(token.balanceOf(team), 250e18);
    }

    function test_SyncIsIdempotentAndNeedsABalance() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        v.sync(address(token)); // holds none yet: nothing recorded
        assertEq(v.arrivedAt(address(token)), 0);
        token.mint(address(v), 1e18);
        v.sync(address(token));
        uint64 first = v.arrivedAt(address(token));
        vm.warp(block.timestamp + 5 days);
        v.sync(address(token));
        assertEq(v.arrivedAt(address(token)), first); // a second call never moves the clock
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(0)));
        v.sync(address(0));
    }

    function test_EachTokenInAnOpenVaultHasItsOwnClock() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        token.mint(address(v), 1000e18);
        v.sync(address(token));
        vm.warp(block.timestamp + 14 days);
        imd.mint(address(v), 100e18);
        v.sync(address(imd));
        assertEq(v.releasable(address(token)), 500e18);
        assertEq(v.releasable(address(imd)), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(v.releasable(address(token)), 750e18);
        assertEq(v.releasable(address(imd)), 25e18);
    }

    function test_BoundVaultHasNoArrivalClock() public {
        vm.prank(project);
        VestingVault v =
            factory.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 100 days);
        assertEq(v.unlockStart(address(token)), uint64(block.timestamp));
        v.sync(address(token));
        assertEq(v.arrivedAt(address(token)), 0);
        vm.warp(block.timestamp + 50 days);
        vm.prank(project);
        token.transfer(address(v), 1000e18); // a top-up still follows the calendar schedule, as the README says
        assertEq(v.releasable(address(token)), 1000e18);
    }

    function testFuzz_LateArrivalNeverUnlocksMoreThan25PercentInAWeek(
        uint256 amount,
        uint64 cliff,
        uint64 duration,
        uint64 slip,
        uint64 at
    ) public {
        amount = bound(amount, 1e6, 1_000_000e18);
        duration = uint64(bound(duration, 28 days, 4 * 365 days));
        cliff = uint64(bound(cliff, 0, 365 days));
        slip = uint64(bound(slip, 0, 2 * 365 days));
        VestingVault v = _open(uint64(block.timestamp), cliff, duration);
        vm.warp(block.timestamp + slip);
        token.mint(address(v), amount);
        v.sync(address(token));
        assertEq(v.releasable(address(token)), 0, "unlocked on arrival");
        uint64 t = uint64(bound(at, block.timestamp, block.timestamp + cliff + duration));
        uint256 week = v.vestedAmount(address(token), t + 7 days) - v.vestedAmount(address(token), t);
        assertLe(week, amount / 4 + 1);
    }

    // =================== 9267dfb4: the real bound of the fixed-epoch weekly cap, now documented ===================

    function test_TreasuryEpochBoundaryBoundIsRatePlusRateOfRemainder() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        token.mint(address(t), 10_000e18);
        vm.startPrank(project);
        uint256 a = t.queue(address(token), multisig, 2_500e18);
        uint256 b = t.queue(address(token), multisig, 1_875e18);
        uint256 c = t.queue(address(token), multisig, 1);
        vm.stopPrank();
        uint256 boundary = ((block.timestamp + 1 days) / t.EPOCH() + 1) * t.EPOCH();
        vm.warp(boundary - 1);
        t.execute(a);
        vm.warp(boundary);
        t.execute(b);
        // 25% + 25% of the remaining 75% = 43.75% across the boundary, and not a wei more this week.
        assertEq(token.balanceOf(multisig), 4_375e18);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(c);
    }

    // =================== ea7dc628: an overflowing schedule trapped the tokens forever ===================

    function test_VestingRejectsOverflowingSchedule() public {
        vm.startPrank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1000e18, type(uint64).max, 1, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1000e18, type(uint64).max - 28 days + 1, 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createLaunchVesting(team, type(uint64).max - 10 days, 0, 28 days);
        // The largest schedule that fits is accepted, and no tokens moved for the refused ones.
        VestingVault v =
            factory.createVesting(IERC20(address(token)), team, 1000e18, type(uint64).max - 28 days, 0, 28 days);
        vm.stopPrank();
        assertEq(token.balanceOf(project), 10_000_000e18 - 1000e18);
        assertEq(v.releasable(address(token)), 0);
        assertEq(v.vestedAmount(address(token), type(uint64).max), 1000e18);
    }

    function test_ExtendDurationCannotOverflowTheSchedule() public {
        vm.prank(project);
        VestingVault v =
            factory.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 28 days);
        vm.prank(team);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        v.extendDuration(type(uint64).max);
        vm.prank(team);
        v.extendDuration(365 days);
        assertEq(v.duration(), 365 days);
    }

    // =================== 5f526bd2: recover() moved the vested token through a second entry point ===================

    function test_RecoverRefusesASecondEntryPointToTheVestedToken() public {
        DoubleEntryToken dbl = new DoubleEntryToken();
        LegacyEntry legacy = new LegacyEntry(dbl);
        dbl.setLegacy(address(legacy));
        dbl.mint(project, 1000e18);
        vm.startPrank(project);
        dbl.approve(address(factory), type(uint256).max);
        VestingVault v =
            factory.createVesting(IERC20(address(dbl)), team, 1000e18, uint64(block.timestamp), 365 days, 28 days);
        vm.stopPrank();

        vm.expectRevert(VestingVault.VestingToken.selector);
        v.recover(IERC20(address(legacy)));
        assertEq(dbl.balanceOf(address(v)), 1000e18);
        assertEq(dbl.balanceOf(team), 0);

        // A genuinely different token still comes back to the beneficiary.
        imd.mint(address(v), 5e18);
        v.recover(IERC20(address(imd)));
        assertEq(imd.balanceOf(team), 5e18);
    }

    function test_OpenVaultRecoverAlwaysRefuses() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        vm.expectRevert(VestingVault.VestingToken.selector);
        v.recover(IERC20(address(0)));
        vm.expectRevert(VestingVault.VestingToken.selector);
        v.recover(IERC20(address(imd)));
    }

    // =================== 6a087594: the 24h floor is now in the treasury itself ===================

    function test_TreasuryConstructorEnforcesMinDelay() public {
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        new TreasuryVault(address(token), project, 0, 2500, new address[](0));
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        new TreasuryVault(address(token), project, 1 days - 1, 2500, new address[](0));
        TreasuryVault t = new TreasuryVault(address(token), project, 1 days, 2500, new address[](0));
        assertEq(t.delay(), 1 days);
        assertEq(t.MIN_DELAY(), factory.MIN_DELAY());
    }

    // =================== c693ed06: the weekly cap was per address, so two entry points to one balance got two ===================

    function _doubleEntry() internal returns (DoubleEntryToken dbl, LegacyEntry legacy, TreasuryVault t) {
        dbl = new DoubleEntryToken();
        legacy = new LegacyEntry(dbl);
        dbl.setLegacy(address(legacy));
        vm.prank(project);
        t = factory.createTreasury(address(dbl), project, 1 days, 2500, new address[](0));
        dbl.mint(address(t), 1000e18);
    }

    function test_TreasuryCapIsSharedByTwoEntryPointsToOneBalance() public {
        (DoubleEntryToken dbl, LegacyEntry legacy, TreasuryVault t) = _doubleEntry();
        vm.startPrank(project);
        uint256 a = t.queue(address(dbl), multisig, 250e18);
        uint256 b = t.queue(address(legacy), multisig, 187.5e18);
        uint256 c = t.queue(address(legacy), multisig, 1);
        vm.stopPrank();
        address[] memory tracked = t.trackedAssets();
        assertEq(tracked.length, 2);
        assertTrue(t.isTracked(address(dbl)) && t.isTracked(address(legacy)));

        vm.warp(block.timestamp + 1 days);
        // The main-address withdrawal is charged to the legacy address's window as well.
        vm.expectEmit(true, true, false, true, address(t));
        emit TreasuryVault.SharedBalanceCharged(a, address(legacy), 250e18);
        t.execute(a);
        assertEq(dbl.balanceOf(multisig), 250e18);
        assertEq(t.availableThisWeek(address(legacy)), 0);
        // So nothing more leaves through the second address this epoch, not even a wei.
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(b);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(c);
        assertEq(dbl.balanceOf(multisig), 250e18);

        // Next epoch, the legacy address can withdraw its 25% of what is left, and then the main address is capped.
        vm.warp((block.timestamp / t.EPOCH() + 1) * t.EPOCH());
        vm.prank(project);
        uint256 d = t.queue(address(dbl), multisig, 1);
        vm.warp(block.timestamp + 1 days);
        t.execute(b);
        assertEq(dbl.balanceOf(multisig), 437.5e18);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(d);
    }

    function test_TreasuryCapThroughLegacyAddressFirstIsSharedToo() public {
        (DoubleEntryToken dbl, LegacyEntry legacy, TreasuryVault t) = _doubleEntry();
        vm.startPrank(project);
        uint256 a = t.queue(address(legacy), multisig, 250e18);
        uint256 b = t.queue(address(dbl), multisig, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        t.execute(a);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(b);
        assertEq(dbl.balanceOf(multisig), 250e18);
    }

    function test_TreasuryTrackedAssetsNeverBlockOtherWithdrawals() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        token.mint(address(t), 1000e18);
        imd.mint(address(t), 100e18);
        vm.startPrank(project);
        uint256 junk = t.queue(stranger, multisig, 1); // an address without code, queued by mistake
        uint256 a = t.queue(address(token), multisig, 250e18);
        uint256 b = t.queue(address(imd), multisig, 25e18);
        uint256 eth = t.queue(address(0), multisig, 1 ether);
        vm.stopPrank();
        vm.deal(address(t), 4 ether);
        assertEq(t.trackedAssets().length, 3); // ETH is never tracked: a token transfer can not move it
        vm.warp(block.timestamp + 1 days);
        t.execute(a); // the unreadable asset is skipped, and an unrelated token's balance does not fall
        t.execute(b);
        t.execute(eth);
        assertEq(token.balanceOf(multisig), 250e18);
        assertEq(imd.balanceOf(multisig), 25e18);
        assertEq(multisig.balance, 1 ether);
        assertEq(t.availableThisWeek(address(imd)), 0);
        vm.expectRevert(); // the junk asset itself still can not be withdrawn
        t.execute(junk);
    }

    // =================== 960ccd81: a longer delay revived an expired withdrawal ===================

    function test_IncreaseDelayNeverRevivesAnExpiredWithdrawal() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        token.mint(address(t), 1000e18);
        uint64 t0 = uint64(block.timestamp);
        vm.prank(project);
        uint256 id = t.queue(address(token), multisig, 250e18);
        (,,,, uint64 expiresAt,) = t.withdrawals(id);
        assertEq(expiresAt, t0 + 1 days + t.GRACE());

        vm.warp(t0 + 20 days);
        vm.expectRevert(TreasuryVault.Expired.selector);
        t.execute(id);
        vm.prank(project);
        t.increaseDelay(20 days);
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.Expired.selector);
        t.execute(id);
        assertEq(token.balanceOf(multisig), 0);
    }

    function test_IncreaseDelayPastTheExpiryClosesAQueuedWithdrawal() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        token.mint(address(t), 1000e18);
        uint64 t0 = uint64(block.timestamp);
        vm.startPrank(project);
        uint256 id = t.queue(address(token), multisig, 250e18);
        t.increaseDelay(20 days); // due T0+20d, expiry stays T0+15d: never executable, must be requeued
        vm.stopPrank();
        vm.warp(t0 + 10 days);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TooEarly.selector, t0 + 20 days));
        t.execute(id);
        vm.warp(t0 + 20 days);
        vm.expectRevert(TreasuryVault.Expired.selector);
        t.execute(id);
        // A fresh announcement under the new delay works as before.
        vm.prank(project);
        uint256 again = t.queue(address(token), multisig, 250e18);
        vm.warp(block.timestamp + 20 days);
        t.execute(again);
        assertEq(token.balanceOf(multisig), 250e18);
    }

    // =================== 5811a810: a pending manager change kept the delay it was proposed with ===================

    function test_PendingManagerFollowsTheCurrentDelay() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        uint64 t0 = uint64(block.timestamp);
        vm.startPrank(project);
        t.proposeManager(multisig);
        assertEq(t.pendingManagerEta(), t0 + 1 days);
        t.increaseDelay(30 days);
        vm.stopPrank();
        assertEq(t.pendingManagerEta(), t0 + 30 days);
        vm.warp(t0 + 1 days);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TooEarly.selector, t0 + 30 days));
        t.acceptManager();
        vm.warp(t0 + 30 days);
        vm.prank(multisig);
        t.acceptManager();
        assertEq(t.manager(), multisig);
        assertEq(t.pendingManagerEta(), 0);
    }

    // =================== 8d4b11e3 and 28e462ee: who created a vault, and what it really received ===================

    function test_FactoryRecordsTheCreatorOfEveryVault() public {
        vm.prank(project);
        VestingVault v =
            factory.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 28 days);
        assertEq(factory.creatorOf(address(v)), project);
        // The fee for this token is paid, so a stranger's treasury under it is free, but it is filed as theirs.
        vm.prank(stranger);
        vm.expectEmit(true, true, true, true, address(factory));
        emit VaultFactory.TreasuryCreated(
            vm.computeCreateAddress(address(factory), vm.getNonce(address(factory))),
            address(token),
            stranger,
            stranger,
            1 days,
            1,
            new address[](0)
        );
        TreasuryVault t = factory.createTreasury(address(token), stranger, 1 days, 1, new address[](0));
        assertEq(factory.creatorOf(address(t)), stranger);
        assertEq(imd.balanceOf(radar), 5e18);
        vm.prank(project);
        VestingVault open = factory.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days);
        assertEq(factory.creatorOf(address(open)), project);
        assertEq(factory.creatorOf(stranger), address(0));
    }

    function test_VestingCreatedLogsWhatTheVaultReceived() public {
        AuditFeeToken fee = new AuditFeeToken();
        fee.mint(project, 1000e18);
        vm.startPrank(project);
        fee.approve(address(factory), type(uint256).max);
        uint64 now_ = uint64(block.timestamp);
        vm.expectEmit(true, true, true, true, address(factory));
        emit VaultFactory.VestingCreated(
            vm.computeCreateAddress(address(factory), vm.getNonce(address(factory))),
            address(fee),
            team,
            project,
            990e18,
            now_,
            0,
            28 days
        );
        VestingVault v = factory.createVesting(IERC20(address(fee)), team, 1000e18, now_, 0, 28 days);
        vm.stopPrank();
        assertEq(fee.balanceOf(address(v)), 990e18);
    }

    // =================== Robinhood launch (chain 4663): the fixes below were made for it ===================

    // =================== d9f3f847: the Ethereum constructor arguments brick the factory on Robinhood ===================

    function test_RobinhoodFactoryWithZeroArgumentsCreatesVaultsAndTakesNoFee() public {
        vm.chainId(4663);
        // The Ethereum manifest's arguments: IMD has no code on 4663, so every creation path reverts in the fee.
        VaultFactory wrong = new VaultFactory(IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7), radar);
        vm.prank(project);
        vm.expectRevert();
        wrong.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days);
        assertEq(wrong.vaultCount(), 0);

        // The brief's arguments for this chain: both zero, no fee, no token call, every path works.
        VaultFactory free = new VaultFactory(IERC20(address(0)), address(0));
        assertEq(address(free.imd()), address(0));
        assertEq(free.feeRecipient(), address(0));
        vm.startPrank(project);
        token.approve(address(free), type(uint256).max);
        VestingVault open = free.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days);
        VestingVault bound =
            free.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 28 days);
        TreasuryVault t = free.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        vm.expectRevert(VaultFactory.NoFeeOnThisChain.selector);
        free.payFor(4663, address(token));
        vm.stopPrank();
        assertEq(free.vaultCount(), 3);
        assertTrue(free.isVault(address(open)) && free.isVault(address(bound)) && free.isVault(address(t)));
        assertFalse(free.feePaid(4663, address(token)));
        assertFalse(free.feePaid(4663, address(open)));
        assertEq(imd.balanceOf(radar), 0);
        assertEq(token.balanceOf(address(bound)), 1000e18);
    }

    /// @dev The launch manifest refuses the zero address as a constructor word, so the Robinhood copy is deployed as
    ///      `VaultFactoryNoFee`, a zero-argument subclass that passes the brief's two zero values itself. It must be
    ///      the audited factory and nothing else: the same deployed code, byte for byte, as
    ///      `new VaultFactory(IERC20(address(0)), address(0))`, with the same immutables.
    function test_NoFeeFactoryIsTheAuditedFactoryWithZeroArguments() public {
        vm.chainId(4663);
        VaultFactory audited = new VaultFactory(IERC20(address(0)), address(0));
        VaultFactoryNoFee launched = new VaultFactoryNoFee();
        assertEq(address(launched).code, address(audited).code, "deployed code differs from VaultFactory(0, 0)");
        assertEq(address(launched).codehash, address(audited).codehash);
        assertEq(address(launched).code.length, address(audited).code.length);
        assertLe(address(launched).code.length, 24_576, "runtime exceeds EIP-170");
        assertEq(address(launched.imd()), address(0));
        assertEq(launched.feeRecipient(), address(0));
        assertEq(launched.FEE(), audited.FEE());
        assertEq(launched.BENEFICIARY_DELAY(), audited.BENEFICIARY_DELAY());
        assertEq(launched.MIN_DELAY(), audited.MIN_DELAY());
        // No owner, admin or factory role: the only addresses the contract stores are the two zero words.
        assertEq(address(launched.imd()), address(0));
        assertEq(launched.feeRecipient(), address(0));
    }

    /// @dev The no-fee factory does on chain 4663 what the brief asks of `VaultFactory(0, 0)`: every creation path
    ///      works for anyone, no IMD is asked for or moves, nothing is marked paid, and `payFor` is refused here.
    function test_NoFeeFactoryCreatesVaultsAndTakesNoFeeOnRobinhood() public {
        vm.chainId(4663);
        VaultFactoryNoFee free = new VaultFactoryNoFee();
        address[] memory dests = new address[](1);
        dests[0] = multisig;

        vm.startPrank(project);
        token.approve(address(free), type(uint256).max);
        VestingVault open = free.createLaunchVesting(team, uint64(block.timestamp + 1 days), 7 days, 56 days);
        VestingVault bound =
            free.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 28 days);
        TreasuryVault t = free.createTreasury(address(token), project, 1 days, 2500, dests);
        TreasuryVault openTreasury = free.createTreasury(address(0), project, 2 days, 1000, new address[](0));
        vm.expectRevert(VaultFactory.NoFeeOnThisChain.selector);
        free.payFor(4663, address(token));
        vm.expectRevert(VaultFactory.NoFeeOnThisChain.selector);
        free.payFor(1, address(token));
        vm.stopPrank();

        // A wallet with no IMD at all, and no approval, creates vaults too: nothing is charged on this chain.
        vm.prank(stranger);
        VestingVault strangerVault = free.createLaunchVesting(stranger, uint64(block.timestamp), 0, 28 days);

        assertEq(free.vaultCount(), 5);
        assertTrue(free.isVault(address(open)) && free.isVault(address(bound)) && free.isVault(address(t)));
        assertTrue(free.isVault(address(openTreasury)) && free.isVault(address(strangerVault)));
        assertEq(free.creatorOf(address(open)), project);
        assertEq(free.creatorOf(address(strangerVault)), stranger);
        assertEq(free.vaultsByToken(address(token)).length, 2);
        assertEq(free.vaultsByToken(address(0)).length, 3);
        assertFalse(free.feePaid(4663, address(token)));
        assertFalse(free.feePaid(4663, address(open)));
        assertFalse(free.feePaid(4663, address(openTreasury)));
        assertEq(imd.balanceOf(radar), 0);
        assertEq(imd.balanceOf(project), 1000e18);
        assertEq(token.balanceOf(address(bound)), 1000e18);
        assertEq(address(bound.token()), address(token));
        assertEq(bound.beneficiary(), team);
        assertEq(t.manager(), project);
        assertEq(t.rateBps(), 2500);
        assertEq(t.delay(), 1 days);
        assertTrue(t.isDestination(multisig));
        // The Ethereum factory in the same tree still charges: the two copies differ only by their arguments.
        vm.prank(project);
        factory.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days);
        assertEq(imd.balanceOf(radar), 5e18);
    }

    // =================== 8894516c: the weekly cap overflowed for huge balances and locked the asset ===================

    function test_TreasuryCapHasNoOverflowForHugeBalances() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        MaxSupplyToken huge = new MaxSupplyToken();
        huge.transfer(address(t), 1 << 255);
        vm.prank(project);
        uint256 id = t.queue(address(huge), multisig, 1e18);
        vm.warp(block.timestamp + 1 days);

        uint256 cap = t.availableThisWeek(address(huge));
        assertEq(cap, (1 << 255) / 4);
        t.execute(id);
        assertEq(huge.balanceOf(multisig), 1e18);
        assertEq(t.availableThisWeek(address(huge)), cap - 1e18);

        // The whole cap can leave, and not a wei more, even at the largest possible balance.
        huge.transfer(address(t), type(uint256).max - (1 << 255));
        vm.warp((block.timestamp / t.EPOCH() + 1) * t.EPOCH());
        uint256 held = huge.balanceOf(address(t));
        vm.startPrank(project);
        uint256 all = t.queue(address(huge), multisig, held / 4);
        uint256 more = t.queue(address(huge), multisig, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertEq(t.availableThisWeek(address(huge)), held / 4);
        t.execute(all);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(more);
    }

    // =================== 53c7bd14: the vesting math overflowed for huge allocations ===================

    function test_VestingHugeAllocationVestsLinearly() public {
        MaxSupplyToken huge = new MaxSupplyToken();
        huge.approve(address(factory), type(uint256).max);
        imd.mint(address(this), 5e18);
        imd.approve(address(factory), 5e18);
        VestingVault v =
            factory.createVesting(IERC20(address(huge)), team, type(uint256).max, uint64(block.timestamp), 0, 28 days);
        assertEq(v.releasable(address(huge)), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(v.releasable(address(huge)), type(uint256).max / 28);
        v.release(address(huge));
        assertEq(huge.balanceOf(team), type(uint256).max / 28);
        vm.warp(block.timestamp + 6 days);
        assertEq(v.vestedAmount(address(huge), uint64(block.timestamp)), type(uint256).max / 4);
        v.release(address(huge));
        assertEq(huge.balanceOf(team), type(uint256).max / 4);
        vm.warp(block.timestamp + 21 days);
        v.release(address(huge));
        assertEq(huge.balanceOf(team), type(uint256).max);
    }

    // =================== 959cdd52: a tracked asset that turned hostile froze every ERC-20 withdrawal ===================

    function _hostileSetup(AuditToken hostile)
        internal
        returns (TreasuryVault t, uint256 viaToken, uint256 viaImd, uint256 viaHostile)
    {
        vm.prank(project);
        t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        hostile.mint(address(t), 100e18);
        token.mint(address(t), 1000e18);
        imd.mint(address(t), 100e18);
        vm.startPrank(project);
        viaHostile = t.queue(address(hostile), multisig, 1e18); // the asset is tracked while it is still benign
        viaToken = t.queue(address(token), multisig, 250e18);
        viaImd = t.queue(address(imd), multisig, 25e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
    }

    function test_GasBurningTrackedAssetCanNotBlockOtherWithdrawals() public {
        GasBurningToken burner = new GasBurningToken();
        (TreasuryVault t, uint256 a, uint256 b, uint256 h) = _hostileSetup(burner);
        burner.setHostile(true);
        // Before the fix each read forwarded all gas and left the caller 1/64: this call ran out of gas.
        t.execute{gas: 10_000_000}(a);
        t.execute{gas: 2_000_000}(b);
        assertEq(token.balanceOf(multisig), 250e18);
        assertEq(imd.balanceOf(multisig), 25e18);
        // The unreadable asset is charged nothing, and its own withdrawal fails only because it reverts itself.
        (uint64 epoch,,) = t.windows(address(burner));
        assertEq(epoch, 0);
        vm.expectRevert();
        t.execute(h);
        // Once it is benign again it is read and charged as before.
        burner.setHostile(false);
        t.execute(h);
        assertEq(burner.balanceOf(multisig), 1e18);
    }

    function test_PayloadBombTrackedAssetCanNotBlockOtherWithdrawals() public {
        PayloadBombToken bomb = new PayloadBombToken();
        (TreasuryVault t, uint256 a, uint256 b,) = _hostileSetup(bomb);
        bomb.setHostile(true);
        uint256 before = gasleft();
        t.execute{gas: 2_000_000}(a);
        // Two reads of the bomb cost at most two stipends on top of an ordinary execution.
        assertLt(before - gasleft(), 500_000 + 2 * t.BALANCE_READ_GAS());
        t.execute{gas: 2_000_000}(b);
        assertEq(token.balanceOf(multisig), 250e18);
        assertEq(imd.balanceOf(multisig), 25e18);
    }

    function test_SlowButHonestSecondEntryPointIsStillCharged() public {
        DoubleEntryToken dbl = new DoubleEntryToken();
        SlowLegacyEntry legacy = new SlowLegacyEntry(dbl);
        dbl.setLegacy(address(legacy));
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(dbl), project, 1 days, 2500, new address[](0));
        dbl.mint(address(t), 1000e18);
        vm.startPrank(project);
        uint256 a = t.queue(address(dbl), multisig, 250e18);
        uint256 b = t.queue(address(legacy), multisig, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        // The expensive read fits in the stipend, so the shared cap still holds through both addresses.
        vm.expectEmit(true, true, false, true, address(t));
        emit TreasuryVault.SharedBalanceCharged(a, address(legacy), 250e18);
        t.execute(a);
        assertEq(t.availableThisWeek(address(legacy)), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(b);
    }

    // =================== 444bc00c: an early small execute pins the epoch cap ahead of a deposit (documented) ===================

    /// @dev The README's rule: the cap is fixed by the first execute of the epoch and deposits later in the epoch do
    ///      not raise it. Anyone can choose that moment, so a large withdrawal queued before a deposit can be held to
    ///      the next epoch, which starts on the full balance; the grace period covers it, so nothing is lost.
    function test_EarlyExecuteBeforeADepositOnlyDelaysToTheNextEpoch() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        token.mint(address(t), 100e18);
        vm.startPrank(project);
        uint256 small = t.queue(address(token), multisig, 1e18);
        uint256 large = t.queue(address(token), multisig, 25_000e18);
        vm.stopPrank();
        uint256 epochStart = ((block.timestamp + 1 days) / t.EPOCH() + 1) * t.EPOCH();
        vm.warp(epochStart);
        vm.prank(stranger);
        t.execute(small); // pins this epoch's cap to 25% of 100e18
        token.mint(address(t), 100_000e18);
        assertEq(t.availableThisWeek(address(token)), 24e18);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 24e18));
        t.execute(large);
        // Next epoch opens on the full balance and the withdrawal is still inside its grace period.
        vm.warp(epochStart + t.EPOCH());
        (,,,, uint64 expiresAt,) = t.withdrawals(large);
        assertLe(block.timestamp, expiresAt);
        t.execute(large);
        assertEq(token.balanceOf(multisig), 25_001e18);
    }
}
