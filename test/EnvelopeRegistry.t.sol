// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EnvelopeRegistry} from "../src/EnvelopeRegistry.sol";
import {IBoundedAgentAction} from "../src/IBoundedAgentAction.sol";
import {IBudgetSubstrate} from "../src/IBudgetSubstrate.sol";
import {IContestableEnvelope} from "../src/IContestableEnvelope.sol";
import {IERC165} from "../src/IERC165.sol";

/// @notice Conformance suite for the Bounded Agent Actions reference registry.
contract EnvelopeRegistryTest is Test {
    EnvelopeRegistry internal reg;

    uint256 internal constant PK = 0xA11CE;
    address internal principal;
    address internal constant THIRD = address(0xBEEF);
    address internal constant ASSET = address(0xA55E7);
    uint256 internal constant CAP = 1000 ether;

    function setUp() public {
        reg = new EnvelopeRegistry();
        principal = vm.addr(PK);
    }

    // ----------------------------- helpers ------------------------------- //

    function _capRoot(uint256 cap, address asset) internal pure returns (bytes32) {
        return keccak256(abi.encode(cap, asset));
    }

    function _registerSelf(bytes32 salt, uint64 expiresAt) internal returns (bytes32 id) {
        bytes memory initData = abi.encode(CAP, ASSET, salt, bytes(""));
        vm.prank(principal);
        id = reg.registerEnvelope(principal, _capRoot(CAP, ASSET), expiresAt, initData);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _advance(bytes32 id, uint256 amount) internal {
        bytes32 prev = reg.getCursor(id);
        bytes memory auth = _sign(PK, reg.advanceDigest(id, prev, amount));
        reg.advanceCursor(id, abi.encode(amount, auth));
    }

    // --------------------------- registration ---------------------------- //

    function test_RegisterSelf_Active_EmptyCursor() public {
        bytes32 id = _registerSelf(bytes32("s1"), 0);
        assertEq(uint256(reg.getStatus(id)), uint256(IBoundedAgentAction.Status.Active));
        assertTrue(reg.isActive(id));
        assertEq(reg.getCursor(id), keccak256(abi.encode(uint256(0))));

        IBoundedAgentAction.Envelope memory e = reg.getEnvelope(id);
        assertEq(e.principal, principal);
        assertEq(e.cursorRoot, reg.getCursor(id)); // getCursor == getEnvelope().cursorRoot
        assertEq(uint256(e.status), uint256(IBoundedAgentAction.Status.Active));

        (uint256 cap, address asset) = reg.bound(id);
        assertEq(cap, CAP);
        assertEq(asset, ASSET);
        assertEq(reg.remaining(id), CAP);
        assertEq(reg.spent(id), 0);
    }

    function test_Register_EmitsEvent() public {
        bytes32 salt = bytes32("ev");
        bytes32 capRoot = _capRoot(CAP, ASSET);
        bytes32 id = reg.computeId(principal, capRoot, salt);
        vm.expectEmit(true, true, true, true, address(reg));
        emit IBoundedAgentAction.EnvelopeRegistered(id, principal, capRoot);
        vm.prank(principal);
        reg.registerEnvelope(principal, capRoot, 0, abi.encode(CAP, ASSET, salt, bytes("")));
    }

    function test_Register_CapabilityMismatch_Reverts() public {
        vm.prank(principal);
        vm.expectRevert(EnvelopeRegistry.CapabilityMismatch.selector);
        reg.registerEnvelope(principal, bytes32("wrong"), 0, abi.encode(CAP, ASSET, bytes32("s"), bytes("")));
    }

    function test_Register_BadExpiry_Reverts() public {
        vm.warp(1000);
        vm.prank(principal);
        vm.expectRevert(EnvelopeRegistry.BadExpiry.selector);
        reg.registerEnvelope(principal, _capRoot(CAP, ASSET), uint64(500), abi.encode(CAP, ASSET, bytes32("s"), bytes("")));
    }

    function test_Register_ThirdParty_RequiresPrincipalSig() public {
        bytes32 capRoot = _capRoot(CAP, ASSET);
        bytes32 salt = bytes32("s3");

        // without a valid sig -> Unauthorized
        vm.prank(THIRD);
        vm.expectRevert(EnvelopeRegistry.Unauthorized.selector);
        reg.registerEnvelope(principal, capRoot, 0, abi.encode(CAP, ASSET, salt, bytes("")));

        // with the principal's signature -> success
        bytes memory sig = _sign(PK, reg.registrationDigest(principal, capRoot, 0, salt));
        vm.prank(THIRD);
        bytes32 id = reg.registerEnvelope(principal, capRoot, 0, abi.encode(CAP, ASSET, salt, sig));
        assertEq(reg.getEnvelope(id).principal, principal);
    }

    function test_ComputeId_Matches() public {
        bytes32 salt = bytes32("cid");
        bytes32 expected = reg.computeId(principal, _capRoot(CAP, ASSET), salt);
        assertEq(_registerSelf(salt, 0), expected);
    }

    function test_IdReuse_Reverts_IncludingAfterTerminal() public {
        bytes32 salt = bytes32("dup");
        bytes32 id = _registerSelf(salt, 0);
        bytes memory initData = abi.encode(CAP, ASSET, salt, bytes(""));

        vm.prank(principal);
        vm.expectRevert(EnvelopeRegistry.IdExists.selector);
        reg.registerEnvelope(principal, _capRoot(CAP, ASSET), 0, initData);

        vm.prank(principal);
        reg.setStatus(id, IBoundedAgentAction.Status.Revoked);

        vm.prank(principal);
        vm.expectRevert(EnvelopeRegistry.IdExists.selector);
        reg.registerEnvelope(principal, _capRoot(CAP, ASSET), 0, initData);
    }

    // ------------------------------ advance ------------------------------ //

    function test_Advance_UpdatesCursor_And_Remaining() public {
        bytes32 id = _registerSelf(bytes32("a1"), 0);

        vm.expectEmit(true, false, false, true, address(reg));
        emit IBoundedAgentAction.EnvelopeAdvanced(id, keccak256(abi.encode(uint256(0))), keccak256(abi.encode(uint256(100 ether))));
        _advance(id, 100 ether);

        assertEq(reg.spent(id), 100 ether);
        assertEq(reg.getCursor(id), keccak256(abi.encode(uint256(100 ether))));
        assertEq(reg.remaining(id), CAP - 100 ether);
        // profile invariant: keccak(cap - remaining) == cursor while Active
        assertEq(keccak256(abi.encode(CAP - reg.remaining(id))), reg.getCursor(id));
        // getCursor == getEnvelope().cursorRoot after advance
        assertEq(reg.getCursor(id), reg.getEnvelope(id).cursorRoot);
    }

    function test_Advance_BoundExceeded_Reverts() public {
        bytes32 id = _registerSelf(bytes32("a2"), 0);
        uint256 amount = CAP + 1;
        bytes memory auth = _sign(PK, reg.advanceDigest(id, reg.getCursor(id), amount));
        vm.expectRevert(EnvelopeRegistry.BoundExceeded.selector);
        reg.advanceCursor(id, abi.encode(amount, auth));
    }

    function test_Advance_Replay_Reverts() public {
        bytes32 id = _registerSelf(bytes32("a3"), 0);
        uint256 amount = 50 ether;
        bytes memory auth = _sign(PK, reg.advanceDigest(id, reg.getCursor(id), amount));
        bytes memory witness = abi.encode(amount, auth);
        reg.advanceCursor(id, witness); // first succeeds
        vm.expectRevert(EnvelopeRegistry.BadWitness.selector);
        reg.advanceCursor(id, witness); // prevCursor changed -> replay rejected
    }

    function test_Advance_WrongEnvelope_Reverts() public {
        bytes32 idA = _registerSelf(bytes32("a4"), 0);
        bytes32 idB = _registerSelf(bytes32("a5"), 0);
        uint256 amount = 10 ether;
        bytes memory auth = _sign(PK, reg.advanceDigest(idA, reg.getCursor(idA), amount)); // signed for A
        vm.expectRevert(EnvelopeRegistry.BadWitness.selector);
        reg.advanceCursor(idB, abi.encode(amount, auth)); // used on B
    }

    function test_Advance_NonActive_Reverts() public {
        bytes32 id = _registerSelf(bytes32("a6"), 0);
        vm.prank(principal);
        reg.setStatus(id, IBoundedAgentAction.Status.Revoked);
        bytes memory auth = _sign(PK, reg.advanceDigest(id, reg.getCursor(id), 1 ether));
        vm.expectRevert(EnvelopeRegistry.NotActive.selector);
        reg.advanceCursor(id, abi.encode(uint256(1 ether), auth));
    }

    function test_Advance_Expired_Reverts() public {
        vm.warp(1000);
        bytes32 id = _registerSelf(bytes32("a7"), uint64(2000));
        bytes memory auth = _sign(PK, reg.advanceDigest(id, reg.getCursor(id), 1 ether));
        vm.warp(2001);
        vm.expectRevert(EnvelopeRegistry.NotActive.selector);
        reg.advanceCursor(id, abi.encode(uint256(1 ether), auth));
    }

    // ----------------------------- lifecycle ----------------------------- //

    function test_SetStatus_PrincipalRevoke() public {
        bytes32 id = _registerSelf(bytes32("l1"), 0);
        vm.prank(principal);
        reg.setStatus(id, IBoundedAgentAction.Status.Revoked);
        assertEq(uint256(reg.getStatus(id)), uint256(IBoundedAgentAction.Status.Revoked));
    }

    function test_SetStatus_NonPrincipal_Reverts() public {
        bytes32 id = _registerSelf(bytes32("l2"), 0);
        vm.prank(THIRD);
        vm.expectRevert(EnvelopeRegistry.Unauthorized.selector);
        reg.setStatus(id, IBoundedAgentAction.Status.Revoked);
    }

    function test_SetStatus_ExpirePermissionless() public {
        vm.warp(1000);
        bytes32 id = _registerSelf(bytes32("l3"), uint64(2000));
        vm.warp(2001);
        vm.prank(THIRD); // any caller may expire after the timestamp
        reg.setStatus(id, IBoundedAgentAction.Status.Expired);
        assertEq(uint256(reg.getStatus(id)), uint256(IBoundedAgentAction.Status.Expired));
    }

    function test_SetStatus_Contested_Reverts_BaseUnsupported() public {
        bytes32 id = _registerSelf(bytes32("l4"), 0);
        vm.prank(principal);
        vm.expectRevert(EnvelopeRegistry.BadTransition.selector);
        reg.setStatus(id, IBoundedAgentAction.Status.Contested);
    }

    function test_SetStatus_Terminal_Reverts() public {
        bytes32 id = _registerSelf(bytes32("l5"), 0);
        vm.prank(principal);
        reg.setStatus(id, IBoundedAgentAction.Status.Revoked);
        vm.prank(principal);
        vm.expectRevert(EnvelopeRegistry.BadTransition.selector);
        reg.setStatus(id, IBoundedAgentAction.Status.Completed);
    }

    // ----------------------------- reads / expiry ------------------------ //

    function test_Status_And_IsActive_FoldExpiry() public {
        vm.warp(1000);
        bytes32 id = _registerSelf(bytes32("e1"), uint64(2000));
        assertTrue(reg.isActive(id));
        vm.warp(2001);
        assertEq(uint256(reg.getStatus(id)), uint256(IBoundedAgentAction.Status.Expired));
        assertFalse(reg.isActive(id));
        assertEq(uint256(reg.getEnvelope(id).status), uint256(IBoundedAgentAction.Status.Expired));
        assertEq(reg.remaining(id), 0); // remaining 0 when inactive
    }

    function test_UnknownId_AllReadsRevert() public {
        bytes32 bad = keccak256("nope");
        vm.expectRevert(EnvelopeRegistry.UnknownEnvelope.selector);
        reg.getEnvelope(bad);
        vm.expectRevert(EnvelopeRegistry.UnknownEnvelope.selector);
        reg.getCursor(bad);
        vm.expectRevert(EnvelopeRegistry.UnknownEnvelope.selector);
        reg.getStatus(bad);
        vm.expectRevert(EnvelopeRegistry.UnknownEnvelope.selector);
        reg.isActive(bad);
        vm.expectRevert(EnvelopeRegistry.UnknownEnvelope.selector);
        reg.bound(bad);
        vm.expectRevert(EnvelopeRegistry.UnknownEnvelope.selector);
        reg.spent(bad);
        vm.expectRevert(EnvelopeRegistry.UnknownEnvelope.selector);
        reg.remaining(bad);
    }

    // ------------------------------ ERC-165 ------------------------------ //

    function test_SupportsInterface() public view {
        assertTrue(reg.supportsInterface(type(IERC165).interfaceId));
        assertTrue(reg.supportsInterface(type(IBoundedAgentAction).interfaceId));
        assertTrue(reg.supportsInterface(type(IBudgetSubstrate).interfaceId));
        assertFalse(reg.supportsInterface(0xffffffff));
    }

    // ------------- emit the frozen interfaceIds for the spec ------------- //

    function test_LogInterfaceIds() public {
        emit log_named_bytes32("IBoundedAgentAction.interfaceId", bytes32(uint256(uint32(type(IBoundedAgentAction).interfaceId))));
        emit log_named_bytes32("IBudgetSubstrate.interfaceId", bytes32(uint256(uint32(type(IBudgetSubstrate).interfaceId))));
        emit log_named_bytes32("IContestableEnvelope.interfaceId", bytes32(uint256(uint32(type(IContestableEnvelope).interfaceId))));
    }
}
