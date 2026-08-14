# ENG-3687 Sepolia MarketplaceZone with ERC-1271 (Safe) signer

Base commit: `062f04968fda561f1f5b72b46fa8ce4016645004` (`origin/main`)
Network: Sepolia (`11155111`)
Deployer / seller EOA: `0xBF03076547a99857b796717faF4034dea94569dF`

Scope: item 1 only — deploy a new `FabricaMarketplaceZone` on Sepolia whose
`oracleSigner` is a **contract** signer, and prove a real marketplace order
authorized by that contract signer fulfills through it. The mainnet Zone
redeploy and the production Safe custody selection are item 2 and are **not**
touched here.

No mainnet contract was read from, written to, or otherwise involved. Naming
them precisely, because this document elsewhere corrects the ticket for saying
"the Sepolia Zone" as though one existed: the Ethereum-mainnet zones are
`0x3a44D64f28135C82bC39b4cB90Fb5a3c0A0309f7` (**staging** stage) and
`0x35768a81a4360d1Ca453D9EC6eD50aB04ABfEb9b` (**production** stage). Neither
was involved.

## Why a new deployment was required

`FabricaMarketplaceZone.oracleSigner` is `immutable` and set in the
constructor, so the signer cannot be rotated on an existing Zone. The contract
already supports contract signers — `_verify` branches on
`oracleSigner.code.length` and calls `IERC1271.isValidSignature` — so only a
redeploy pointed at a contract signer was needed. No source change was made to
`FabricaMarketplaceZone.sol` in this PR.

## Signer choice: a 2-of-2 Safe (plus a 1-of-1 control Safe)

The signer is a **canonical Safe v1.4.1** deployed from the canonical Sepolia
factory, with **threshold 2 of 2 owners**. Threshold and owners were free
choices for the proof; 2-of-2 was chosen because a 1-of-1 Safe still permits a
single key to authorize every order, which is the property ENG-3687 exists to
remove.

A **second, 1-of-1 Safe** was deployed purely as a control. At threshold 2,
Safe's `checkSignatures` rejects any 65-byte blob on a length precheck
(`signatures.length >= threshold * 65`) before examining a single signature
byte — which would make "the API's signature shape is rejected" unfalsifiable
at threshold 2, since *any* 65 bytes fail identically. The 1-of-1 Safe removes
the length gate so the claim can be tested where it is actually decidable. See
"Negative controls" below.

The owners are **two disposable keys generated for this lane only**. They hold
no funds and guard nothing else. Both Safes are **test** signers and must never
be configured into a deployed environment.

Key disposition: the owner keys and the buyer key live only in this lane's
scratchpad (mode `0600`, outside any git repository) and are destroyed at
wrap-up along with the Foundry keystore created for the deployer. Consequence
to record deliberately: once destroyed, Zone `0x892f9A70…` becomes permanently
un-authorizable — nothing can ever produce a valid order authorization for it
again. That is intended. It is also a second, independent reason the Zone must
never be pointed at by a deployed environment.

Canonical Safe v1.4.1 contracts used (all pre-existing on Sepolia, verified
non-empty bytecode before use):

| Role | Address |
| --- | --- |
| `SafeProxyFactory` 1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |
| `Safe` singleton 1.4.1 | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| `CompatibilityFallbackHandler` 1.4.1 | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |

The `CompatibilityFallbackHandler` is load-bearing: it supplies
`isValidSignature(bytes32,bytes)` and `getMessageHash(bytes)` on the Safe. A
Safe configured with a zero fallback handler would **not** answer ERC-1271 and
the Zone would revert on every order.

## Parameter review gate

### Safe `setup` — intended vs deployed (2-of-2)

Called via `SafeProxyFactory.createProxyWithNonce(singleton, initializer, 3687)`.

| Parameter | Intended | Deployed (read back on-chain) |
| --- | --- | --- |
| `_owners[0]` | `0x0af6aaDc74927B7A5cbd8Ab339834c38b10f3b3F` | `0x0af6aaDc74927B7A5cbd8Ab339834c38b10f3b3F` |
| `_owners[1]` | `0xbC6718D825B41ED0Bdee0D8e269B3644e728EDeD` | `0xbC6718D825B41ED0Bdee0D8e269B3644e728EDeD` |
| `_threshold` | `2` | `2` |
| `to` | `0x0000…0000` (no setup delegatecall) | no module or guard installed |
| `data` | `0x` | n/a |
| `fallbackHandler` | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |
| `paymentToken` / `payment` / `paymentReceiver` | `0x0000…0000` / `0` / `0x0000…0000` | n/a |
| singleton (slot 0) | `0x41675C099F32341bf84BFc5382aF534df5C7461a` | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| `VERSION()` | `1.4.1` | `1.4.1` |

