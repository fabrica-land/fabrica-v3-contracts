# ENG-3922 — as-shipped Sepolia evidence

Real transactions, real EAS v0.26, real reads. Every number below has a Sepolia transaction hash
behind it. No round-1 contract was modified or redeployed. Writers are lane-local throwaway EOAs,
deliberately not the shared deployer `0xBF03076547a99857b796717faF4034dea94569dF`, so nothing here
contended for a nonce with the ENG-3895 cycle-close cron.

## Deployed for the experiment

| What | Address |
| -- | -- |
| `FactPointer` (arm 2, ownerless) | `0x97E6EE56aBe0Dd30d5e55327ad99F0070C10590a` |
| `OwnerlessFactStore` (arm 3) | `0x012110C641eE4C445766DfBE5Dd512115A0166f0` |
| `PriceGasProbe` | `0x77009055B7FD99b3B121C589fCe18f56bC2CB604` |
| `ArmEasPointer` | `0xE4212375D42bB87878D56Bd4d98bD0E464799e05` |
| `ArmEasIndexer` | `0x8c410070620d5A96377B3BED7E4BFf3898CFe89F` |
| `ArmEasContext` (Option C) | `0x66d728fd5638A1961ceDF3224625a0DD8d1d5B97` |
| `ArmOwnerlessStore` | `0x13505AbA5c0c7d78Fa1Bbc5ef0D05Bff39addA5C` |

EAS schemas registered on the Sepolia `SchemaRegistry` (`resolver = address(0)`, `revocable = true`):

| Schema | uid |
| -- | -- |
| price `(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6, uint24 confidence, uint64 cycle, bytes32 inputsHash)` | `0xa7dac77e6aebee43580b6591121858b006d7df052186ef5b1a59616a95920de1` |
| cycle close `(address writer, uint64 cycle, bytes32 root)` | `0x1d9dc9a79ee5a4a6af1628955732581659e70bedded150f3598d4c85e1399546` |
| coverage `(uint256 tokenId, uint64 cycle)` | `0xbe99a036dea734761bae3021a4a68f3efee8715bf3b2502daec77d2c1f9e66a5` |

Oracle-source writers: `0x889A1330555C52062d275365C5cc65b723856F9c`,
`0xB772e5a59616c047081f3C4E44c9C530b2f02cE4`, `0x366F9e43BC0d26152aDa8112EaDB087051bcD7aF`.

## The read — `price()` for a three-source read, from a real transaction

`price()` is a view, so an `eth_call` costs nothing observable. `PriceGasProbe` performs the read
inside a transaction and emits what it consumed, so these are receipts, not estimates. One token,
quantity 1, walk depth 0, round-2 configuration (no on-chain coverage check).

| Arm | `price()` gas | Price returned | Transaction |
| -- | -- | -- | -- |
| arm 3 — ownerless custom store | **148,230** | 100500000000 | `0x2c58ed48266bc93d372dc47d345df477f89da9dc9c471e948bdba609d634d445` |
| arm 1C — all-EAS via `oracleContext` | **315,566** | 100500000000 | `0x761f628b8ce54e896e6bebaa4260ba381de6476e7ffe8ca70883d0ef1ebd69b5` |
| arm 2 — EAS plus pointer | **355,594** | 100500000000 | `0xefbb395701e7c1b0570a2c2b9f75ab919d758f9e3011e5fe2ac7acefe6243e86` |
| arm 1 — all-EAS via EAS `Indexer` | **408,043** | 100500000000 | `0x524d41995656286f69b9bc49bc4279823517582bb853a5d1aab22e98272872bc` |

All four arms return the same usable price, which is the point: the arms differ only in where the
facts live.

**Sepolia against the fork, same code, two independent methods:**

| Arm | Fork | Sepolia | Difference |
| -- | -- | -- | -- |
| arm 3 ownerless store | 149,337 | 148,230 | −0.7% |
| arm 1C `oracleContext` | 315,283 | 315,566 | +0.1% |
| arm 2 EAS plus pointer | 354,841 | 355,594 | +0.2% |
| arm 1 all-EAS Indexer | 407,305 | 408,043 | +0.2% |

## The write — one real cycle, 20 tokens x 3 oracle sources

Whole-transaction `gasUsed` from receipts.

