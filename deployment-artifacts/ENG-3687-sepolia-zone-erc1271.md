# ENG-3687 Sepolia MarketplaceZone with ERC-1271 (Safe) signer

Base commit: `062f0492` (`origin/main`)
Network: Sepolia (`11155111`)
Deployer / seller EOA: `0xBF03076547a99857b796717faF4034dea94569dF`

Scope: item 1 only — deploy a new `FabricaMarketplaceZone` on Sepolia whose
`oracleSigner` is a **contract** signer, and prove a real marketplace order
authorized by that contract signer fulfills through it. The mainnet Zone
redeploy and the production Safe custody selection are item 2 and are **not**
touched here. Mainnet Zone `0x3a44d64f28135c82bc39b4cb90fb5a3c0a0309f7` was
not read from, written to, or otherwise involved.

## Why a new deployment was required

`FabricaMarketplaceZone.oracleSigner` is `immutable` and set in the
constructor, so the signer cannot be rotated on an existing Zone. The contract
already supports contract signers — `_verify` branches on
`oracleSigner.code.length` and calls `IERC1271.isValidSignature` — so only a
redeploy pointed at a contract signer was needed. No source change was made to
`FabricaMarketplaceZone.sol` in this PR.

## Signer choice: a 2-of-2 Safe

The signer is a **canonical Safe v1.4.1** deployed from the canonical Sepolia
factory, with **threshold 2 of 2 owners**. Threshold and owners were free
choices for the proof; 2-of-2 was chosen deliberately over 1-of-1 because a
1-of-1 Safe still permits a single key to authorize every order, which is the
exact property ENG-3687 exists to remove. Proving the multi-owner path is what
makes the result useful to the item-2 custody decision.

The owners are **two disposable keys generated for this lane only**. They hold
no funds, guard nothing else, and are not intended to survive this proof. This
Safe is a **test** signer: it must never be configured into a deployed
environment.

Canonical Safe v1.4.1 contracts used (all pre-existing on Sepolia, verified
non-empty bytecode before use):

| Role | Address |
| --- | --- |
| `SafeProxyFactory` 1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |
| `Safe` singleton 1.4.1 | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| `CompatibilityFallbackHandler` 1.4.1 | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |

The `CompatibilityFallbackHandler` is load-bearing: it is what supplies
`isValidSignature(bytes32,bytes)` and `getMessageHash(bytes)` on the Safe. A
Safe configured with a zero fallback handler would **not** answer ERC-1271 and
the Zone would revert on every order.

## Parameter review gate

### Safe `setup` — intended vs deployed

Called via `SafeProxyFactory.createProxyWithNonce(singleton, initializer, 3687)`.

| Parameter | Intended | Deployed (read back on-chain) |
| --- | --- | --- |
| `_owners[0]` | `0x0af6aaDc74927B7A5cbd8Ab339834c38b10f3b3F` | `0x0af6aaDc74927B7A5cbd8Ab339834c38b10f3b3F` |
| `_owners[1]` | `0xbC6718D825B41ED0Bdee0D8e269B3644e728EDeD` | `0xbC6718D825B41ED0Bdee0D8e269B3644e728EDeD` |
| `_threshold` | `2` | `2` |
| `to` | `0x0000…0000` (no setup delegatecall) | n/a — no module/guard installed |
| `data` | `0x` | n/a |
| `fallbackHandler` | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |
| `paymentToken` | `0x0000…0000` | n/a |
| `payment` | `0` | n/a |
| `paymentReceiver` | `0x0000…0000` | n/a |
| singleton (slot 0) | `0x41675C099F32341bf84BFc5382aF534df5C7461a` | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| `VERSION()` | `1.4.1` | `1.4.1` |

### `FabricaMarketplaceZone` constructor — intended vs deployed

The constructor takes exactly one argument.

| Parameter | Intended | Deployed (read back on-chain) |
| --- | --- | --- |
| `_oracleSigner` | `0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8` (the Safe) | `oracleSigner()` → `0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8` |

Encoded constructor args as submitted to Etherscan:

```text
000000000000000000000000b9c4179d0b25b813a641b5809e7b0fd05483ead8
```

Derived state read back after deploy:

```text
cast call 0x892f9A7067a82Dbc49A3e557b08767C20fa1B061 'oracleSigner()(address)'
0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8

cast call 0x892f9A7067a82Dbc49A3e557b08767C20fa1B061 'MAX_AGE()(uint256)'
604800

cast code 0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8 | wc -c
345          # non-empty => the zone takes its ERC-1271 branch, not ECDSA.recover
```

`MAX_AGE` is `604800` = 7 days, unchanged from the existing deployments.

