// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "./VaultFactory.sol";

/// @title VaultFactoryNoFee
/// @notice `VaultFactory` for a chain without IMD (Robinhood Chain, chain id 4663): `imd` and `feeRecipient` are both
///         zero, so vaults are free to create here and the project pays its one-time 5 IMD on the Ethereum factory
///         with `payFor(4663, token or vault)`. The radar reads `feePaid` there before granting its seal.
/// @dev The behaviour is exactly `new VaultFactory(IERC20(address(0)), address(0))`, the arguments the brief states
///      for this chain. This contract exists only because the IMD launch manifest does not accept the zero address as
///      a constructor word: it adds nothing, overrides nothing and takes no arguments, so its runtime bytecode is
///      the audited factory's (asserted by `test_NoFeeFactoryIsTheAuditedFactoryWithZeroArguments`). Like the base,
///      it has no owner, calls no contract in its constructor and holds no funds.
contract VaultFactoryNoFee is VaultFactory {
    constructor() VaultFactory(IERC20(address(0)), address(0)) {}
}