| Operation | Total | Per token | Transaction (writer 1 of 3) |
| -- | -- | -- | -- |
| EAS `multiAttest`, 20 prices | 5,609,525 | 280,476 | `0xc5d650d6cf7aaba640c665c297ced23c1f3e5d36c3a44f3d7173267b73e432b3` |
| EAS `indexAttestations`, 20 | 3,522,144 | 176,107 | `0x5e6ef87089a03c9bced760b243379f7df698ebfd2b82bb3c2ec472c413506bdc` |
| pointer `pointBatch`, 20 | 552,213 | 27,611 | `0x11306bcac035eadc49ca3a6c863076d3846c9640d4199e950f75e521b3045dff` |
| ownerless store `writePriceBatch`, 20 | 1,498,384 | 74,919 | `0x0cd3fe6fc5f72047be69215194f2f47bb036bd3cb6e83a0973572e3dac97d8d5` |
| EAS cycle-close `attest` | 230,461 | — | `0xf15219bce7309c5a5f40dab268d1690791ceed6b37a3ab9bea771d193a029898` |
| pointer `point` (cycle close) | 46,988 | — | `0xe28129d8ebcef8bcd8f03bffdb7fcd3dc63a0fb7b5b34a0bd2ee55abf071da1f` |
| EAS `indexAttestation` (cycle close) | 234,039 | — | `0xd5df6ce92bb6ca7cd9f84d9c692eca6b59819d1ad13ba38161da22a3e180260e` |
| ownerless store `heartbeat` (cycle close) | 33,289 | — | `0xa890fd32357237465b55bc67f7b09b798be75dd78eaf3117b003b03d83368a44` |

**Per fact, and per weekly cycle at 1,000 tokens (3,000 facts):**

| Arm | Per fact | Weekly cycle |
| -- | -- | -- |
| arm 3 — ownerless custom store | 74,919 | **225M** |
| arm 2 — EAS plus pointer (`attest` + `point`) | 308,087 | **924M** |
| arm 1 — all-EAS (`attest` + `indexAttestation`) | 456,583 | **1,370M** |

## The lock, end to end

Token `0xf1de9251b4dd69eadbda0acc7b63e058ea5fe3b4d8378016e4a2442cf7684777`.

After ONE writer locks — EAS revocation `0xcae0db21a30d2f0cbef186394068a2b096a3db779483d0aa13f9796482e2be24`,
store `setLock` `0xa679588995618b4698c1baa5d39901ff49f23863477595fbcc7a399dfe33adff`:

```text
ArmOwnerlessStore -> true 0x0000...0000 100500000000 0
ArmEasPointer     -> true 0x0000...0000 100500000000 0
ArmEasIndexer     -> true 0x0000...0000 100500000000 0
```

Still priced. **With three oracle sources and `minLiveSources` 2, one lock drops the live count to
the floor, not below it.** The ticket's bullet 3 expects one lock to trip `CHECK_MIN_SOURCES`; that
holds only when two sources were live to begin with.

After a SECOND writer locks — `0x7f984be342d8fc8b3923dd55d88c50870b1661db9dfda2d19d968c0abc31ff51`
and `0x31c34b1645e6cef0e7c13097daefd4439ea73ab9ab6dfde83d0bba36fecbb4db`:

```text
ArmOwnerlessStore -> false 0x4a2b6d9997de3b0ab1f2bae95dc15d063d26988a0c51617a58e74911251792fc 0 0
ArmEasPointer     -> false 0x4a2b6d9997de3b0ab1f2bae95dc15d063d26988a0c51617a58e74911251792fc 0 0
ArmEasIndexer     -> false 0x4a2b6d9997de3b0ab1f2bae95dc15d063d26988a0c51617a58e74911251792fc 0 0
```

`0x4a2b6d99…` is `CHECK_MIN_SOURCES`, confirmed by reading the constant off the deployed arm. And
`price()` itself reverts, captured through the probe in
`0x30571a1639fdfc439c56aeae84ac6eeb091578da66b5a9ebc98c561967ecdb20`, whose `PriceReverted` event
carries reason `0x4c73a6a1…` = `CheckFailed(bytes32)`, gas 67,353.

Revocation costs 80,192 gas on EAS; the store's `setLock` costs 46,141.

## The keying gap is closed

Writer 2 attempted to write the same `(tokenId, kind)` row and moved only its own
(`0x2d4c29c949be4141a1b2a8c05d3cc2d23507bc3836bef70ed5d1545c232b6acb`):

```text
writer0 row before: 0x429d4dbcc5f2db05e7afce482274edb88929f34e1c05c8d3ad9e9a7cde49e32f
writer0 row after:  0x429d4dbcc5f2db05e7afce482274edb88929f34e1c05c8d3ad9e9a7cde49e32f
writer1 row after:  0x1111111111111111111111111111111111111111111111111111111111111111
```

## Two facts about EAS's `Indexer` that the numbers depend on

1. **Indexing is not automatic.** `indexAttestation` is a separate write per attestation, measured
   at 176,107 gas per token in a 20-item batch. The all-EAS arm's per-fact write cost is `attest`
   PLUS that, which is what makes it the most expensive arm on both sides.
2. **It is not deployed on Ethereum mainnet.** The EAS repo has no `Indexer.json` under
   `deployments/mainnet/`. Whatever arm 1 measures on Sepolia cannot ship to mainnet as it stands.

## One structural cost of Option A that is not a gas number

An EAS uid is `keccak256(schema, recipient, attester, time, expirationTime, revocable, refUID,
data, bump)` — it depends on the block timestamp of the transaction that creates it. Nothing can
compute the uid it is about to create, so no publisher can attest and point at the result in one
transaction. The oracle writer must attest, read the uids back from the receipt, and point in a
second transaction. That is why the publication here runs in two phases, and it is a property of
the design rather than of this harness.
