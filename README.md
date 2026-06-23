# Bounded Agent Actions — Reference Implementation

CC0 reference implementation of the Bounded Agent Actions ERC; canonical spec at
[ethereum/ERCs](https://github.com/ethereum/ERCs) (PR link to be added).
Discussion: [Ethereum Magicians](https://ethereum-magicians.org) (thread link to be added).

This repository is the reference implementation only. The normative specification
lives in ethereum/ERCs; this code exists to show the interface is implementable and
the Budget Substrate Profile interoperable.

## Contents

| Path | Role |
|------|------|
| `src/IBoundedAgentAction.sol` | Base interface: register, read, advance, status |
| `src/IBudgetSubstrate.sol` | Typed extension for the Budget Substrate Profile |
| `src/IContestableEnvelope.sol` | Optional contestation extension |
| `src/EnvelopeRegistry.sol` | Reference registry implementing the Budget Substrate Profile |
| `src/IERC165.sol` | Vendored ERC-165 interface (keeps this dependency-free) |
| `test/EnvelopeRegistry.t.sol` | Conformance suite |

## Scope

This is a deliberately minimal budget substrate. The cursor is a running spend
counter and the witness is an ECDSA authorization bound to `(id, prevCursor)`.

It **meters but does not enforce**: it binds no assets and gates no execution path,
so it is not non-bypassable by the principal's own key. Per the ERC, non-bypassability
is a substrate obligation and is out of scope for this minimal example. It contains
no production substrate: no proof system, no execution kernel, no credit logic.

## Frozen ERC-165 interface ids

| Interface | id |
|-----------|------|
| `IBoundedAgentAction` | `0x3985961d` |
| `IBudgetSubstrate` | `0x021ca455` |
| `IContestableEnvelope` | `0xe664d441` |

## Build and test

```
forge install foundry-rs/forge-std
forge test
```

## License

CC0-1.0. See [LICENSE](LICENSE).
