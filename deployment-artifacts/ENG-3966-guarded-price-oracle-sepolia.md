# ENG-3966 FabricaGuardedSignedPriceOracle — Sepolia deployment record

<!-- markdownlint-disable MD013 -->

Base commit: `7bb6343ac7a8d395020b280b0c144714b224f1f9` (`origin/main`)
Network: **Sepolia (`11155111`) only** — see "No mainnet deployment" below.
Recorded: 2026-09-07, ENG-3966.

This file exists because the address was recorded **nowhere**. There is no
`broadcast/FabricaGuardedSignedPriceOracleDeploy.s.sol/` directory in this
repo, no entry in `DEPLOYMENT.md`, and `GUARDED-PRICE-ORACLE-RUNBOOK.md` told
operators to "set `GUARDED_ORACLE_PROXY` from the deployment log" — a log that
is not in the repository. An in-repo lookup therefore returned nothing and
would have supported the false conclusion that the contract was never
deployed. It was.

## Addresses

| Role | Address |
| --- | --- |
| Proxy (`ERC1967Proxy`) | `0x7f4CE6d333C6d5D7f4EAbFf393c39632459C1682` |
| Implementation (`FabricaGuardedSignedPriceOracle`) | `0xEDd25C20F554256b7D2844078A6E6413213c2072` |
| Deployer EOA | `0xBF03076547a99857b796717faF4034dea94569dF` |
| `owner()` | `0xBF03076547a99857b796717faF4034dea94569dF` |
| `pendingOwner()` | `0x0000000000000000000000000000000000000000` |
| `IMPLEMENTATION_VERSION()` | `1.0.0` |

Creation transaction (proxy **and** implementation, same block):
`0x2ce9e684385387ea2b0bffaa3585db89d7115e9302ab81fb78fd8413a7bc0cc5`,
block `11333976`, status `1 (success)`.

### How it was found

Not from any file. The Sepolia deployer's contract-creation transactions were
enumerated (177 successful creations), and each created contract was probed by
`eth_call` for the oracle-only selector `collateralPolicy(address)`
(`0x586afe2d`). Three responded; two resolved to the proxy/implementation pair
above. Record the address here on any future deployment so this is never
necessary again.

## Do not confuse this with the metastreet-fork oracle

`0xb6082EAe8D56e38cF9d3f02d634d6F90D68B552D` on Sepolia also answers
`collateralPolicy(address)`. It is **not** this contract. It reports
`IMPLEMENTATION_VERSION() = "1.4"`, has an **empty** EIP-1967 implementation
slot (it is a direct, non-upgradeable deployment), and is the
`SimpleSignedPriceOracle` from
[`fabrica-land/metastreet-contracts-v2`](https://github.com/fabrica-land/metastreet-contracts-v2)
— the "guarded oracle" of ENG-3686 / ENG-3695. Different repository, different
contract, different upgrade model.

## Initialization is atomic — the proof

`script/FabricaGuardedSignedPriceOracleDeploy.s.sol:21-22` passes
`abi.encodeCall(FabricaGuardedSignedPriceOracle.initialize, (owner, name))` as
`ERC1967Proxy`'s `_data`. The deployed proxy confirms the script was followed:
the constructor arguments decoded out of the creation transaction's input are

| Field | Value |
| --- | --- |
| `_logic` | `0xedd25c20f554256b7d2844078a6e6413213c2072` |
| `_data` length | **164 bytes (non-empty)** |
| `_data` selector | `0xf399e22e` = `initialize(address,string)` |
| `_data` arg 0 (`initialOwner`) | `0xbf03076547a99857b796717faf4034dea94569df` |
| `_data` arg 1 (`name`) | `"Fabrica Guarded Signed Price Oracle"` |

and the receipt for that single transaction carries all three logs on the
proxy address:

| Topic 0 | Event |
| --- | --- |
| `0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b` | `Upgraded(address)` → implementation |
| `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | `OwnershipTransferred(address,address)` → `0x0` to deployer |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)`, data `1` |

Creation and initialization are the same transaction. There was never a window
in which a stranger could have called `initialize` — not one block.

## Read-only state readback

| Read | Value |
| --- | --- |
| EIP-1967 implementation slot | `0x…edd25c20f554256b7d2844078a6e6413213c2072` |
| EIP-1967 admin slot | `0x0` (plain `ERC1967Proxy`, no admin) |
| EIP-1967 beacon slot | `0x0` |
| Proxy `InitializableStorage` (`0xf0c57e16…`) | `0x…0001` (initialized, version 1) |
| Implementation `InitializableStorage` | `0x…ffffffffffffffff` (`_disableInitializers()` ran) |
| Implementation `owner()` | `0x0` (never initialized) |
| `initialize(...)` re-call, proxy, from a stranger | reverts `0xf92ee8a9` = `InvalidInitialization()` |
| `initialize(...)` call, implementation, from a stranger | reverts `0xf92ee8a9` = `InvalidInitialization()` |

Every command was `cast call` / `cast storage` against a public read endpoint.
No broadcast, no transaction, no state change.

## Open item: owner is an EOA, not a Safe

`GUARDED-PRICE-ORACLE-RUNBOOK.md` states "The owner should be a Safe. The owner
controls policy and authorizes upgrades." The deployed Sepolia proxy's owner is
the deployer EOA `0xBF03076547a99857b796717faF4034dea94569dF`, and
`pendingOwner()` is zero, so no `Ownable2Step` handoff is in flight. UUPS
upgrade authority for this proxy therefore rests on a single testnet key.

Sepolia-only, and **not** changed by ENG-3966. Tracked under ENG-3805 (oracle
trust-hierarchy hardening / Safe ownership).

## No mainnet deployment

The same creation-scan over the mainnet deployers
(`0xb0DD2Cd32bAd78CCf0303AeA5b643EC1e0bC164b`,
`0xc888F5E3dd4FBeb37F6e1Ba6fa68c83Ab0cf7B2C`, 53 successful creations) found
**zero** contracts answering `collateralPolicy(address)`. There is no
`FabricaGuardedSignedPriceOracle` on Ethereum mainnet.
`GUARDED-PRICE-ORACLE-RUNBOOK.md` § "Mainnet Boundary" still governs any future
mainnet deployment.

## Regression cover

`test/FabricaProxyDeployPathInitialization.t.sol` drives
`script/FabricaGuardedSignedPriceOracleDeploy.s.sol` and
`script/FabricaFeeCollector.s.sol` themselves and asserts each deploy produces
an already-initialized proxy that a stranger cannot re-initialize, behind an
implementation locked by `_disableInitializers()`. Dropping the init data from
either script fails that suite.
