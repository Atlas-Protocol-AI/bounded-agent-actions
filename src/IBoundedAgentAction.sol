// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC165} from "./IERC165.sol";

/// @title IBoundedAgentAction
/// @notice Base interface for the Bounded Agent Actions ERC. A registry stores
///         envelopes and meters an agent's aggregate authority across calls via a
///         cursor. This interface meters; it does not enforce. Non-bypassability and
///         atomicity are substrate obligations, not guarantees of this interface.
interface IBoundedAgentAction is IERC165 {
    /// @dev `None` (0) is the not-registered sentinel and is never a stored status
    ///      of a live envelope.
    enum Status {
        None,
        Active,
        Completed,
        Contested,
        Revoked,
        Expired
    }

    struct Envelope {
        bytes32 id;
        address principal;
        bytes32 capabilityRoot;
        bytes32 cursorRoot;
        uint64 createdAt;
        uint64 expiresAt;
        Status status;
    }

    event EnvelopeRegistered(bytes32 indexed id, address indexed principal, bytes32 indexed capabilityRoot);
    event EnvelopeAdvanced(bytes32 indexed id, bytes32 prevCursor, bytes32 newCursor);
    event EnvelopeStatusChanged(bytes32 indexed id, Status fromStatus, Status toStatus);

    function registerEnvelope(address principal, bytes32 capabilityRoot, uint64 expiresAt, bytes calldata initData)
        external
        returns (bytes32 id);

    function getEnvelope(bytes32 id) external view returns (Envelope memory);

    function getCursor(bytes32 id) external view returns (bytes32);

    function getStatus(bytes32 id) external view returns (Status);

    function isActive(bytes32 id) external view returns (bool);

    function advanceCursor(bytes32 id, bytes calldata witness) external returns (bytes32 newCursor);

    function setStatus(bytes32 id, Status newStatus) external;
}
