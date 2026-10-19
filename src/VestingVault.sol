// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault
/// @notice Holds tokens and releases them to a beneficiary on a schedule: nothing during the cliff, then linearly
///         over `duration`. No schedule can unlock more than 25% of the tokens in any week. Nobody owns this contract.
///         The schedule can only get longer, and a new beneficiary takes over only after a public delay. There is no
///         admin, no pause and no emergency withdrawal.
///
///         A vault is either bound to one `token`, or open (`token` is zero). An open vault is made before a token
///         exists: a project puts its address as the launch's `remainderTo`, so its share of the supply arrives here
///         in the launch transaction and never passes through the team's wallet. Every token an open vault holds vests
///         on the same schedule.
/// @dev The amount under vesting, per token, is this contract's balance plus what it already released, so tokens
///      that charge a transfer fee and later top-ups are both accounted for: everything that arrives vests on the same
///      schedule. `start` can not be in the past at creation, so a bound vault (funded in the transaction that creates
///      it) never has anything unlocked before it exists. An open vault is funded later, by a launch it does not
///      control, so each token's linear unlock begins no earlier than the moment the vault records that token's arrival
///      (`sync`, which `release` also does): a launch that slips past `start + cliff` still vests from its arrival,
///      never on it. The schedule is calendar-based per token, not per tranche: a later top-up of a token already
///      held is unlocked by the fraction of the schedule that has elapsed. An open vault accounts per token address,
///      so a token with two addresses to one balance would vest once per address; the radar refuses its seal to an
///      open vault holding such a token, since the vault can not know the other address.
contract VestingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The shortest linear unlock allowed: 4 weeks, so at most 25% of the tokens unlock in any 7 days.
    uint64 public constant MIN_DURATION = 28 days;

    /// @notice The vested token, or zero for an open vault that vests any token it receives.
    IERC20 public immutable token;
    uint64 public immutable start;
    uint64 public immutable cliff; // seconds after start before anything unlocks
    uint64 public immutable beneficiaryDelay;

    uint64 public duration; // length of the linear unlock after the cliff; can only grow
    address public beneficiary;
    mapping(address => uint256) public released;
    /// @notice Open vault only: when the vault first recorded holding `asset`. Its linear unlock starts no earlier.
    ///         Zero until `sync(asset)` or `release(asset)` is called while the vault holds some; always zero in a
    ///         bound vault, whose token arrives when it is created.
    mapping(address => uint64) public arrivedAt;

    address public pendingBeneficiary;
    uint64 public pendingBeneficiaryEta;

    event Released(address indexed token, address indexed beneficiary, uint256 amount);
    event Arrived(address indexed token, uint64 at);
    event DurationExtended(uint64 oldDuration, uint64 newDuration);
    event BeneficiaryProposed(address indexed current, address indexed proposed, uint64 eta);
    event BeneficiaryCancelled(address indexed proposed);
    event BeneficiaryChanged(address indexed oldBeneficiary, address indexed newBeneficiary);
    event Recovered(address indexed otherToken, address indexed to, uint256 amount);

    error NotBeneficiary();
    error NotPendingBeneficiary();
    error ZeroAddress();
    error BadSchedule();
    error NothingToRelease();
    error NoProposal();
    error TooEarly(uint64 eta);
    error NotLonger();
    error NotVested(address token);
    error VestingToken();

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    constructor(
        IERC20 token_,
        address beneficiary_,
        uint64 start_,
        uint64 cliff_,
        uint64 duration_,
        uint64 beneficiaryDelay_
    ) {
        if (beneficiary_ == address(0)) revert ZeroAddress();
        if (duration_ < MIN_DURATION) revert BadSchedule();
        // Never in the past: a schedule that has already run would unlock tokens in the block that locks them.
        if (start_ < block.timestamp) revert BadSchedule();
        // The whole schedule must fit in uint64, or the vault's arithmetic would revert forever and trap the tokens.
        if (uint256(start_) + cliff_ + duration_ > type(uint64).max) revert BadSchedule();
        token = token_;
        beneficiary = beneficiary_;
        start = start_;
        cliff = cliff_;
        duration = duration_;
        beneficiaryDelay = beneficiaryDelay_;
    }

    // ---------- the schedule ----------

    /// @notice True when `asset` vests here: the bound token, or any token in an open vault.
    function vests(address asset) public view returns (bool) {
        return asset != address(0) && (address(token) == address(0) || asset == address(token));
    }

    /// @notice Everything this vault has ever held of `asset` for vesting: what it holds now plus what it released.
    function totalAllocation(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + released[asset];
    }

    /// @notice When the linear unlock of `asset` begins: `start + cliff`, or for an open vault the later of that and
    ///         the recorded arrival of `asset`. Zero while an open vault has not recorded `asset` yet: nothing vests.
    function unlockStart(address asset) public view returns (uint64) {
        uint64 scheduled = start + cliff;
        if (address(token) != address(0)) return scheduled;
        uint64 arrived = arrivedAt[asset];
        if (arrived == 0) return 0;
        return arrived > scheduled ? arrived : scheduled;
    }

    /// @notice How much of `asset` has vested by `timestamp`, released or not.
    function vestedAmount(address asset, uint64 timestamp) public view returns (uint256) {
        uint64 from = unlockStart(asset);
        if (from == 0 || timestamp < from) return 0;
        uint256 total = totalAllocation(asset);
        uint64 elapsed = timestamp - from;
        if (elapsed >= duration) return total;
        return (total * elapsed) / duration;
    }

    /// @notice Records that an open vault now holds `asset`, which starts that token's clock: its linear unlock
    ///         begins at the later of `start + cliff` and this moment. Anyone can call it, and `release` does it too;
    ///         calling it again, or on a bound vault, changes nothing. Call it right after the launch pays the vault,
    ///         since the clock only runs from the recorded arrival.
    function sync(address asset) external {
        if (!vests(asset)) revert NotVested(asset);
        _sync(asset);
    }

    /// @notice What the beneficiary can take of `asset` right now.
    function releasable(address asset) public view returns (uint256) {
        if (!vests(asset)) return 0;
        uint256 vested = vestedAmount(asset, uint64(block.timestamp));
        uint256 done = released[asset];
        return vested > done ? vested - done : 0;
    }

    /// @notice Sends what has vested of `asset` to the beneficiary. Anyone can call it; the tokens only ever go to the
    ///         beneficiary. In an open vault the first call for a newly arrived token only records its arrival
    ///         (nothing can have vested yet) and returns without reverting, so the clock is started and kept.
    function release(address asset) external nonReentrant {
        if (!vests(asset)) revert NotVested(asset);
        bool justArrived = _sync(asset);
        uint256 amount = releasable(asset);
        if (amount == 0) {
            if (justArrived) return;
            revert NothingToRelease();
        }
        released[asset] += amount;
        address to = beneficiary;
        IERC20(asset).safeTransfer(to, amount);
        emit Released(asset, to, amount);
    }

    /// @notice Makes the vesting last longer. It can never be shortened.
    function extendDuration(uint64 newDuration) external onlyBeneficiary {
        if (newDuration <= duration) revert NotLonger();
        if (uint256(start) + cliff + newDuration > type(uint64).max) revert BadSchedule();
        emit DurationExtended(duration, newDuration);
        duration = newDuration;
    }

    // ---------- changing the beneficiary: proposed, public, then delayed ----------

    function proposeBeneficiary(address proposed) external onlyBeneficiary {
        if (proposed == address(0)) revert ZeroAddress();
        pendingBeneficiary = proposed;
        pendingBeneficiaryEta = uint64(block.timestamp) + beneficiaryDelay;
        emit BeneficiaryProposed(beneficiary, proposed, pendingBeneficiaryEta);
    }

    function cancelBeneficiary() external onlyBeneficiary {
        address proposed = pendingBeneficiary;
        if (proposed == address(0)) revert NoProposal();
        delete pendingBeneficiary;
        delete pendingBeneficiaryEta;
        emit BeneficiaryCancelled(proposed);
    }

    /// @notice The proposed beneficiary takes over once the delay has passed.
    function acceptBeneficiary() external {
        address proposed = pendingBeneficiary;
        if (proposed == address(0)) revert NoProposal();
        if (msg.sender != proposed) revert NotPendingBeneficiary();
        if (block.timestamp < pendingBeneficiaryEta) revert TooEarly(pendingBeneficiaryEta);
        emit BeneficiaryChanged(beneficiary, proposed);
        beneficiary = proposed;
        delete pendingBeneficiary;
        delete pendingBeneficiaryEta;
    }

    // ---------- tokens sent here by mistake ----------

    /// @notice In a bound vault, returns any other token sent here by mistake to the beneficiary. The vested token can
    ///         never leave through this path, and an open vault has no such path: everything it holds vests.
    /// @dev A token with two entry points to one balance (a legacy or proxy contract forwarding to the vested token)
    ///      passes the address check, so the vested balance is read before and after: if it fell, the call reverts.
    function recover(IERC20 otherToken) external nonReentrant {
        if (address(token) == address(0) || vests(address(otherToken))) revert VestingToken();
        uint256 held = token.balanceOf(address(this));
        uint256 amount = otherToken.balanceOf(address(this));
        address to = beneficiary;
        otherToken.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) < held) revert VestingToken();
        emit Recovered(address(otherToken), to, amount);
    }

    /// @dev Records the arrival of `asset` in an open vault, once, when the vault holds some. True when it did so now.
    function _sync(address asset) internal returns (bool) {
        if (address(token) != address(0) || arrivedAt[asset] != 0) return false;
        if (IERC20(asset).balanceOf(address(this)) == 0) return false;
        arrivedAt[asset] = uint64(block.timestamp);
        emit Arrived(asset, uint64(block.timestamp));
        return true;
    }
}
