// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IBoundedAgentAction} from "./IBoundedAgentAction.sol";

/// @title IContestableEnvelope
/// @notice Optional extension that owns the Contested lifecycle. A base registry
///         preserves the Contested enum value but need not support entering or
///         leaving it. `contest` and `resolve` MUST also emit the base
///         EnvelopeStatusChanged event.
interface IContestableEnvelope is IBoundedAgentAction {
    event EnvelopeContested(bytes32 indexed id, address indexed challenger);
    event EnvelopeResolved(bytes32 indexed id, Status outcome);

    /// @notice Active -> Contested. Authorization is implementation-defined (for
    ///         example, a bonded challenger). MUST revert unless status is Active.
    function contest(bytes32 id, bytes calldata evidence) external;

    /// @notice Contested -> Active or Contested -> Revoked. MUST be restricted to a
    ///         documented resolver. MUST revert unless status is Contested and
    ///         `outcome` is Active or Revoked.
    function resolve(bytes32 id, Status outcome, bytes calldata resolution) external;
}