The 1-of-1 control Safe (`saltNonce 36871`) is identical except
`_owners = [0x0af6aaDc74927B7A5cbd8Ab339834c38b10f3b3F]` and `_threshold = 1`;
read back on-chain as owners `[0x0af6aaDc…]`, threshold `1`.

### `FabricaMarketplaceZone` constructor — intended vs deployed

The constructor takes exactly one argument.

| Parameter | Intended | Deployed (read back on-chain) |
| --- | --- | --- |
| `_oracleSigner` | `0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8` (the 2-of-2 Safe) | `oracleSigner()` → `0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8` |

Encoded constructor args as submitted to Etherscan:

```text
000000000000000000000000b9c4179d0b25b813a641b5809e7b0fd05483ead8
```

Build settings actually used (`foundry.toml` sets `auto_detect_solc = true`, so
the compiler is whatever the deploying machine resolved — recording it because
it is not pinned):

| Setting | Value |
| --- | --- |
| solc | `0.8.35+commit.47b9dedd` |
| optimizer | enabled, `runs = 1` |
| evm version | `osaka` |

The Sepolia Zone this replaces in `run-latest.json` was compiled with solc
`0.8.28`. The two creation-code blobs are identical except for the CBOR
metadata trailer and the constructor argument, so there is no behavioural
drift here — but an unpinned compiler on a money-path deploy is a
reproducibility risk that item 2's mainnet deploy should not inherit.

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
| Deploy 1-of-1 control Safe | `0xF19896681Fe823a07044E8D58B2E25374771f3f2` | `0x7543c4dd68c207f2acae6e55af9775a03653d832a9f2132824b1f60be5a6b978` | `11488385` | success |

Only the Zone deploy went through `forge script`, so it is the only step with a
committed Foundry broadcast record
(`broadcast/FabricaMarketplaceZone.s.sol/11155111/run-latest.json`). The other
five were `cast send` calls, which Foundry does not journal; they are verifiable
by transaction hash on Sepolia.

The Zone is Etherscan-verified:
<https://sepolia.etherscan.io/address/0x892f9a7067a82dbc49a3e557b08767c20fa1b061>

⚠️ **`broadcast/FabricaMarketplaceZone.s.sol/11155111/run-latest.json` now points
at a throwaway.** That file is the conventional "latest deployment on this chain"
lookup, and this PR moves it from `0xa02015acdc…` (the production-stage Sepolia
zone) to `0x892f9a70…`, whose signer is a Safe controlled by keys that are
destroyed at wrap-up. The superseded record is preserved verbatim at
`run-1768927198066.json`. Do not read `run-latest` as "the Sepolia Zone".

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
definitionUrl        ipfs://QmEng3687FregolottaZoneErc1271Proof   (synthetic fixture, not a real CID)
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
it against the signed URL. The value is a synthetic fixture label, not a
resolvable CID — `_checkDefinition` is a `keccak256` string equality, so the
path executes identically either way. Token balances after the fill confirm
real settlement: seller `999`, buyer `1`.

## Negative controls

These establish that the happy path was not vacuous. Run against the live Zone
and Safes; all are reproduced by
`test/FabricaMarketplaceZoneSepoliaErc1271Fork.t.sol` so a reader can re-run
them rather than take the table on trust.

| Variant | Safe | Bytes | Expected | Observed |
| --- | --- | --- | --- | --- |
| Valid signature over the Safe message hash | 2-of-2 | 130 | accept | `0x1626ba7e` |
| Only 1 of 2 owners signed | 2-of-2 | 65 | revert | `GS020` |
| Both owners, signing the **raw zone digest** | 2-of-2 | 130 | revert | `GS026` |
| Two well-formed **non-owner** signatures | 2-of-2 | 130 | revert | `GS026` |
| Valid authorization for a **different order** | 2-of-2 | 130 | revert | `GS026` |
| 2-of-2 blob, one byte flipped | 2-of-2 | 130 | revert | `GS026` |
| Owner signs the Safe message hash | **1-of-1** | 65 | accept | `0x1626ba7e` |
| Owner signs the **raw zone digest** | **1-of-1** | 65 | revert | `GS026` |

