// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IBoundedAgentAction} from "./IBoundedAgentAction.sol";
import {IBudgetSubstrate} from "./IBudgetSubstrate.sol";
import {IERC165} from "./IERC165.sol";

/// @title EnvelopeRegistry
/// @notice Minimal CC0 reference implementation of the Bounded Agent Actions ERC,
///         conforming to the Budget Substrate Profile (IBudgetSubstrate).
/// @dev Reference only. This is a toy budget substrate: the cursor is a running
///      spend counter and the witness is an ECDSA authorization bound to
///      (id, prevCursor). It binds no assets and gates no execution path, so it is
///      NOT non-bypassable by the principal's own key (that is a substrate
///      obligation the ERC documents and this minimal example does not attempt).
///      It exists to demonstrate the interface, the profile semantics, and the
///      conformance test vectors.
contract EnvelopeRegistry is IBudgetSubstrate {
    struct Record {
        address principal;
        bytes32 capabilityRoot;
        bytes32 cursorRoot;
        uint64 createdAt;
        uint64 expiresAt;
        Status status; // stored status; reads fold in expiry
        uint256 cap;
        address asset;
        uint256 spent;
    }

    mapping(bytes32 => Record) private _records;
    uint256 private _lock = 1;

    bytes32 private constant EMPTY_CURSOR = keccak256(abi.encode(uint256(0)));
    bytes32 private constant REGISTER_TYPEHASH =
        keccak256("Register(address principal,bytes32 capabilityRoot,uint64 expiresAt,bytes32 salt)");
    bytes32 private constant ADVANCE_TYPEHASH =
        keccak256("Advance(bytes32 id,bytes32 prevCursor,uint256 amount)");

    error UnknownEnvelope();
    error IdExists();
    error BadExpiry();
    error CapabilityMismatch();
    error Unauthorized();
    error NotActive();
    error BoundExceeded();
    error BadWitness();
    error BadTransition();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // --------------------------------------------------------------------- //
    // Registration                                                          //
    // --------------------------------------------------------------------- //

    /// @notice Deterministic id derivation; callers may precompute the reference
    ///         before registration and embed it upstream.
    function computeId(address principal, bytes32 capabilityRoot, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), principal, capabilityRoot, salt));
    }

    /// @inheritdoc IBoundedAgentAction
    /// @dev initData = abi.encode(uint256 cap, address asset, bytes32 salt, bytes principalSig).
    ///      capabilityRoot MUST equal keccak256(abi.encode(cap, asset)).
    ///      If principal != msg.sender, principalSig MUST be a valid EIP-712
    ///      signature by principal over the registration digest.
    function registerEnvelope(address principal, bytes32 capabilityRoot, uint64 expiresAt, bytes calldata initData)
        external
        returns (bytes32 id)
    {
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert BadExpiry();

        (uint256 cap, address asset, bytes32 salt, bytes memory principalSig) =
            abi.decode(initData, (uint256, address, bytes32, bytes));
        if (capabilityRoot != keccak256(abi.encode(cap, asset))) revert CapabilityMismatch();

        id = computeId(principal, capabilityRoot, salt);
        if (_records[id].status != Status.None) revert IdExists();

        if (principal != msg.sender) {
            bytes32 d = registrationDigest(principal, capabilityRoot, expiresAt, salt);
            if (_recover(d, principalSig) != principal) revert Unauthorized();
        }

        Record storage r = _records[id];
        r.principal = principal;
        r.capabilityRoot = capabilityRoot;
        r.cursorRoot = EMPTY_CURSOR;
        r.createdAt = uint64(block.timestamp);
        r.expiresAt = expiresAt;
        r.status = Status.Active;
        r.cap = cap;
        r.asset = asset;

        emit EnvelopeRegistered(id, principal, capabilityRoot);
    }

    // --------------------------------------------------------------------- //
    // Reads (all revert on unknown id; status folds in expiry)              //
    // --------------------------------------------------------------------- //

    function getEnvelope(bytes32 id) external view returns (Envelope memory) {
        Record storage r = _get(id);
        return Envelope({
            id: id,
            principal: r.principal,
            capabilityRoot: r.capabilityRoot,
            cursorRoot: r.cursorRoot,
            createdAt: r.createdAt,
            expiresAt: r.expiresAt,
            status: _effective(r)
        });
    }

    function getCursor(bytes32 id) external view returns (bytes32) {
        return _get(id).cursorRoot;
    }

    function getStatus(bytes32 id) external view returns (Status) {
        return _effective(_get(id));
    }

    function isActive(bytes32 id) external view returns (bool) {
        return _effective(_get(id)) == Status.Active;
    }

    function bound(bytes32 id) external view returns (uint256 cap, address asset) {
        Record storage r = _get(id);
        return (r.cap, r.asset);
    }

    function spent(bytes32 id) external view returns (uint256) {
        return _get(id).spent;
    }

    function remaining(bytes32 id) external view returns (uint256) {
        Record storage r = _get(id);
        if (_effective(r) != Status.Active) return 0;
        return r.cap - r.spent;
    }

    // --------------------------------------------------------------------- //
    // Advance                                                               //
    // --------------------------------------------------------------------- //

    /// @inheritdoc IBoundedAgentAction
    /// @dev witness = abi.encode(uint256 amount, bytes authorization), where
    ///      authorization is an EIP-712 signature by principal over
    ///      Advance(id, prevCursor, amount). Binding (id, prevCursor) makes the
    ///      witness non-replayable across envelopes and across cursor states.
    function advanceCursor(bytes32 id, bytes calldata witness) external nonReentrant returns (bytes32 newCursor) {
        Record storage r = _get(id);
        if (_effective(r) != Status.Active) revert NotActive();

        (uint256 amount, bytes memory authorization) = abi.decode(witness, (uint256, bytes));
        if (r.spent + amount > r.cap) revert BoundExceeded();

        bytes32 prevCursor = r.cursorRoot;
        if (_recover(advanceDigest(id, prevCursor, amount), authorization) != r.principal) revert BadWitness();

        // checks-effects: state finalized before returning; no external calls here.
        r.spent += amount;
        newCursor = keccak256(abi.encode(r.spent));
        r.cursorRoot = newCursor;
        emit EnvelopeAdvanced(id, prevCursor, newCursor);
    }

    // --------------------------------------------------------------------- //
    // Lifecycle (base transitions only; Contested is an optional extension) //
    // --------------------------------------------------------------------- //

    function setStatus(bytes32 id, Status newStatus) external {
        Record storage r = _get(id);
        Status cur = r.status;
        if (cur != Status.Active) revert BadTransition(); // terminal or Contested: base does not transition

        bool expired = r.expiresAt != 0 && block.timestamp >= r.expiresAt;
        if (newStatus == Status.Expired) {
            if (!expired) revert BadTransition();
            // permissionless once the expiry timestamp is reached
        } else {
            if (expired) revert BadTransition(); // effectively expired: the only exit is Expired
            if (newStatus == Status.Revoked || newStatus == Status.Completed) {
                if (msg.sender != r.principal) revert Unauthorized();
            } else {
                revert BadTransition(); // Contested / Active / None not permitted by the base registry
            }
        }

        r.status = newStatus;
        emit EnvelopeStatusChanged(id, cur, newStatus);
    }

    // --------------------------------------------------------------------- //
    // ERC-165                                                               //
    // --------------------------------------------------------------------- //

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IBoundedAgentAction).interfaceId
            || interfaceId == type(IBudgetSubstrate).interfaceId;
        // 0xffffffff matches none of the above and therefore returns false.
    }

    // --------------------------------------------------------------------- //
    // EIP-712 digest helpers (public so integrators can build signatures)   //
    // --------------------------------------------------------------------- //

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BoundedAgentActions"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function registrationDigest(address principal, bytes32 capabilityRoot, uint64 expiresAt, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return _digest(keccak256(abi.encode(REGISTER_TYPEHASH, principal, capabilityRoot, expiresAt, salt)));
    }

    function advanceDigest(bytes32 id, bytes32 prevCursor, uint256 amount) public view returns (bytes32) {
        return _digest(keccak256(abi.encode(ADVANCE_TYPEHASH, id, prevCursor, amount)));
    }

    // --------------------------------------------------------------------- //
    // Internal                                                              //
    // --------------------------------------------------------------------- //

    function _get(bytes32 id) private view returns (Record storage r) {
        r = _records[id];
        if (r.status == Status.None) revert UnknownEnvelope();
    }

    function _effective(Record storage r) private view returns (Status) {
        if (r.status == Status.Active && r.expiresAt != 0 && block.timestamp >= r.expiresAt) {
            return Status.Expired;
        }
        return r.status;
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function _recover(bytes32 digest, bytes memory sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return ecrecover(digest, v, r, s);
    }
}
