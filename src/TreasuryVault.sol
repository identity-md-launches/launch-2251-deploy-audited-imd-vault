// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TreasuryVault
/// @notice A project treasury that nobody owns. Anyone can deposit tokens or ETH. A manager can only announce a
///         withdrawal; it executes after a public delay, only to an allowed destination, and no more than a fixed
///         share of the balance can leave per week. Every rule can only become stricter after creation. There is no
///         admin, no pause, no upgrade and no emergency withdrawal. The weekly share can never exceed 25%.
/// @dev `address(0)` stands for ETH everywhere. The weekly cap is measured per asset, per fixed 7-day epoch
///      (`block.timestamp / 7 days`), as `rateBps` of the balance seen by the first withdrawal executed in that epoch.
///      Two epochs can be straddled within any rolling 7 days, so the most that can leave in any 7-day span is
///      `rate + rate * (1 - rate)` of the balance at its start (43.75% at the 25% ceiling), and a rate decrease
///      applies from the next epoch when a withdrawal has already executed in the current one.
///
///      The cap is a rule on the balance, not on the address: a token reachable through two addresses that share one
///      balance (a legacy contract forwarding to the main token, a proxy and its target) must not get one window per
///      address. So every ERC-20 withdrawal reads the balances of every other asset the manager has ever queued,
///      before and after the transfer, and any balance that fell is charged against that asset's window as well,
///      as if it had been withdrawn through that address. Only the manager grows that set, by queueing, so only the
///      manager pays for the loop it adds. An asset nobody queued keeps a window of its own, since the vault can not
///      tell that two addresses share a balance until both are used.
contract TreasuryVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant ETH = address(0);
    uint256 public constant EPOCH = 7 days;
    uint256 public constant GRACE = 14 days;
    /// @notice Withdrawals wait at least 24h. Checked here as well as in the factory, so the rule is in the vault.
    uint256 public constant MIN_DELAY = 1 days;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant BPS = 10_000;
    /// @notice At most 25% of a treasury can leave per week.
    uint16 public constant MAX_RATE_BPS = 2_500;

    /// @notice The project this treasury belongs to (informational: the radar files the vault under this token).
    address public immutable projectToken;

    address public manager;
    uint64 public delay;
    uint16 public rateBps;
    /// @notice True when withdrawals may only go to the destinations listed below.
    bool public restricted;

    address public pendingManager;
    /// @notice When the pending manager was proposed. The takeover waits the current delay from then, like a queued
    ///         withdrawal, so raising the delay also holds back a change of manager already proposed.
    uint64 public pendingManagerProposedAt;

    struct Withdrawal {
        address asset;
        address to;
        uint256 amount;
        uint64 queuedAt;
        /// @dev Fixed when queued (`queuedAt + delay + GRACE`): raising the delay never revives an expired withdrawal.
        uint64 expiresAt;
        bool done; // executed or cancelled
    }

    Withdrawal[] public withdrawals;

    mapping(address => bool) public isDestination;
    address[] internal _destinations;

    /// @notice Every ERC-20 asset ever queued, each once. Their balances are watched on every ERC-20 withdrawal, so
    ///         two addresses that share one balance share one weekly cap.
    address[] internal _trackedAssets;
    mapping(address => bool) public isTracked;

    struct Window {
        uint64 epoch;
        uint256 cap;
        uint256 spent;
    }

    mapping(address => Window) public windows;

    event Deposited(address indexed asset, address indexed from, uint256 amount);
    event Queued(uint256 indexed id, address indexed asset, address indexed to, uint256 amount, uint64 eta);
    event Cancelled(uint256 indexed id);
    event Executed(uint256 indexed id, address indexed asset, address indexed to, uint256 amount);
    /// @notice A withdrawal of another asset lowered `asset`'s balance too (two addresses to one balance), so the
    ///         amount was charged against `asset`'s weekly window as well.
    event SharedBalanceCharged(uint256 indexed id, address indexed asset, uint256 amount);
    event DelayIncreased(uint64 oldDelay, uint64 newDelay);
    event RateDecreased(uint16 oldBps, uint16 newBps);
    event DestinationsRestricted(address[] destinations);
    event DestinationRemoved(address indexed destination);
    event ManagerProposed(address indexed current, address indexed proposed, uint64 eta);
    event ManagerCancelled(address indexed proposed);
    event ManagerChanged(address indexed oldManager, address indexed newManager);

    error NotManager();
    error NotPendingManager();
    error ZeroAddress();
    error ZeroAmount();
    error BadDelay();
    error BadRate();
    error NotAllowed(address to);
    error UnknownWithdrawal();
    error AlreadyDone();
    error TooEarly(uint64 eta);
    error Expired();
    error OverWeeklyCap(uint256 available);
    error NoProposal();
    error AlreadyRestricted();
    error NotRestricted();
    error NotListed();
    error EthTransferFailed();

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    constructor(
        address projectToken_,
        address manager_,
        uint64 delay_,
        uint16 rateBps_,
        address[] memory destinations_
    ) {
        if (manager_ == address(0)) revert ZeroAddress();
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert BadDelay();
        if (rateBps_ == 0 || rateBps_ > MAX_RATE_BPS) revert BadRate();
        projectToken = projectToken_;
        manager = manager_;
        delay = delay_;
        rateBps = rateBps_;
        if (destinations_.length > 0) _restrict(destinations_);
    }

    // ---------- deposits ----------

    receive() external payable {
        emit Deposited(ETH, msg.sender, msg.value);
    }

    /// @notice Deposits a token. Sending tokens straight to the vault works too; this only adds an event.
    function deposit(IERC20 asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(address(asset), msg.sender, asset.balanceOf(address(this)) - before);
    }

    // ---------- withdrawals: announced, delayed, capped ----------

    /// @notice Announces a withdrawal. It can execute once the delay has passed, by anyone, within the grace period.
    function queue(address asset, address to, uint256 amount) external onlyManager returns (uint256 id) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (restricted && !isDestination[to]) revert NotAllowed(to);
        if (asset != ETH && !isTracked[asset]) {
            isTracked[asset] = true;
            _trackedAssets.push(asset);
        }
        id = withdrawals.length;
        uint64 eta = uint64(block.timestamp) + delay;
        withdrawals.push(Withdrawal(asset, to, amount, uint64(block.timestamp), eta + uint64(GRACE), false));
        emit Queued(id, asset, to, amount, eta);
    }

    function cancel(uint256 id) external onlyManager {
        Withdrawal storage w = _get(id);
        if (w.done) revert AlreadyDone();
        w.done = true;
        emit Cancelled(id);
    }

    /// @notice Executes an announced withdrawal. Anyone can call it; the funds only go to the announced destination.
    /// @dev The current delay and destination list apply, so tightening either also holds back queued withdrawals.
    ///      The expiry was fixed when the withdrawal was queued, so a longer delay can only shorten or close its
    ///      execution window, never reopen one that has passed. An ERC-20 withdrawal that also lowers the balance of
    ///      another tracked asset (two addresses to one balance) is charged against that asset's window too.
    function execute(uint256 id) external nonReentrant {
        Withdrawal storage w = _get(id);
        if (w.done) revert AlreadyDone();
        uint64 due = w.queuedAt + delay;
        if (block.timestamp < due) revert TooEarly(due);
        if (block.timestamp > w.expiresAt) revert Expired();
        if (restricted && !isDestination[w.to]) revert NotAllowed(w.to);

        _charge(windows[w.asset], _balance(w.asset), w.amount);
        w.done = true;

        if (w.asset == ETH) {
            (bool ok,) = w.to.call{value: w.amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            uint256 n = _trackedAssets.length;
            uint256[] memory before = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                if (_trackedAssets[i] != w.asset) before[i] = _tryBalance(_trackedAssets[i]);
            }
            IERC20(w.asset).safeTransfer(w.to, w.amount);
            for (uint256 i; i < n; ++i) {
                address other = _trackedAssets[i];
                if (other == w.asset) continue;
                uint256 now_ = _tryBalance(other);
                if (now_ >= before[i]) continue;
                uint256 fell = before[i] - now_;
                _charge(windows[other], before[i], fell);
                emit SharedBalanceCharged(id, other, fell);
            }
        }
        emit Executed(id, w.asset, w.to, w.amount);
    }

    // ---------- rules: they can only get stricter ----------

    function increaseDelay(uint64 newDelay) external onlyManager {
        if (newDelay <= delay || newDelay > MAX_DELAY) revert BadDelay();
        emit DelayIncreased(delay, newDelay);
        delay = newDelay;
    }

    function decreaseRate(uint16 newBps) external onlyManager {
        if (newBps == 0 || newBps >= rateBps) revert BadRate();
        emit RateDecreased(rateBps, newBps);
        rateBps = newBps;
    }

    /// @notice Limits an open vault to a list of destinations. Only possible once, and the list can then only shrink.
    function restrictDestinations(address[] calldata list) external onlyManager {
        if (restricted) revert AlreadyRestricted();
        if (list.length == 0) revert NotListed();
        _restrict(list);
    }

    function removeDestination(address destination) external onlyManager {
        if (!restricted) revert NotRestricted();
        if (!isDestination[destination]) revert NotListed();
        // Keep at least one destination, or the treasury would be frozen for good.
        if (_destinations.length == 1) revert NotListed();
        isDestination[destination] = false;
        uint256 n = _destinations.length;
        for (uint256 i; i < n; ++i) {
            if (_destinations[i] == destination) {
                _destinations[i] = _destinations[n - 1];
                _destinations.pop();
                break;
            }
        }
        emit DestinationRemoved(destination);
    }

    // ---------- changing the manager: proposed, public, then delayed ----------

    function proposeManager(address proposed) external onlyManager {
        if (proposed == address(0)) revert ZeroAddress();
        pendingManager = proposed;
        pendingManagerProposedAt = uint64(block.timestamp);
        emit ManagerProposed(manager, proposed, pendingManagerEta());
    }

    function cancelManager() external onlyManager {
        address proposed = pendingManager;
        if (proposed == address(0)) revert NoProposal();
        delete pendingManager;
        delete pendingManagerProposedAt;
        emit ManagerCancelled(proposed);
    }

    /// @notice The proposed manager takes over once the current delay has passed since the proposal.
    function acceptManager() external {
        address proposed = pendingManager;
        if (proposed == address(0)) revert NoProposal();
        if (msg.sender != proposed) revert NotPendingManager();
        uint64 eta = pendingManagerEta();
        if (block.timestamp < eta) revert TooEarly(eta);
        emit ManagerChanged(manager, proposed);
        manager = proposed;
        delete pendingManager;
        delete pendingManagerProposedAt;
    }

    // ---------- views for the radar ----------

    /// @notice When the pending manager can take over: the proposal time plus the current delay (zero if none).
    function pendingManagerEta() public view returns (uint64) {
        uint64 proposedAt = pendingManagerProposedAt;
        return proposedAt == 0 ? 0 : proposedAt + delay;
    }

    function destinations() external view returns (address[] memory) {
        return _destinations;
    }

    /// @notice Every ERC-20 asset ever queued, whose balances every ERC-20 withdrawal watches.
    function trackedAssets() external view returns (address[] memory) {
        return _trackedAssets;
    }

    function withdrawalCount() external view returns (uint256) {
        return withdrawals.length;
    }

    /// @notice What can still leave this epoch for `asset`, if a withdrawal executed right now.
    function availableThisWeek(address asset) external view returns (uint256) {
        Window memory win = windows[asset];
        if (win.epoch != uint64(block.timestamp / EPOCH)) return (_balance(asset) * rateBps) / BPS;
        return win.cap - win.spent;
    }

    // ---------- internals ----------

    function _restrict(address[] memory list) internal {
        restricted = true;
        for (uint256 i; i < list.length; ++i) {
            address d = list[i];
            if (d == address(0)) revert ZeroAddress();
            if (isDestination[d]) continue;
            isDestination[d] = true;
            _destinations.push(d);
        }
        emit DestinationsRestricted(_destinations);
    }

    function _get(uint256 id) internal view returns (Withdrawal storage) {
        if (id >= withdrawals.length) revert UnknownWithdrawal();
        return withdrawals[id];
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == ETH ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    /// @dev `balanceOf` of a tracked asset, or zero when the call fails (an address without code, or a token that
    ///      reverts): a watched asset that can not be read never blocks the others' withdrawals.
    function _tryBalance(address asset) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            asset.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// @dev Charges `amount` against `win` for the current epoch, opening it on `balance` (the balance before the
    ///      withdrawal) when it is the first charge of the epoch.
    function _charge(Window storage win, uint256 balance, uint256 amount) internal {
        uint64 epoch = uint64(block.timestamp / EPOCH);
        if (win.epoch != epoch) {
            win.epoch = epoch;
            win.cap = (balance * rateBps) / BPS;
            win.spent = 0;
        }
        uint256 available = win.cap - win.spent;
        if (amount > available) revert OverWeeklyCap(available);
        win.spent += amount;
    }
}
