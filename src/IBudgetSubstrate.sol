// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IBoundedAgentAction} from "./IBoundedAgentAction.sol";

/// @title IBudgetSubstrate
/// @notice Typed extension for the Budget Substrate Profile. Under this profile
///         capabilityRoot = keccak256(abi.encode(cap, asset)) and
///         cursorRoot = keccak256(abi.encode(spent)). A consumer reads remaining()
///         directly instead of interpreting the opaque cursor.
interface IBudgetSubstrate is IBoundedAgentAction {
    /// @return cap   Maximum value consumable of `asset` under the envelope.
    /// @return asset The bounded asset.
    function bound(bytes32 id) external view returns (uint256 cap, address asset);

    /// @return Cumulative value consumed under the envelope.
    function spent(bytes32 id) external view returns (uint256);

    /// @return Remaining headroom (cap - spent), or 0 if the envelope is not active.
    ///         A value of 0 is not self-disambiguating; consult isActive to tell an
    ///         exhausted bound from an inactive envelope.
    function remaining(bytes32 id) external view returns (uint256);
}
