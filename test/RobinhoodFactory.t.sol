// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VaultFactoryNoFee} from "../src/VaultFactoryNoFee.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

// The Robinhood Chain (4663) copy of the audited factory: `VaultFactory(imd_ = 0, feeRecipient_ = 0)`, deployed through
// the launch as `VaultFactoryNoFee`. These tests drive that configuration only: its failure paths, the absence of any
// fee or token call, and invariants over random sequences of creations, fundings and releases.

contract RhToken is ERC20 {
    constructor(string memory s) ERC20(s, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Keeps 1% of every transfer that is not a mint or burn.
contract RhFeeToken is RhToken {
    constructor() RhToken("FEE") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev `transferFrom` returns false without moving anything.
contract RhFalseToken is RhToken {
    constructor() RhToken("NO") {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Re-enters the factory from inside `transferFrom`, creating a second vault mid-creation.
contract RhReentrantToken is RhToken {
    VaultFactory public f;
    bool public armed;
    address public inner;

    constructor() RhToken("RE") {}

    function arm(VaultFactory f_) external {
        f = f_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            inner = address(f.createLaunchVesting(from, uint64(block.timestamp), 0, 28 days));
        }
        _transfer(from, to, value);
        return true;
    }
}

/// @dev Deploys the factory and uses it in one call, the way the launch transaction runs.
contract RhOneTransaction {
    VaultFactoryNoFee public factory;
    VestingVault public open;
    TreasuryVault public treasury;

    constructor(address beneficiary) {
        factory = new VaultFactoryNoFee();
        open = factory.createLaunchVesting(beneficiary, uint64(block.timestamp), 0, 28 days);
        treasury = factory.createTreasury(address(0), beneficiary, 1 days, 2500, new address[](0));
    }
}

contract RobinhoodFactoryTest is Test {
    uint256 constant ROBINHOOD = 4663;

    VaultFactoryNoFee f;
    RhToken token;
    address project = makeAddr("project");
    address team = makeAddr("team");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.chainId(ROBINHOOD);
        vm.warp(1_760_000_000);
        f = new VaultFactoryNoFee();
        token = new RhToken("TKN");
        token.mint(project, 1_000_000e18);
        vm.prank(project);
        token.approve(address(f), type(uint256).max);
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _assertNothingRegistered() internal view {
        assertEq(f.vaultCount(), 0, "a failed creation left a vault in the registry");
        assertEq(f.vaultsByToken(address(token)).length, 0);
        assertEq(f.vaultsByToken(address(0)).length, 0);
    }

    // ---------------------------------------------------------------- deployment

    function test_ConstructorArgumentsOfTheBriefAreAcceptedAndStored() public {
        VaultFactory direct = new VaultFactory(IERC20(address(0)), address(0));
        assertEq(address(direct.imd()), address(0));
        assertEq(direct.feeRecipient(), address(0));
        assertEq(address(f).code, address(direct).code, "launched copy is not VaultFactory(0, 0)");
        assertEq(f.vaultCount(), 0);
    }

    /// @dev The constructor guard only bites when a fee token is set; the brief's pair (0, 0) never hits it.
    function test_ConstructorRejectsImdWithoutRecipientOnly() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(IERC20(address(token)), address(0));
        // A recipient without IMD is harmless: still no fee anywhere.
        VaultFactory odd = new VaultFactory(IERC20(address(0)), stranger);
        vm.expectRevert(VaultFactory.NoFeeOnThisChain.selector);
        odd.payFor(ROBINHOOD, address(token));
    }

    /// @dev The launch checks run constructors on an empty chain: the factory's must touch no other account.
    function test_ConstructorTouchesNoOtherAccount() public {
        vm.startStateDiffRecording();
        VaultFactoryNoFee fresh = new VaultFactoryNoFee();
        Vm.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            assertEq(diff[i].account, address(fresh), "constructor accessed another account");
        }
    }

    function test_DeployAndCreateInOneTransaction() public {
        RhOneTransaction tx_ = new RhOneTransaction(team);
        VaultFactoryNoFee fresh = tx_.factory();
        assertEq(fresh.vaultCount(), 2);
        assertEq(fresh.creatorOf(address(tx_.open())), address(tx_));
        assertEq(fresh.creatorOf(address(tx_.treasury())), address(tx_));
        assertFalse(fresh.feePaid(ROBINHOOD, address(tx_.open())));
        assertFalse(fresh.feePaid(ROBINHOOD, address(tx_.treasury())));
    }

    function test_FactoryRefusesEth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(f).call{value: 1 ether}("");
        assertFalse(ok, "factory accepted ETH");
        assertEq(address(f).balance, 0);
    }

    // ---------------------------------------------------------------- no fee, no token call

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PayForAlwaysRefusedHere(address caller, uint256 chainId, address key) public {
        vm.prank(caller);
        vm.expectRevert(VaultFactory.NoFeeOnThisChain.selector);
        f.payFor(chainId, key);
        assertFalse(f.feePaid(chainId, key));
    }

    /// @dev On this chain `createLaunchVesting` and `createTreasury` touch only the factory and the new vault: no
    ///      fee token is read or charged, so a wallet with no tokens and no approvals creates them.
    function test_OpenVaultCreationTouchesNoTokenAccount() public {
        vm.prank(stranger);
        vm.startStateDiffRecording();
        VestingVault v = f.createLaunchVesting(stranger, _now(), 0, 28 days);
        Vm.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            address a = diff[i].account;
            assertTrue(a == address(f) || a == address(v), "launch vesting touched another account");
        }

        vm.prank(stranger);
        vm.startStateDiffRecording();
        TreasuryVault t = f.createTreasury(address(token), stranger, 1 days, 2500, new address[](0));
        diff = vm.stopAndReturnStateDiff();
        for (uint256 i; i < diff.length; ++i) {
            address a = diff[i].account;
            assertTrue(a == address(f) || a == address(t), "treasury creation touched another account");
        }
        assertFalse(f.feePaid(ROBINHOOD, address(token)));
        assertFalse(f.feePaid(ROBINHOOD, address(v)));
        assertEq(f.creatorOf(address(v)), stranger);
        assertEq(f.creatorOf(address(t)), stranger);
    }

    /// @dev Creating many vaults for one token never marks it paid here: the radar must read `feePaid(4663, token)`
    ///      on the Ethereum factory, not on this one.
    function test_RepeatedCreationsNeverMarkAnythingPaid() public {
        vm.startPrank(project);
        for (uint256 i; i < 3; ++i) {
            VestingVault v = f.createVesting(IERC20(address(token)), team, 1e18, _now(), 0, 28 days);
            assertFalse(f.feePaid(ROBINHOOD, address(v)));
        }
        f.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        vm.stopPrank();
        assertFalse(f.feePaid(ROBINHOOD, address(token)));
        assertFalse(f.feePaid(1, address(token)));
        assertEq(f.vaultsByToken(address(token)).length, 4);
        assertEq(token.balanceOf(address(f)), 0);
    }

    // ---------------------------------------------------------------- createVesting failure paths

    function test_CreateVestingRejectsZeroToken() public {
        vm.prank(project);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        f.createVesting(IERC20(address(0)), team, 1e18, _now(), 0, 28 days);
        _assertNothingRegistered();
    }

    function test_CreateVestingRejectsZeroAmount() public {
        vm.prank(project);
        vm.expectRevert(VaultFactory.ZeroAmount.selector);
        f.createVesting(IERC20(address(token)), team, 0, _now(), 0, 28 days);
        _assertNothingRegistered();
    }

    function test_CreateVestingRejectsZeroBeneficiary() public {
        vm.prank(project);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        f.createVesting(IERC20(address(token)), address(0), 1e18, _now(), 0, 28 days);
        _assertNothingRegistered();
    }

    function test_CreateVestingRejectsDurationOneSecondShortOfFourWeeks() public {
        vm.prank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        f.createVesting(IERC20(address(token)), team, 1e18, _now(), 0, 28 days - 1);
        _assertNothingRegistered();
        vm.prank(project);
        f.createVesting(IERC20(address(token)), team, 1e18, _now(), 0, 28 days);
        assertEq(f.vaultCount(), 1);
    }

    function test_CreateVestingRejectsStartOneSecondInThePast() public {
        vm.prank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        f.createVesting(IERC20(address(token)), team, 1e18, _now() - 1, 0, 28 days);
        _assertNothingRegistered();
    }

    function test_CreateVestingRejectsScheduleOverflowingUint64() public {
        uint64 cliff = type(uint64).max - _now() - 28 days + 1;
        vm.prank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        f.createVesting(IERC20(address(token)), team, 1e18, _now(), cliff, 28 days);
        _assertNothingRegistered();
        // One second less fits exactly.
        vm.prank(project);
        f.createVesting(IERC20(address(token)), team, 1e18, _now(), cliff - 1, 28 days);
        assertEq(f.vaultCount(), 1);
    }

    function test_CreateVestingWithoutApprovalReverts() public {
        token.mint(stranger, 10e18);
        vm.prank(stranger);
        vm.expectRevert();
        f.createVesting(IERC20(address(token)), team, 1e18, _now(), 0, 28 days);
        _assertNothingRegistered();
    }

    function test_CreateVestingBeyondBalanceReverts() public {
        uint256 held = token.balanceOf(project);
        vm.prank(project);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, project, held, held + 1));
        f.createVesting(IERC20(address(token)), team, held + 1, _now(), 0, 28 days);
        _assertNothingRegistered();
        assertEq(token.balanceOf(project), held);
    }

    function test_CreateVestingWithTokenReturningFalseReverts() public {
        RhFalseToken bad = new RhFalseToken();
        bad.mint(project, 1e18);
        vm.prank(project);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        f.createVesting(IERC20(address(bad)), team, 1e18, _now(), 0, 28 days);
        assertEq(f.vaultCount(), 0);
    }

    function test_CreateVestingWithCodelessTokenReverts() public {
        vm.prank(project);
        vm.expectRevert();
        f.createVesting(IERC20(stranger), team, 1e18, _now(), 0, 28 days);
        assertEq(f.vaultCount(), 0);
    }

    function test_CreateVestingLogsWhatAFeeTokenDelivered() public {
        RhFeeToken fee = new RhFeeToken();
        fee.mint(project, 100e18);
        vm.startPrank(project);
        fee.approve(address(f), type(uint256).max);
        vm.recordLogs();
        VestingVault v = f.createVesting(IERC20(address(fee)), team, 100e18, _now(), 0, 28 days);
        vm.stopPrank();
        assertEq(fee.balanceOf(address(v)), 99e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("VestingCreated(address,address,address,address,uint256,uint64,uint64,uint64)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(f) || logs[i].topics[0] != sig) continue;
            (address creator, uint256 amount,,,) = abi.decode(logs[i].data, (address, uint256, uint64, uint64, uint64));
            assertEq(creator, project);
            assertEq(amount, 99e18, "event must carry what the vault received");
            seen = true;
        }
        assertTrue(seen);
        vm.warp(block.timestamp + 28 days);
        v.release(address(fee));
        // The release itself pays the token's 1% on the way out; the vault ends empty.
        assertEq(fee.balanceOf(address(v)), 0);
        assertEq(v.released(address(fee)), 99e18);
    }

    /// @dev A token that re-enters the factory mid-creation gets a second, separate vault; both are registered and
    ///      the outer vault still holds exactly what was transferred.
    function test_ReentrantTokenCannotCorruptTheRegistry() public {
        RhReentrantToken re = new RhReentrantToken();
        re.mint(project, 10e18);
        vm.prank(project);
        re.approve(address(f), type(uint256).max);
        re.arm(f);
        vm.prank(project);
        VestingVault outer = f.createVesting(IERC20(address(re)), team, 10e18, _now(), 0, 28 days);
        address inner = re.inner();
        assertEq(f.vaultCount(), 2);
        assertTrue(f.isVault(address(outer)) && f.isVault(inner));
        assertEq(f.allVaults(0), inner, "inner call registers first");
        assertEq(f.allVaults(1), address(outer));
        assertEq(f.creatorOf(inner), address(re), "the token itself created the inner vault");
        assertEq(f.creatorOf(address(outer)), project);
        assertEq(re.balanceOf(address(outer)), 10e18);
        assertEq(f.vaultsByToken(address(re)).length, 1);
    }

    // ---------------------------------------------------------------- createLaunchVesting failure paths

    function test_CreateLaunchVestingFailurePaths() public {
        vm.startPrank(stranger);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        f.createLaunchVesting(address(0), _now(), 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        f.createLaunchVesting(team, _now(), 0, 28 days - 1);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        f.createLaunchVesting(team, _now() - 1, 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        f.createLaunchVesting(team, type(uint64).max - 28 days + 1, 0, 28 days);
        vm.stopPrank();
        _assertNothingRegistered();
    }

    function test_LaunchVestingVestsTheRemainderFromItsArrival() public {
        vm.prank(project);
        VestingVault v = f.createLaunchVesting(team, _now(), 0, 28 days);
        // The launch pays the remainder two weeks late; it still vests over a full 28 days from its arrival.
        vm.warp(block.timestamp + 14 days);
        token.mint(address(v), 280e18);
        v.release(address(token)); // only records arrival
        assertEq(token.balanceOf(team), 0);
        vm.warp(block.timestamp + 7 days);
        v.release(address(token));
        assertEq(token.balanceOf(team), 70e18, "25% after one week, not half");
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));
        vm.warp(block.timestamp + 21 days);
        v.release(address(token));
        assertEq(token.balanceOf(team), 280e18);
        assertEq(token.balanceOf(address(v)), 0);
    }

    // ---------------------------------------------------------------- createTreasury failure paths

    function test_CreateTreasuryFailurePaths() public {
        address[] memory none = new address[](0);
        address[] memory zeroDest = new address[](1);
        vm.startPrank(stranger);
        vm.expectRevert(VaultFactory.BadDelay.selector);
        f.createTreasury(address(token), stranger, 1 days - 1, 2500, none);
        vm.expectRevert(VaultFactory.BadDelay.selector);
        f.createTreasury(address(token), stranger, 0, 2500, none);
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        f.createTreasury(address(token), stranger, 30 days + 1, 2500, none);
        vm.expectRevert(TreasuryVault.BadRate.selector);
        f.createTreasury(address(token), stranger, 1 days, 0, none);
        vm.expectRevert(TreasuryVault.BadRate.selector);
        f.createTreasury(address(token), stranger, 1 days, 2501, none);
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        f.createTreasury(address(token), address(0), 1 days, 2500, none);
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        f.createTreasury(address(token), stranger, 1 days, 2500, zeroDest);
        vm.stopPrank();
        _assertNothingRegistered();
    }

    function test_CreateTreasuryAtTheBounds() public {
        vm.startPrank(stranger);
        TreasuryVault lo = f.createTreasury(address(0), stranger, 1 days, 1, new address[](0));
        TreasuryVault hi = f.createTreasury(address(0), stranger, 30 days, 2500, new address[](0));
        vm.stopPrank();
        assertEq(lo.delay(), 1 days);
        assertEq(lo.rateBps(), 1);
        assertEq(hi.delay(), 30 days);
        assertEq(hi.rateBps(), 2500);
        assertEq(f.vaultsByToken(address(0)).length, 2);
        assertFalse(f.feePaid(ROBINHOOD, address(lo)));
    }

    /// @dev Treasury creation never reads `projectToken`, so it works for a token that has no code yet on this chain.
    function test_CreateTreasuryForATokenWithoutCode() public {
        address future = makeAddr("future token");
        vm.prank(project);
        TreasuryVault t = f.createTreasury(future, project, 1 days, 2500, new address[](0));
        assertEq(t.projectToken(), future);
        assertEq(f.vaultsByToken(future)[0], address(t));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_CreateTreasuryAcceptsExactlyTheBounds(uint64 delay, uint16 rate) public {
        bool ok = delay >= 1 days && delay <= 30 days && rate >= 1 && rate <= 2500;
        vm.prank(stranger);
        try f.createTreasury(address(0), stranger, delay, rate, new address[](0)) returns (TreasuryVault t) {
            assertTrue(ok, "out-of-bounds treasury accepted");
            assertEq(t.delay(), delay);
            assertEq(t.rateBps(), rate);
            assertEq(f.vaultCount(), 1);
        } catch {
            assertFalse(ok, "in-bounds treasury refused");
            assertEq(f.vaultCount(), 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_CreateVestingAcceptsExactlyValidSchedules(
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration
    ) public {
        amount = bound(amount, 0, 2e24);
        start = uint64(bound(start, _now() - 10 days, _now() + 3650 days));
        cliff = uint64(bound(cliff, 0, type(uint64).max));
        duration = uint64(bound(duration, 0, 3650 days));
        bool ok = amount > 0 && start >= _now() && duration >= 28 days
            && uint256(start) + cliff + duration <= type(uint64).max && amount <= token.balanceOf(project);
        vm.prank(project);
        try f.createVesting(IERC20(address(token)), team, amount, start, cliff, duration) returns (VestingVault v) {
            assertTrue(ok, "invalid vesting accepted");
            assertEq(token.balanceOf(address(v)), amount);
            assertEq(v.vestedAmount(address(token), _now()), 0, "something unlocked in the block that locks it");
            assertEq(f.vaultCount(), 1);
        } catch {
            assertFalse(ok, "valid vesting refused");
            assertEq(f.vaultCount(), 0);
        }
    }
}

// ============================================================================================================
//                                  invariants over the Robinhood (no-fee) factory
// ============================================================================================================

contract RobinhoodHandler is Test {
    VaultFactory public f;
    RhToken[2] public tokens;
    address[3] public actors;
    address[3] public beneficiaries;

    address[] public vaults;
    mapping(address => address) public creatorOfGhost;
    mapping(address => bool) public isVestingGhost;
    mapping(address => uint256) public keyCount; // vaultsByToken length per key
    address[] public vestings;
    address[] public treasuries;

    mapping(address => uint256) public intoVestings; // token => amount ever delivered to vesting vaults
    mapping(address => uint256) public intoTreasuries; // token => amount ever deposited to treasuries
    mapping(address => uint256) public releasedGhost; // token => amount the beneficiaries received

    bool public violated;
    string public reason;
    uint256 public releases;

    constructor(VaultFactory f_, RhToken[2] memory tokens_, address[3] memory actors_, address[3] memory bens_) {
        f = f_;
        tokens = tokens_;
        actors = actors_;
        beneficiaries = bens_;
    }

    function _bad(string memory r) internal {
        if (!violated) reason = r;
        violated = true;
    }

    function _record(address v, address creator, address key, bool vesting) internal {
        vaults.push(v);
        creatorOfGhost[v] = creator;
        keyCount[key]++;
        if (vesting) {
            isVestingGhost[v] = true;
            vestings.push(v);
        } else {
            treasuries.push(v);
        }
    }

    function vaultCountGhost() external view returns (uint256) {
        return vaults.length;
    }

    function vestingCount() external view returns (uint256) {
        return vestings.length;
    }

    function treasuryCount() external view returns (uint256) {
        return treasuries.length;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 21 days));
    }

    function createVesting(
        uint256 ai,
        uint256 bi,
        uint256 ti,
        uint256 amount,
        uint256 startOff,
        uint256 cliff,
        uint256 dur
    ) external {
        address a = actors[ai % 3];
        RhToken t = tokens[ti % 2];
        amount = bound(amount, 1, 1e27);
        uint64 start = uint64(block.timestamp + bound(startOff, 0, 60 days));
        t.mint(a, amount);
        vm.startPrank(a);
        t.approve(address(f), amount);
        VestingVault v = f.createVesting(
            IERC20(address(t)),
            beneficiaries[bi % 3],
            amount,
            start,
            uint64(bound(cliff, 0, 60 days)),
            uint64(bound(dur, 28 days, 400 days))
        );
        vm.stopPrank();
        if (t.balanceOf(address(v)) != amount) _bad("vault not funded with the amount");
        if (t.allowance(a, address(f)) != 0) _bad("allowance left over");
        intoVestings[address(t)] += amount;
        _record(address(v), a, address(t), true);
    }

    function createLaunchVesting(uint256 ai, uint256 bi, uint256 startOff, uint256 cliff, uint256 dur) external {
        address a = actors[ai % 3];
        vm.prank(a);
        VestingVault v = f.createLaunchVesting(
            beneficiaries[bi % 3],
            uint64(block.timestamp + bound(startOff, 0, 60 days)),
            uint64(bound(cliff, 0, 60 days)),
            uint64(bound(dur, 28 days, 400 days))
        );
        _record(address(v), a, address(0), true);
    }

    function createTreasury(uint256 ai, uint256 ti, bool open, uint256 delay, uint256 rate) external {
        address a = actors[ai % 3];
        address pt = open ? address(0) : address(tokens[ti % 2]);
        vm.prank(a);
        TreasuryVault v = f.createTreasury(
            pt, a, uint64(bound(delay, 1 days, 30 days)), uint16(bound(rate, 1, 2500)), new address[](0)
        );
        _record(address(v), a, pt, false);
    }

    /// @dev A launch paying its remainder (or anyone topping up) straight into a vesting vault.
    function fundVesting(uint256 vi, uint256 ti, uint256 amount) external {
        if (vestings.length == 0) return;
        VestingVault v = VestingVault(vestings[vi % vestings.length]);
        RhToken t = tokens[ti % 2];
        if (!v.vests(address(t))) t = RhToken(address(v.token()));
        amount = bound(amount, 1, 1e27);
        t.mint(address(v), amount);
        intoVestings[address(t)] += amount;
    }

    function depositTreasury(uint256 vi, uint256 ti, uint256 amount) external {
        if (treasuries.length == 0) return;
        TreasuryVault v = TreasuryVault(payable(treasuries[vi % treasuries.length]));
        RhToken t = tokens[ti % 2];
        amount = bound(amount, 1, 1e27);
        address a = actors[0];
        t.mint(a, amount);
        vm.startPrank(a);
        t.approve(address(v), amount);
        v.deposit(IERC20(address(t)), amount);
        vm.stopPrank();
        intoTreasuries[address(t)] += amount;
    }

    function release(uint256 vi, uint256 ti, uint256 ci) external {
        if (vestings.length == 0) return;
        VestingVault v = VestingVault(vestings[vi % vestings.length]);
        address t = address(tokens[ti % 2]);
        if (!v.vests(t)) {
            vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, t));
            v.release(t);
            return;
        }
        address ben = v.beneficiary();
        uint256 before = IERC20(t).balanceOf(ben);
        uint256 due = v.releasable(t);
        vm.prank(actors[ci % 3]); // anyone may call; the tokens only go to the beneficiary
        try v.release(t) {
            uint256 got = IERC20(t).balanceOf(ben) - before;
            if (got != due) _bad("release paid other than releasable");
            releasedGhost[t] += got;
            if (got > 0) releases++;
        } catch (bytes memory err) {
            if (bytes4(err) != VestingVault.NothingToRelease.selector) _bad("release reverted unexpectedly");
            if (due != 0) _bad("release refused a due amount");
        }
    }

    /// @dev Every invalid creation must revert and leave the registry exactly as it was.
    function badCreate(uint256 which, uint256 ai) external {
        address a = actors[ai % 3];
        uint256 n = f.vaultCount();
        RhToken t = tokens[0];
        t.mint(a, 1e18);
        vm.startPrank(a);
        t.approve(address(f), 1e18);
        bool ok;
        uint256 w = which % 7;
        if (w == 0) {
            try f.createVesting(IERC20(address(0)), a, 1e18, uint64(block.timestamp), 0, 28 days) {
                ok = true;
            } catch {}
        } else if (w == 1) {
            try f.createVesting(IERC20(address(t)), a, 0, uint64(block.timestamp), 0, 28 days) {
                ok = true;
            } catch {}
        } else if (w == 2) {
            try f.createVesting(IERC20(address(t)), a, 1e18, uint64(block.timestamp - 1), 0, 28 days) {
                ok = true;
            } catch {}
        } else if (w == 3) {
            try f.createLaunchVesting(a, uint64(block.timestamp), 0, 28 days - 1) {
                ok = true;
            } catch {}
        } else if (w == 4) {
            try f.createLaunchVesting(address(0), uint64(block.timestamp), 0, 28 days) {
                ok = true;
            } catch {}
        } else if (w == 5) {
            try f.createTreasury(address(0), a, 1 days - 1, 2500, new address[](0)) {
                ok = true;
            } catch {}
        } else {
            try f.createTreasury(address(t), a, 1 days, 2501, new address[](0)) {
                ok = true;
            } catch {}
        }
        vm.stopPrank();
        if (ok) _bad("invalid creation accepted");
        if (f.vaultCount() != n) _bad("failed creation changed the registry");
        // Clean up the unused approval and tokens so they cannot be mistaken for anything later.
        vm.startPrank(a);
        t.approve(address(f), 0);
        t.transfer(address(0xdead), t.balanceOf(a));
        vm.stopPrank();
    }

    function payFor(uint256 ai, uint256 chainSel, uint256 ki) external {
        uint256 chainId = chainSel % 2 == 0 ? 4663 : 1;
        address key = vaults.length > 0 && ki % 2 == 0 ? vaults[ki % vaults.length] : address(tokens[ki % 2]);
        vm.prank(actors[ai % 3]);
        try f.payFor(chainId, key) {
            _bad("payFor accepted on the no-fee factory");
        } catch (bytes memory err) {
            if (bytes4(err) != VaultFactory.NoFeeOnThisChain.selector) _bad("payFor reverted for another reason");
        }
    }
}