`GS020` is Safe's "signatures data too short"; `GS026` its "invalid owner
provided".

**Read the last two rows together — they are the load-bearing pair.** Same Safe,
same owner, both 65 bytes; the *only* variable is which hash was signed. That
isolates the SafeMessage domain wrap as the cause and rules out signature
length. The 2-of-2 rows cannot do this on their own: at threshold 2 every
65-byte blob fails identically on the length precheck, so a below-threshold
signature and the API's signature shape are indistinguishable experiments there.
An earlier revision of this document claimed the threshold-2 EOA row proved the
1-of-1 case; it did not, and the 1-of-1 Safe was deployed specifically to close
that gap.

Note that a rejected contract signature surfaces as the Safe's own revert
string rather than the Zone's `"Bad oracle sig"`: `checkSignatures` reverts
internally instead of returning a non-magic value, so the Zone's comparison
branch is never reached. Anyone writing alerting against this path should match
on the Safe errors, not on `"Bad oracle sig"`.

## Test coverage

Two files, doing deliberately different jobs.

`test/FabricaMarketplaceZone.t.sol` — **source-level coverage, runs in ordinary
CI with no RPC.** Adds `SafeLikeErc1271Signer`, which models the two Safe
behaviours that decide whether a Safe can serve as `oracleSigner`: the
SafeMessage EIP-712 re-wrap and the length/ascending-owner check. The
pre-existing `MockERC1271Signer` is a lookup table — it proves the Zone *calls*
a contract signer, not that a real Safe would accept what we send. The new
tests pin the item-2 finding as an executable claim, including
`testSafeLikeSigner_RejectsEoaSignatureOverRawZoneDigest_EvenAtThresholdOne`,
which uses threshold 1 so the rejection cannot be attributed to length.

`test/FabricaMarketplaceZoneSepoliaErc1271Fork.t.sol` — **deployment
attestation, not regression coverage.** Every assertion targets already-deployed
immutable bytecode at a pinned block, so no edit to `src/FabricaMarketplaceZone.sol`
can ever make it fail. It attests that this deployment behaves as documented.
It uses `ForkTestBase._forkOrRequire`, so it skips when `SEPOLIA_RPC_URL` is
absent (CI stays green) but fails loudly when `ENG3687_REQUIRE_FORK` is set, so
a manual verification run cannot silently report a skipped proof.

One limitation worth stating: the fork test re-derives `ZoneParameters` rather
than replaying them byte-for-byte. The digest-relevant fields (`orderHash`,
`expiry`, `definitionUrl`, `disclosurePackageId`) are the live values;
`fulfiller`, `offerer`, `consideration`, `startTime` and `endTime` are zeroed
because `_verify` never reads them. A consequence: with an empty
`consideration`, the consideration-side branch of `_verifyDefinitionUrl` (the
buyer-bid path) is not exercised by this file.

## Where the Sepolia Zone address is consumed (the repoint surface)

| Surface | Finding |
| --- | --- |
| `fabrica-v3-contracts` | No config consumes it. Only `broadcast/` artifacts, which are historical records. |
| `fabrica-v3-api` | `networks.<net>.marketplace.fabricaZoneAddress` (+ `legacyZoneAddress`) in `config/{develop,staging,production}.json`; consumed by `marketplace.service.ts` (zone validation, current-vs-legacy discrimination, order construction) and `seaport-events-listener.service.ts` (event filtering). |
| `soil-app` | **No zone address of its own.** It carries a `zone` field through from the API order payload; nothing to repoint. |
| `fabrica-v3-subgraph` | No zone-address reference found. |

## Hand-off to item 2 (mainnet custody)

**1. A config-only zone repoint cannot work for any Safe — 1-of-1 included.**
`fabrica-v3-api` signs the fulfillment permission with a single EOA over the
**Zone's** EIP-712 digest (`marketplace.service.ts` L1468-1471 builds
`new Wallet(fulfillmentPermissionPrivateKey)`; L1506-1507 calls
`_signTypedData` with `domain.verifyingContract` = the zone). A Safe does not
accept that. Safe v1.4.1's `isValidSignature` re-wraps the incoming hash in the
Safe's **own** EIP-712 domain — `SafeMessage(bytes message)` over
`abi.encode(zoneDigest)` — and runs `checkSignatures` against that hash. The
API must fetch the Safe message hash and sign it with N owner keys concatenated
in ascending owner-address order. Verified on-chain by the 1-of-1 control pair
above. Item 2 must fund an `fabrica-v3-api` signing change (Safe message-hash
derivation, multi-owner signing, key management for N owners) before **any**
Safe custody works.