## Deployment summary

| Step | Address | Tx | Block | Status |
| --- | --- | --- | --- | --- |
| Deploy 2-of-2 Safe proxy | `0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8` | `0xa0f4748f59c3faafc2db5bb13a2f9799b556a4a2e25d2992e9b3d4f50efb094d` | `11488271` | success |
| Deploy `FabricaMarketplaceZone` | `0x892f9A7067a82Dbc49A3e557b08767C20fa1B061` | `0x6115e1328c4db228ef16c42cec067e31863687b04d43db1629a39121ccea4868` | `11488278` | success |
| Mint fixture property token | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` id `298855539945321607` | `0xa593ba6909200465d98414c3e2e0b64348a03ecb709815c5e844fdc237883835` | `11488287` | success |
| Seller approves Seaport 1.6 | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` | `0x92d938906c80b4fdb9c6a77c1355a5cffa815ce4d7c9a89e8e4f5501cea36f0b` | — | success |
| **Fulfill order through the new Zone** | Seaport `0x0000000000000068F116a894984e2DB1123eB395` | `0xbec9380cae6c5bf8ef6383a483c75bfecc3cdbc7dd5004f201560bb6dddc9ddc` | `11488310` | success |

The Zone is Etherscan-verified:
<https://sepolia.etherscan.io/address/0x892f9a7067a82dbc49a3e557b08767c20fa1b061>

Foundry broadcast record is committed at
`broadcast/FabricaMarketplaceZone.s.sol/11155111/run-latest.json`.

## End-to-end proof

A real Seaport 1.6 `FULL_RESTRICTED` order, offering a real Fabrica ERC-1155
property token, with `zone` set to the new Zone, authorized by a 2-of-2 Safe
ERC-1271 signature, fulfilled on Sepolia.

The fulfiller is `0x59d0b67A4F67149E4A3a7615B9d5e5D153BDa9c8`, which is **not**
the offerer. This matters: Seaport skips the restricted-order zone callback
when the caller is the offerer or the zone itself, so a self-fulfilled order
would have proved nothing. Because the fulfiller is a third party, Seaport
genuinely invoked `authorizeOrder` and `validateOrder`.

Order and authorization values:

```text
orderHash            0x31ac743402a7daec3e3e10311a33b766806faf162c328d925a57d3a094b8347b
zone                 0x892f9A7067a82Dbc49A3e557b08767C20fa1B061
orderType            2 (FULL_RESTRICTED)
offer                ERC1155 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD id 298855539945321607 amount 1
consideration        1000000000000000 wei NATIVE -> 0xBF03076547a99857b796717faF4034dea94569dF
zone domainSeparator 0x6c70406c966b1f0f5aba556d1d1fb51c8a499933387085338c46c6c9f571ffec
expiry               1786727956            (fulfilled at block timestamp 1786724364)
definitionUrl        ipfs://QmEng3687FregolottaZoneErc1271Proof
disclosurePackageId  e0036870-0000-4000-8000-000000003687   (36 bytes)
zone digest          0x085069988deaacd6b7f1fe9f5b79ae5a4eb1dac28d210d4fcbafaa7f58fcd81c
safe getMessageHash  0x2723e4acc561cd46a7e096d6d861cf04eca6c801a19201697c27908eb0a27352
safe signature       130 bytes (two 65-byte owner signatures, ascending owner order)
isValidSignature     0x1626ba7e
extraData            218 bytes = expiry(8) | defUrlLen(2) | defUrl(42) | dpId(36) | sig(130)
fulfill tx           0xbec9380cae6c5bf8ef6383a483c75bfecc3cdbc7dd5004f201560bb6dddc9ddc
status               1  (block 11488310, gasUsed 233561)
```

The non-empty `definitionUrl` means the Zone's `_verifyDefinitionUrl` path also
executed, reading `_property(tokenId)` from the live FabricaToken and comparing
it against the signed URL. Token balances after the fill confirm real
settlement: seller `999`, buyer `1`.

## Negative controls

Run against the same live Zone and Safe with a second real order
(`0xe1a2a1c22467f26ea66f8aab5627dac1d9ca6937d88c2b0d08d7129e10efe249`), as
static `fulfillAdvancedOrder` calls. These are what establish the happy path
was not vacuous.

| Variant | Signature | Expected | Observed |
| --- | --- | --- | --- |
| Valid 2-of-2 Safe signature | 130 bytes | succeed | `fulfilled = true` |
| Only 1 of 2 owners signed | 65 bytes | revert | revert `GS020` |
| 2-of-2 blob, one byte flipped | 130 bytes | revert | revert `GS026` |
| EOA signature over the raw zone digest | 65 bytes | revert | revert `GS020` |