contract RobinhoodInvariantTest is Test {
    RobinhoodHandler h;
    VaultFactoryNoFee f;
    RhToken[2] tokens;
    address[3] actors;
    address[3] bens;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_760_000_000);
        f = new VaultFactoryNoFee();
        tokens = [new RhToken("A"), new RhToken("B")];
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];
        bens = [makeAddr("b0"), makeAddr("b1"), makeAddr("b2")];
        h = new RobinhoodHandler(f, tokens, actors, bens);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = h.warp.selector;
        sel[1] = h.createVesting.selector;
        sel[2] = h.createLaunchVesting.selector;
        sel[3] = h.createTreasury.selector;
        sel[4] = h.fundVesting.selector;
        sel[5] = h.depositTreasury.selector;
        sel[6] = h.release.selector;
        sel[7] = h.badCreate.selector;
        sel[8] = h.payFor.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    /// @dev The handler is not vacuous: a fixed sequence reaches creation, funding and a paying release.
    function test_HandlerReachesRelease() public {
        h.createVesting(0, 0, 0, 1000e18, 0, 0, 28 days);
        h.createLaunchVesting(1, 1, 0, 0, 28 days);
        h.fundVesting(1, 1, 500e18);
        h.release(1, 1, 2); // records arrival
        h.createTreasury(2, 0, true, 1 days, 2500);
        h.depositTreasury(0, 0, 10e18);
        h.badCreate(3, 0);
        h.payFor(0, 0, 0);
        h.warp(14 days);
        h.release(0, 0, 1);
        h.release(1, 1, 0);
        assertFalse(h.violated(), h.reason());
        assertEq(h.releases(), 2);
        assertEq(tokens[0].balanceOf(bens[0]), 500e18);
        assertEq(tokens[1].balanceOf(bens[1]), 250e18);
        invariant_noFeeAndNoCustody();
        invariant_registry();
        invariant_conservation();
        invariant_neverAheadOfSchedule();
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_noFeeAndNoCustody() public view {
        assertFalse(h.violated(), h.reason());
        assertEq(address(f.imd()), address(0));
        assertEq(f.feeRecipient(), address(0));
        assertEq(address(f).balance, 0, "factory holds ETH");
        for (uint256 i; i < 2; ++i) {
            assertEq(tokens[i].balanceOf(address(f)), 0, "factory holds tokens");
            assertFalse(f.feePaid(4663, address(tokens[i])), "token marked paid on the no-fee factory");
            assertFalse(f.feePaid(1, address(tokens[i])));
        }
        uint256 n = h.vaultCountGhost();
        for (uint256 i; i < n; ++i) {
            address v = h.vaults(i);
            assertFalse(f.feePaid(4663, v), "vault marked paid on the no-fee factory");
            assertFalse(f.feePaid(1, v));
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_registry() public view {
        uint256 n = h.vaultCountGhost();
        assertEq(f.vaultCount(), n, "registry counts every vault, and only those");
        for (uint256 i; i < n; ++i) {
            address v = h.vaults(i);
            assertEq(f.allVaults(i), v, "registry order");
            assertTrue(f.isVault(v));
            assertEq(f.creatorOf(v), h.creatorOfGhost(v), "vault filed under its creator");
        }
        assertEq(f.vaultsByToken(address(0)).length, h.keyCount(address(0)));
        for (uint256 i; i < 2; ++i) {
            assertEq(f.vaultsByToken(address(tokens[i])).length, h.keyCount(address(tokens[i])));
        }
        assertFalse(f.isVault(address(h)));
        assertFalse(f.isVault(address(f)));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_conservation() public view {
        for (uint256 k; k < 2; ++k) {
            address t = address(tokens[k]);
            uint256 heldPlusReleased;
            uint256 releasedSum;
            for (uint256 i; i < h.vestingCount(); ++i) {
                VestingVault v = VestingVault(h.vestings(i));
                heldPlusReleased += IERC20(t).balanceOf(address(v)) + v.released(t);
                releasedSum += v.released(t);
            }
            assertEq(heldPlusReleased, h.intoVestings(t), "vesting vaults hold what came in minus what left");
            assertEq(releasedSum, h.releasedGhost(t), "released counters match what beneficiaries got");
            uint256 bensHold;
            for (uint256 b; b < 3; ++b) {
                bensHold += IERC20(t).balanceOf(bens[b]);
            }
            assertEq(bensHold, h.releasedGhost(t), "only releases pay beneficiaries");
            uint256 inTreasuries;
            for (uint256 i; i < h.treasuryCount(); ++i) {
                inTreasuries += IERC20(t).balanceOf(h.treasuries(i));
            }
            assertEq(inTreasuries, h.intoTreasuries(t), "treasuries keep every deposit");
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_neverAheadOfSchedule() public view {
        uint64 nowTs = uint64(block.timestamp);
        for (uint256 i; i < h.vestingCount(); ++i) {
            VestingVault v = VestingVault(h.vestings(i));
            for (uint256 k; k < 2; ++k) {
                address t = address(tokens[k]);
                if (!v.vests(t)) {
                    assertEq(v.released(t), 0);
                    continue;
                }
                uint256 vested = v.vestedAmount(t, nowTs);
                assertLe(v.released(t), vested, "released ahead of the schedule");
                assertLe(vested, v.totalAllocation(t), "vested more than the vault ever held");
                if (nowTs < v.start() + v.cliff()) assertEq(vested, 0, "something vested during the cliff");
                assertGe(v.duration(), 28 days, "schedule faster than 25% a week");
            }
        }
    }
}
