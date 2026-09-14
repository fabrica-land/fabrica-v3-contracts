# ENG-4203 — the round-3 batched fact store

[ENG-4203](https://linear.app/fabrica/issue/ENG-4203). Sepolia only; mainnet is out of scope and
was never touched. Contract: `src/FabricaFactStore.sol` as merged in
[fabrica-v3-contracts#52](https://github.com/fabrica-land/fabrica-v3-contracts/pull/52)
(`ec09c2f7a099aa4a20f32c4a3c2047e5d87b364f`). Deploy script:
`script/FabricaFactStoreDeploy.s.sol`, unchanged.

**This deploy adds one capability and changes nothing else.** The round-3 store is the round-2
store plus `writeFacts(address,FactInput[])` and its `MAX_BATCH` cap. `historyDepth` is the same
48, `KIND_PRICE` is byte-identical, and the event surface is unchanged.

## Why a redeploy, and why the aggregator and pool follow

`FabricaFactStore` is not upgradeable — no proxy, no owner, no setter. A new entry point is a new
deployment. The round-2 store
[`0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd`](https://sepolia.etherscan.io/address/0xa81f30b0ec22dbe4b25239883850367edb6f3edd)
([ENG-3924](https://linear.app/fabrica/issue/ENG-3924)) stays deployed and untouched, and both
round-2-backed aggregators still read it.

**It is not, however, serving a price.** That feed has been fail-closed since the staging keeper
cron was disabled under [ENG-4202](https://linear.app/fabrica/issue/ENG-4202): all three writers'
last cycle closes are now older than the 3-day `maxSilence`, and `price()` on both the ENG-3925 and
ENG-3926 aggregators reverts `CheckFailed(keccak256("max_silence"))` — measured, not inferred. No
round-2-backed pool is quoting. That is fail-closed by design following a deliberate operator
decision, and it predates this deployment; nothing in this record caused it. The distinction
matters because "the store is untouched" is true of the contract and false of the feed.

The aggregator holds its store address in an `immutable` slot and the pool reads the aggregator, so
adopting this store means a new aggregator and a new pool — the round-3 stack. Tim released that
hold on 2026-09-14 ("Round-3 stack redeploy: go ahead."). **The aggregator and pool are NOT part of
this record**; they are blocked on the script re-point below and land separately.

## Deployed address

<!-- DEPLOYMENT:sepolia -->

| Contract | Network | Address |
| -- | -- | -- |
| `FabricaFactStore` (round 3) | Sepolia | [`0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D`](https://sepolia.etherscan.io/address/0x97fc2c3a41d4db570363c5e3425c3676e4b81c5d) |

<!-- /DEPLOYMENT:sepolia -->

Deployed 2026-09-14 in transaction
[`0xaa874734…cad7`](https://sepolia.etherscan.io/tx/0xaa87473424dc72f92f076f6a87d48a88313b298fbcc10e69ae07043da519cad7),
status `0x1`, gas used 1,437,018, block 11,704,139, effective gas price 1,334,417,726 wei.
Etherscan-verified in the same run (`Pass - Verified`, solc 0.8.35, optimizer on, `runs = 1`,
`evmVersion` osaka).

## Constructor parameters

One argument. It was not copied from the ENG-3924 record — it was read back off the live round-2
store before the deploy.

<!-- markdownlint-disable MD013 -->

| Parameter | Value | Source |
| -- | -- | -- |
| `historyDepth_` | 48 | `cast call 0xa81f30b0… "historyDepth()(uint8)"` returned 48 on the live store |

<!-- markdownlint-enable MD013 -->

Encoded constructor argument in the verified submission:
`0x0000000000000000000000000000000000000000000000000000000000000030` = 48.

**`FACT_STORE_HISTORY_DEPTH` was set explicitly rather than left to the script default.** Omitting
an override does not prove an inherited environment is absent, and the script's `vm.envOr` would
silently accept one. The variable was confirmed unset in the shell, confirmed absent from `.env`
(grep count 0), and then exported as `48` for both the confirming simulation and the broadcast, so
the effective value is asserted rather than assumed.

## What is NOT changed

Verified by `cast call` after the deploy:

<!-- markdownlint-disable MD013 -->

| Deployment | Sepolia address | State after this deploy |
| -- | -- | -- |
| Round-2 fact store | `0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd` | runtime still 6,036 bytes, unchanged |
| Round-1 pool | `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` | `priceOracle()` = `0x522C7F01…` (unchanged) |
| ENG-3925 pool | `0xdE70d398Be943BB1CCd77a5c081e38046Ca17764` | `priceOracle()` = `0xbDD420cB…` (unchanged) |
| ENG-3926 pool | `0x42C26Fd01B0D8217eDD5009078D6A53c6eE023E5` | `priceOracle()` = `0x1b17C9b2…` (unchanged) |

<!-- markdownlint-enable MD013 -->

No aggregator or pool transaction was broadcast.

## Acceptance criteria not satisfied by this record

Stated here rather than left to be noticed. Both are gaps; neither is waived by this document.

- **Item 3 — the receipt-validated gas table at batch sizes 1, 10, 50 and 100 is NOT delivered.**
  What this record contains is a 12-fact demonstration in two regimes, which is a smaller and
  differently shaped measurement. It is not a substitute and is not offered as one. The table is
  satisfiable and remains outstanding work on this ticket.
- **Provenance is scoped to a non-canonical build shape.** The compared artifact came from
  `forge build --skip test`, not from `forge clean && forge build`. Re-measuring under the canonical
  build is outstanding; see *Bytecode provenance*.
- **Item 4d — `DEPLOYMENT.md` was not updated.** The AC appears unsatisfiable as written: that
  document holds no address registry, and its own "Post-deploy: capture the address" section routes
  addresses to `UPGRADE-RUNBOOK.md`, a new per-family doc, the `broadcast/` artifacts and the
  downstream consumers — which is where this deployment's address has gone. Two of the three prior
  round-2 redeploys also did not touch it. Unsatisfiable is a reason to say so, not a licence to
  omit silently.

## There is no writer registration, on this store or any other

ENG-4203 item 4 asks for writers to be "re-registered/authorized exactly as on `0xa81f30b0`". **That
is a no-op, and the ticket's premise does not hold.** This is a correction to the AC's premise, not
a judgement that the AC was unimportant, and it is surfaced in the PR description and as a comment
on ENG-4203 rather than only at line 100 of a long artifact — a gap stated where nobody reads it has
been stated to nobody. It is not treated as satisfied until the operator acknowledges it. `FabricaFactStore` is ownerless by
construction: no owner, no writer allowlist, no recovery writer, no lock authority, no gate. Its
only access check is `src/FabricaFactStore.sol:339`:

```solidity
if (writer != msg.sender) revert NotWriter(writer, msg.sender);
```

A row is addressed by the writer's own address, so authorization is self-evident and **post-deploy
writer setup on this store is zero transactions.** The trusted-writer mapping lives entirely in the
aggregator's `immutable` `writers[]` constructor argument, which is exactly why a new store forces
a new aggregator.

Confirmed on the new store, **for the queried key only**: `isFactLive(writer, 4203001, KIND_PRICE)`
returns false for each of `0xfA2c254f…`, `0x70ED67c1…` and `0x24E52f31…`. That is a single
(tokenId, kind) probe per source and it does not prove their namespaces are empty — no finite sample
could. The load-bearing facts are stronger than the probe anyway: this contract was deployed in this
transaction, and an exhaustive log sweep — `eth_getLogs` over the store from its deploy block to
latest — returns **24 events, all `FactWritten`, across exactly 2 transactions, from a single writer
topic `0xDD2dB187…`**. That sweep is exhaustive in a way a nonce is not: every mutating function in
this contract emits an event, so no write can escape it, whereas a nonce bounds only one EOA's own
outgoing transactions and this store is permissionless — any address may write under its own row,
and an internal call from a contract consumes no nonce at all. No oracle-source key was created or
used at any point in this deploy.

**Those twelve rows are permanent.** The writer key was destroyed after the sweep, and the store is
ownerless with no delete: `setLock`, `setMinValidCycle` and any superseding write all route through
`_requireWriter`, so nobody — including Fabrica — can ever lock, revoke or supersede them. They are
not a pricing hazard, because `0xDD2dB187…` is in no aggregator's immutable `writers[]`. They are an
**indexing** hazard: a consumer that indexes `FactWritten` by store address without filtering on a
trusted writer will surface twelve fabricated valuations permanently. Applying a trusted-writer
filter is therefore a requirement on
[ENG-4205](https://linear.app/fabrica/issue/ENG-4205) and on any keeper or API consumer, recorded
there rather than only here. The token ids used (4203001–4203012) do not collide with any id in use
and sit roughly 4.2 million ahead of the current Sepolia sequence; they share the same `uint256`
space, so that is a statement about distance, not an impossibility.

## Verification: one real `writeFacts` transaction

Both batches were written under the **disposable deployer's own writer row**
(`writer == msg.sender == 0xDD2dB187…`), token ids 4203001–4203012, `kind = KIND_PRICE`. An
isolated namespace, so no row any real source will use was touched.

<!-- markdownlint-disable MD013 -->

| Batch | Regime | Tx | Facts | `gasUsed` | Gas/fact | Logs |
| -- | -- | -- | -- | -- | -- | -- |
| 1 | first writes | [`0xa093882b…959f`](https://sepolia.etherscan.io/tx/0xa093882b665757e507c5b98680423fb7b3e67889f10a3108d134b386f7a8959f) | 12 | 672,392 | 672,392 / 12 = 56,032.6667 | 12 |
| 2 | steady state | [`0xd734bc31…e12a`](https://sepolia.etherscan.io/tx/0xd734bc31d63369262a747f40a07ef4c9576fa125d0af55eb4c10399aaef3e12a) | 12 | 824,384 | 824,384 / 12 = 68,698.6667 | 12 |

<!-- markdownlint-enable MD013 -->

`gasUsed` is the integer from the transaction receipt. The per-fact column is that integer divided
by 12, carried to four decimal places rather than rounded, so the quotient cannot be mistaken for a
measured per-fact figure — nothing on chain meters a single fact inside a batch.

### The first-write number is not the comparable one

Batch 1's 56,032.6667 gas/fact is real but **must not be compared against the 98,668 single-write
baseline.** On a fresh store every row has `writtenAt == 0`, so `_writeFact`'s
`if (writtenAt != 0)` block is skipped entirely: no history-ring write and no `_enforcePolicy`.
Batch 2 rewrites the same twelve rows at cycle 2 and therefore pays the history-ring write, which
is what a keeper cycle actually costs.

Set against the historical 98,668 single-write baseline, 68,698.6667 is roughly a 30% reduction.
**Treat that as illustrative, not as a controlled reproduction of the keeper's gas.** The two
numbers were not produced under a matched regime: this writer has no declared policy (so
`_enforcePolicy` short-circuits where a real source's would not), the payload is synthetic and
uniform, every row here had exactly one prior version rather than a seasoned ring, and gas price and
chain conditions differ from the ENG-3924 measurement. A batch size alone does not make two runs
comparable.

PR #52's bench reported 74,763 gas/fact whole-transaction at n = 100. That figure was **not**
re-measured on chain here and this record does not claim to reproduce it. It is also not comparable
to the steady-state row above: `_measureWriteFacts` in `test/Eng4203FactStoreBatchGas.t.sol`
constructs a fresh `FabricaFactStore` on every call, so every row it measures has `writtenAt == 0`
and the 74,763 figure is a **first-write** number. Comparing it against a steady-state receipt is
the exact error this section spends the preceding paragraphs ruling out.

This record therefore draws **no conclusion about how per-fact cost varies with batch size.** It has
not measured the same regime at two batch sizes, so it is not entitled to one.

What this transaction does establish, without qualification: `writeFacts` works on chain at a real
batch size, all-or-nothing, one event per fact, with the history ring behaving as designed.

### Read-backs

All twelve rows return the batch-2 values through
`getLiveFact(address,uint256,bytes32)((uint128,uint24,uint64,uint64,uint64,bytes32),bool)`:
values 1,050,000 … 12,050,000, confidence 8101 … 8112, `cycle` 2, `live` true, and `isFactLive`
true. `historyLength` is 1 on every row, and `getHistory(…, 0)` on 4203001 returns
`(1000000, 1789404480, 1)` — the superseded batch-1 value at cycle 1, so the ring retained it.

**Use the tuple signature.** A flattened return signature decodes `(Fact, bool)` into the wrong
field boundaries and yields a spurious `live = false`; that was a decode error during this
verification, not chain state, and it is recorded here so the next reader does not chase it.

### One event per fact

`writeFacts` loops `_writeFact`, which emits one `FactWritten`; there is no batch-level event. Both
receipts carry exactly 12 logs. The signature and `topic0` are unchanged from the round-2 store:

```text
FactWritten(address,uint256,bytes32,uint128,uint24,uint64,uint64,bytes32)
topic0 0x3e2fc348577610decc713fae096858bfe5d83e8a18baf79e9011a07182c69d9c
```

Measured both from this build's ABI and from a live log on `0xa81f30b0…`; byte-identical. The
subgraph ([ENG-4205](https://linear.app/fabrica/issue/ENG-4205)) therefore needs a new data source
address, not new handler code.

## Bytecode provenance

**Method, stated exactly — and stated with its limits, which are real.** The local artifact was
produced in this worktree at commit `ec09c2f` with:

```sh
forge build --skip test
```

**That is not the repo's canonical build, and this record therefore does NOT assert third-party
reproducibility.** The canonical re-measure is `forge clean && forge build --sizes` with no `--skip`
of any path. The distinction is not pedantic: per the ENG-3231 postmortem, via-IR codegen for the
whole compilation graph can shift under `--skip`, and a `--skip` build was once measured 102 bytes
denser than canonical, falsifying a headline size claim. Whether `--skip` perturbs *this* contract
is an empirical question that has not been answered here — answering it needs a clean full build,
which was not available when this record was written.

So the honest statement is bounded: under the build shape named above, the comparison below yields
zero differing offsets outside the declared immutable spans. A reader who rebuilds cleanly may see
executable-region differences arising from the build shape rather than from the deployment, and
should treat that as inconclusive, not as evidence of tampering. **Re-measuring under
`forge clean && forge build` and confirming the same result is outstanding work on this ticket**;
until it is done, treat the provenance claim as scoped to this build shape.

The toolchain is likewise not fixed by the repo: `foundry.toml` sets `auto_detect_solc = true` and
pins no `evm_version`. The build that produced the compared artifact reports **solc 0.8.35,
optimizer on, `runs = 1`, `evmVersion` osaka** in its own metadata — the same settings Etherscan
verified against — so reproduce with those settings or, again, treat a mismatch as inconclusive.
(Pinning `solc_version` and `evm_version` would remove that half of the caveat; it is repo-wide
hardening, out of scope for this ticket.)

The local side is `out/FabricaFactStore.sol/FabricaFactStore.json` → `deployedBytecode.object`,
hex-decoded. The chain side is `eth_getCode` on the deployed address, hex-decoded. The two byte
strings are compared index by index over their whole length. Offsets are then partitioned using the
spans the compiler itself declares in the artifact's `deployedBytecode.immutableReferences` — taken
from the compiler output, never inferred from the diff, so the masking cannot be fitted to the
answer.

**Two different byte counts are in play and this record previously conflated them.** Following the
convention the sibling records use (ENG-3926: 7,148 − 53 = 7,095), the **executable region is the
runtime minus the trailing CBOR metadata**: the last two bytes read `0x0033` = 51, so the trailer is
53 bytes at offsets 6,340–6,392 and the executable region is **6,340 bytes**. Separately, and
disjointly, 128 bytes of declared immutable spans are masked. An earlier draft of this record
reported the region as 6,265 bytes (6,393 − 128), which is the immutable-masked count, not the
house-rule region — the two maskings do not overlap, so the zero-difference result is unchanged
either way, but the label was wrong.

<!-- markdownlint-disable MD013 -->

| Measure | Value |
| -- | -- |
| Local rebuild runtime | 6,393 bytes |
| On-chain runtime | 6,393 bytes |
| Immutable spans, from `immutableReferences` | 4 spans, one slot (id `64740`), 32 bytes each, 128 bytes total |
| Total differing offsets | 4 |
| Differing offsets inside declared immutable spans | 4 |
| Trailing CBOR metadata | 53 bytes, offsets 6,340–6,392 (build-environment dependent) |
| **Differing offsets across the 6,340-byte executable region** | **0** |
| **Differing offsets anywhere outside the 128 masked immutable bytes** | **0** |

<!-- markdownlint-enable MD013 -->

The four differing offsets are not merely inside the spans — each one differs **to the correct
value**. The compiled artifact carries a zero placeholder in every immutable span; the deployed code
carries the constructor argument:

<!-- markdownlint-disable MD013 -->

| Span start | Length | Artifact word | On-chain word |
| -- | -- | -- | -- |
| 1144 | 32 | 0 | 48 |
| 2469 | 32 | 0 | 48 |
| 2754 | 32 | 0 | 48 |
| 3960 | 32 | 0 | 48 |

<!-- markdownlint-enable MD013 -->

All four carry 48, which is `historyDepth` — the sole immutable and the sole constructor argument.
So the deployed code is this source compiled with `historyDepth_ = 48`, and the four differences are
fully explained rather than merely tolerated.

The size agreement is a consistency check, not proof: two different contracts can share a byte
count. What establishes provenance is the executable-region byte identity with the immutable spans
masked, plus the four masked words each resolving to the expected constructor value.

The trailing CBOR metadata holds an IPFS hash digesting the compiler's *input* JSON and is
build-environment dependent. It matched here because this rebuild ran on the machine that produced
the deploy. A rebuild elsewhere may differ in that region without indicating tampering; reproduce
the executable-region result, not the whole-runtime one.

## How this was deployed

Per `DEPLOYMENT.md` § "`TESTNET_DEPLOYER_PRIVATE_KEY` is fenced". That key is the ENG-3895
cycle-close runner EOA and **was not used**.

A **disposable keystore generated in-process**: the keypair was created inside a short script that
wrote the encrypted V3 JSON keystore and a random password file (both `0600`, in a `0700` directory
outside the repo) and printed only the address. The key never reached argv, the environment, a log
or command output. Before any funds moved, the keystore was decrypted back and checked to derive
the expected address — a mismatch there would have stranded the funding.

<!-- markdownlint-disable MD013 -->

| Step | Value |
| -- | -- |
| Disposable deployer | `0xDD2dB187d3d4EBBedCBbbaa9e1F5BafF91FB8a79` (balance 0, nonce 0, no code beforehand) |
| Funding | 0.05 SepoliaETH from the shared pool `0x152e6102…`, tx [`0x0e0885af…dadd`](https://sepolia.etherscan.io/tx/0x0e0885af156a5864f1289cdb6e25dc410404b843383c6bfd47c15a520f35dadd), status 1, block 11,704,135 |
| Sweep back | 0.045703981948278724 ETH, tx [`0x4c752335…5ec8`](https://sepolia.etherscan.io/tx/0x4c75233526ab74d3fa27b3f135d4d2ff32818076f6ebb33332c57e98e6475ec8), status 1, block 11,704,157 |
| Final nonce | 4 |

<!-- markdownlint-enable MD013 -->

**0.000056605416462 ETH is stranded** at `0xDD2dB187…` permanently; the key was destroyed after the
sweep. The sweep reserved three times the quoted gas price as headroom so it could not itself fail
for under-pricing, and the unspent headroom is the stranding. That is **below** ENG-3926's
0.0000815 ETH on the same path (5.66e-5 against 8.15e-5). Recorded rather than rounded away — it is
the standing cost of the disposable-keystore path.

Sweep happened **before** shredding. The keystore, its password file and all five Foundry
sensitive-values files under `cache/FabricaFactStoreDeploy.s.sol/` were then random-overwritten and
unlinked. **The `broadcast/` records were deliberately preserved** — they are the non-sensitive
historical record and are committed with this change.

## Before the broadcast

The deploy was simulated twice without `--broadcast`: once to produce the manifest, then again with
`--sender` set to the real disposable deployer. That second simulation predicted
`0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D`, `cast compute-address --nonce 0` independently
derived the same address, and the broadcast landed on it. Agreement from two independent
derivations before signing; a mismatch was the stop condition.

The batch itself was pre-simulated with `eth_call` before broadcasting — the zero-gas check
`writeFacts`'s own NatSpec points the keeper at.

## The aggregator deploy script had to be re-pointed

`script/FabricaImmutableAggregatorDeploy.s.sol` pins the canonical fact store as a compile-time
constant and reverts `NonCanonicalFactStore` for anything else, with **no environment override**.
PR #52 did not touch it. Pointed at this new store it fails, measured before the deploy:

```text
Error: script failed: NonCanonicalFactStore(0x97fC2C3A…, 0xa81f30b0…)
```

**The guard is correct and was preserved, not removed.** It exists because this store has now been
redeployed twice and every superseded address still circulates in briefs. The aggregator's
constructor cannot separate any two of these stores: `KIND_PRICE` is a compile-time constant, so it
is byte-identical across every generation — that is a universal property of the design, not a
peculiarity of the round-2 store. The constant was re-pointed to the round-3 address and its
rationale rewritten to cover both superseded stores.

**The pin alone was not enough, and the board was right about that.** An address pin enforces a hex
literal, which is only ever as good as the review that last read it; nothing in the repository could
tell a correct pin from an incorrect one, and the binding it produces is an `immutable` — permanent
and unfixable. The guard now also *proves the property the literal stands for*, with a `MAX_BATCH()`
staticcall that must succeed. The two checks are complementary and neither subsumes the other: a pin
cannot separate two round-3-shaped stores, and a property check cannot separate round 3 from a
future round 4.

The discriminator is verified by execution, not by scanning bytecode for a selector — a four-byte
string in runtime code is a heuristic, not proof of dispatcher capability:

| Probe (`eth_call`) | Round-3 `0x97fC2C3A…` | Round-2 `0xa81f30b0…` | Dead `0x89895c2f…` |
| -- | -- | -- | -- |
| `writeFacts(…, [])` | reverts `0xc2e5347d` = `EmptyBatch()` | reverts, no return data | reverts, no return data |
| `MAX_BATCH()` | returns 256 | reverts, no return data | reverts, no return data |

A custom-error selector coming back from the round-3 store is positive proof the function is
reachable and ran its own guard; the empty-data reverts are consistent independent negatives.

Two tests cover the two grounds separately, because one fixture cannot model both:
`test_refusesTheRound2FactStoreSupersededByRound3` exercises address inequality only — its fixture
etches round-3 runtime, so it cannot demonstrate the generation hazard and now says so —
while `test_refusesAStoreThatCannotAnswerMaxBatch` uses a fixture that genuinely cannot answer.
`Eng4203Round3FactStorePinSepoliaForkTest` then asserts the pin against the real chain, with its own
CI step supplying `SEPOLIA_RPC_URL`; without that step a fork suite silently skips and proves
nothing.

`test/Eng3925ImmutableAggregatorSepoliaFork.t.sol` was left entirely unchanged: its
`SHIPPED_FACT_STORE` asserts about the shipped `0xbDD420cB…` aggregator, which genuinely does still
read the round-2 store.

## Downstream

The address above is what [ENG-4204](https://linear.app/fabrica/issue/ENG-4204) (keeper) and
[ENG-4205](https://linear.app/fabrica/issue/ENG-4205) (subgraph) consume. `MAX_BATCH` is 256 and is
a public constant, so the keeper can read it on chain rather than hardcode it. **Neither ticket is
satisfied by this deployment** — it gives them an address, not completion.