`GS020` is Safe's "signatures data too short" and `GS026` its "invalid owner
provided". Note that a rejected contract signature surfaces as the Safe's own
revert string rather than the Zone's `"Bad oracle sig"`: `checkSignatures`
reverts internally instead of returning a non-magic value, so the Zone's
comparison branch is never reached. Anyone writing alerting against this path
should match on the Safe errors, not on `"Bad oracle sig"`.

## Regression coverage

`test/FabricaMarketplaceZoneSepoliaErc1271Fork.t.sol` pins Sepolia block
`11488310` and re-plays the exact bytes above against the live deployment: the
signer is a contract, the Safe is 2-of-2, `isValidSignature` returns the magic
value, `authorizeOrder`/`validateOrder` accept, and the three negative variants
revert. It skips when `SEPOLIA_RPC_URL` is absent so ordinary CI stays green.

## Hand-off to item 2 (mainnet custody)

Two findings that constrain the custody decision.

**1. A config-only zone repoint cannot work for any Safe — 1-of-1 included.**
`fabrica-v3-api` signs the fulfillment permission with a single EOA over the
**Zone's** EIP-712 digest (`marketplace.service.ts` L1468-1471 builds
`new Wallet(fulfillmentPermissionPrivateKey)`; L1506-1507 calls
`_signTypedData` with `domain.verifyingContract` = the zone). A Safe does not
accept that signature. Safe v1.4.1's `isValidSignature` re-wraps the incoming
hash in the Safe's **own** EIP-712 domain — `SafeMessage(bytes message)` over
`abi.encode(zoneDigest)` — and runs `checkSignatures` against that hash. So the
API must fetch the Safe message hash and sign it with N owner keys concatenated
in ascending owner-address order. This is verified on-chain, not inferred: the
"EOA signature over the raw zone digest" negative control above is exactly the
signature shape the API produces today, and it reverts. Item 2 must fund an
`fabrica-v3-api` signing change (Safe message hash derivation, multi-owner
signing, and key management for N owners) before **any** Safe custody works.

**2. A latent constraint in the extraData encoder, narrower than it first
appears.** `MarketplaceService.permissionToExtraData` asserts
`signatureBytes[64]` is `27` or `28`. Byte 64 is the last byte of signature #1
for a blob of any owner count, so this does **not** reject multi-owner blobs
per se — a 2-of-2 blob passes, as confirmed against the live Safe. It does
reject two shapes that are plausible in real custody: owners signing via
`personal_sign`/`eth_sign` (Safe encodes `v` as 31/32) and Safe's
contract-signature (`v = 0`) and pre-approved-hash (`v = 1`) owner types, which
arise with hardware wallets and nested Safes. Treat it as a constraint on which
custody configurations are reachable without an encoder change, not as a
blocker on multi-owner signing.

Neither change is implemented here — both are `fabrica-v3-api` money-path
signing code and out of scope for this lane.

## Correction to the ticket's on-chain facts

ENG-3687 lists Sepolia Zone `0xa02015acdc38839221ca38cde01ed32f588b551b` as
though it were the Sepolia Zone. It is the **production**-stage Sepolia entry.
The per-stage mapping actually in `fabrica-v3-api/config/*.json` is:

| Stage config | `ethereum` zone | `sepolia` zone |
| --- | --- | --- |
| `develop.json` | `0x20174783FBF0f9D2e28C9e544cA4515B6F87Ad2F` | `0x485d38D9b1c1599E2169DbAEA07ea0967A188AeD` |
| `staging.json` | `0x3a44D64f28135C82bC39b4cB90Fb5a3c0A0309f7` | `0xbB6600e35a1Ab708123d46324179Bd2557DF76C2` |
| `production.json` | `0x35768a81a4360d1Ca453D9EC6eD50aB04ABfEb9b` | `0xA02015aCdc38839221Ca38CdE01ED32F588B551b` |

Staging's Sepolia zone is the ticket's "W1" Zone `0xbB6600e3…`, not
`0xa02015…`. Whoever executes the item-2 cutover needs the per-stage mapping,
not a single "the Sepolia Zone" address.

## What was deliberately not done

No deployed environment was repointed. Changing
`networks.sepolia.marketplace.fabricaZoneAddress` in `config/staging.json`
would make shared staging's order flow depend on this lane's disposable 2-of-2
test keys, and — per finding 1 — could only ever exercise a degenerate case
anyway, since the API cannot produce a Safe-valid signature at all. The e2e was
therefore run directly against Sepolia. The staging and production repoints
belong to the item-2 cutover.