**2. A latent constraint in the extraData encoder, narrower than it looks.**
`MarketplaceService.permissionToExtraData` asserts `signatureBytes[64]` is `27`
or `28`. Byte 64 is the last byte of signature **#1** for a blob of any owner
count, so this neither rejects multi-owner blobs by count nor validates the
later owners — by inspection of the 2-of-2 blob, byte 64 is `0x1b` (27) and the
check passes. Because it only ever inspects the first slot, it rejects
`personal_sign`/`eth_sign` owners (Safe encodes `v` as 31/32) and Safe's
contract-signature (`v = 0`) and pre-approved-hash (`v = 1`) owner types **only
when such an owner happens to sort first**. Treat it as a position-dependent
constraint on reachable custody configurations, not a general rule.

**3. An immutable signer pointing at a mutable Safe is a new failure mode.**
`oracleSigner` cannot be repointed, but the Safe behind it is owner-governed.
If its owners ever remove the fallback handler or otherwise stop answering
ERC-1271, every order authorization reverts permanently and the only remedy is
a full Zone redeploy plus a repoint of every consumer. Symmetrically, the Zone
cannot observe the Safe's threshold: owners lowering 3-of-5 to 1-of-5 is
invisible on-chain to the Zone. Adopting a Safe therefore moves signer rotation
from "redeploy the Zone" to "a Safe transaction" — the real benefit — while
making order authorization depend on Safe owner governance.

**4. A Safe introduces a second authorization channel the EOA path did not
have.** The Zone's minimum `extraData` is 46 bytes, so the signature slice may
be empty; Safe's `isValidSignature` branches on `signature.length == 0` to
`require(safe.signedMessages(messageHash) != 0)`. Today that path is closed
(nothing is pre-approved — probing it live returns `Hash not approved`), but
under Safe custody a single `SignMessageLib` delegatecall would make an order
fulfillable with **no signature bytes at all**, as a persistent on-chain
approval that the Zone's 7-day freshness window does not bound in the same way.
Item 2 should decide about this deliberately rather than inherit it.

**5. Custody hardening does not shorten the bearer window.** The signed digest
binds only `orderHash | expiry | definitionUrl | disclosurePackageId`, and
`authorizeOrder` is a permissionless `external view`. An observed `extraData`
blob is therefore a bearer authorization for that order until expiry — up to
`MAX_AGE` 7 days, with the API currently issuing 5 days
(`fulfillmentPermissionDurationSeconds`, carrying a `TODO` at
`marketplace.service.ts:1460` to reduce it to two blocks). Moving the signer
from an EOA to a Safe hardens key custody and does nothing about this.

**6. Cost.** The ERC-1271 branch adds a staticcall into the Safe on **both**
`authorizeOrder` and `validateOrder` (`_verify` runs twice per fill). The
observed fill cost 233561 gas total on Sepolia; item 2 should price the
per-fill delta on mainnet against the EOA path.

None of these changes are implemented here — items 1, 2, 4 and 5 are
`fabrica-v3-api` money-path signing code and out of scope for this lane.

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

## Shared-chain footprint

Per the project's shared-chains rule, Sepolia state is shared by every release
stage that indexes Sepolia. This lane's fixture mint on the canonical Sepolia
`FabricaToken` (`0xb52ED2Dc…`, id `298855539945321607`) and the resulting
fulfilled order are therefore visible to develop, staging and production alike
— for example in subgraph queries or marketplace listings that do not filter by
zone. The fixture is identifiable as test data by its synthetic `definitionUrl`
and `disclosurePackageId`. No environment's *configuration* was changed, so no
environment routes orders through the new Zone; the visible artifact is one
test-labelled property and one completed order.

## What was deliberately not done

No deployed environment was repointed. Changing
`networks.sepolia.marketplace.fabricaZoneAddress` in `config/staging.json`
would make shared staging's order flow depend on this lane's disposable 2-of-2
test keys, and — per hand-off finding 1 — could only ever exercise a degenerate
case anyway, since the API cannot produce a Safe-valid signature at all. The
e2e was therefore run directly against Sepolia.

This substitution was escalated before any code was written and authorized by
`brioche` (this lane's parent agent) over signed Wire IPC on 2026-08-14, which
also directed that the API signing change be surfaced as its own decision
rather than implemented here. The staging and production repoints belong to the
item-2 cutover.
