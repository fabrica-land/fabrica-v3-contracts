# Deploying contracts from this repo

This repo holds Fabrica's own Solidity contracts (FabricaToken, FabricaFeeCollector,
FabricaValidator, FabricaMarketplaceZone, FabricaProxy, and friends) and their
deployment scripts. The MetaStreet-derived lending-pool contracts live in the
[`fabrica-land/metastreet-contracts-v2`](https://github.com/fabrica-land/metastreet-contracts-v2)
fork, not here. We deploy via **Foundry's `forge script`** (Paradigm tooling), one
script per logical operation, against the network's `--rpc-url`.

For UUPS-proxy upgrades to existing FabricaToken / FabricaValidator
deployments, see [`UPGRADE-RUNBOOK.md`](./UPGRADE-RUNBOOK.md) instead — this
doc covers deploying new contracts. The Fabrica lending pool stack now lives in
the [`fabrica-land/metastreet-contracts-v2`](https://github.com/fabrica-land/metastreet-contracts-v2)
fork, with its own Foundry deploy scripts and upgrade runbook.

## TL;DR (for anyone vendoring something new)

```bash
# 1. From repo root, with .env populated (see "Environment setup" below):
forge build

# 2. Run the deploy script against the target network. Network names are
#    declared in foundry.toml's [rpc_endpoints] section.
forge script \
  --rpc-url sepolia \
  script/MyNewContractDeploy.s.sol \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify

# 3. Record the deployed address in UPGRADE-RUNBOOK.md (or a new doc if
#    this is a new contract family) — every consumer (soil-app,
#    fabrica-v3-api) needs the address to reference the contract.
```

## Environment setup

`.env` lives at the repo root, gitignored, sourced by `foundry.toml`. It
must contain at least:

```bash
# RPC endpoints — one per network you intend to deploy to
MAINNET_RPC_URL=https://mainnet.infura.io/v3/<...>
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/<...>
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org

# Etherscan / Basescan API key for contract verification
ETHERSCAN_API_KEY=<...>

# Deployer private key. ONLY for dev/sepolia. Mainnet deploys use Safe
# multisig + a hardware-wallet-signed transaction; never put a mainnet
# deployer key in a .env file.
DEPLOYER_PRIVATE_KEY=<dev-or-sepolia-key>
```

`foundry.toml`'s `[rpc_endpoints]` block declares the network names that
`--rpc-url <name>` resolves to. Currently: `mainnet`, `sepolia`,
`base-sepolia`. Add a new entry when introducing a new network.

## Script conventions

Scripts live in `script/` and are split **one per logical operation**, so
each can be run with a different private key (per the role-separation
pattern documented in [`CLAUDE.md`](./CLAUDE.md)):

| Script suffix | Operation | Wallet that should run it |
|---------------|-----------|---------------------------|
| `*DeployImpl.s.sol` | Deploy a new implementation contract | Any wallet (impl is not authorized) |
| `*Upgrade.s.sol` | Call `upgradeToAndCall` on an existing proxy | **Proxy admin** wallet |
| `*Deploy.s.sol` (no Impl) | Deploy a fresh non-upgradeable contract | Deployer wallet of choice |
| `*Set*.s.sol` | Set business-logic config (e.g. default validator, OA name) | **Owner** wallet |

A `Script` contract has a `run()` function. If the deploy needs
parameters (constructor args, target addresses), use `--sig` to pass them
on the CLI:

```bash
forge script \
  --rpc-url sepolia \
  script/MyDeploy.s.sol \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --sig "run(address,uint256)" \
  0x1234... 86400
```

See the existing scripts for shape references — `FabricaValidatorUpgrade.s.sol`,
`FabricaMarketplaceZone.s.sol`, `FabricaFeeCollector.s.sol` are good
templates depending on what you're building.

## Pre-deploy checklist

Before running `--broadcast` on mainnet:

- [ ] Re-run `forge test` clean
- [ ] Mainnet-fork test exists for the new contract (`forge test --fork-url $MAINNET_RPC_URL`) and passes
- [ ] Re-audit with latest AI models passes clean (or document why skipped — see ENG-3006 for the audit pattern)
- [ ] Operator + counsel review on any new contract behaviors that affect user-facing flows or legal disclosures
- [ ] `forge build` succeeds with `--sizes`; bytecode under 24 KB EIP-170 limit (or you understand why it's allowed to exceed)
- [ ] Safe multisig configured for the actual deploy transaction (mainnet) — see "Safe multisig flow" below
- [ ] Deployment script's `--sig` parameters reviewed line-by-line by operator
- [ ] Etherscan API key valid (test with a sepolia deploy first if unsure)

For sepolia / dev networks: skip the operator-review items but keep the
test items.

## Deploy flow (network-by-network)

We default to **sepolia first, mainnet second**. For any new contract
family, the sequence is:

1. **Sepolia deploy** with the dev/sepolia deployer key. Validate end-to-end
   (soil-app + fabrica-v3-api can read/write the contract; the relevant
   user flow completes; events emit and the subgraph indexes them).
2. **Soak on sepolia** for at least one cycle of real testing.
3. **Mainnet deploy** via Safe multisig (see below) once sepolia
   validation passes.
4. **Post-deploy**: update all consumers (soil-app, fabrica-v3-api,
   subgraph) to point at the new mainnet address.

## Safe multisig flow (mainnet)

Mainnet deployment transactions are signed by the Fabrica Safe multisig.
The flow is:

1. Build the deploy transaction calldata locally using
   `forge script --rpc-url mainnet ... --skip-simulation` (DRY RUN — do
   NOT use `--broadcast` here; this generates the calldata only).
2. Inspect the calldata. It will be visible in the `broadcast/*.json`
   output Foundry writes.
3. Submit the transaction to the Safe Transaction Service via the Safe
   UI or CLI, targeting the contract address `0x0` (for `CREATE`) and
   the calldata from step 2.
4. Collect signatures from the Safe signers (the org's signing quorum).
5. Execute the Safe transaction. The deploy lands on-chain.
6. **Verify the deployed bytecode** matches what `forge build` produced
   locally. Run `forge verify-contract <deployed-address>
   <Contract>` to push verification to Etherscan.

Do NOT use `--broadcast` with a private-key flag on mainnet deploys.
That bypasses the Safe and signs the transaction under whatever key is
in `$DEPLOYER_PRIVATE_KEY` — which should never be a mainnet-funded key.

## Post-deploy: capture the address

When a deploy lands, record the new address in:

1. **`UPGRADE-RUNBOOK.md`** if the contract has its own upgrade path or
   is a proxy for an existing implementation
2. **A new doc** if this is a brand-new contract family (the Fabrica lending
   pool contracts and their deploy records live in the
   `fabrica-land/metastreet-contracts-v2` fork, not this repo)
3. **The `.broadcast/` artifacts** — Foundry's `--broadcast` writes
   per-network JSON files under `broadcast/<script>/<chain-id>/` that
   record the transaction hash and deployed address. Commit these when
   they reflect a real deploy; they're the historical record.
4. **Soil-app + fabrica-v3-api** — every consumer that references the
   contract address needs to be updated. A typical change touches:
   - `fabrica-v3-api/config/{develop,staging,production}.json` —
     per-network contract addresses
   - `soil-app/config/networks.ts` (or equivalent) — client-side
     address registry
   - `fabrica-v3-subgraph` — subgraph data sources for indexed events

## Verification on Etherscan / Basescan

`--verify` automates Etherscan verification at deploy time. If it fails
(network hiccup, API rate limit, missing constructor args):

```bash
forge verify-contract \
  --chain sepolia \
  --watch \
  <deployed-address> \
  src/path/to/Contract.sol:Contract
```

For contracts with constructor args, append:

```bash
  --constructor-args $(cast abi-encode "constructor(address,uint256)" 0xabc 86400)
```

`--watch` polls Etherscan until verification completes; for unattended
deploys, omit it and check status manually.

## When NOT to use `forge script`

- **Existing-contract upgrades** that go through Safe + reinitializer
  chains: follow [`UPGRADE-RUNBOOK.md`](./UPGRADE-RUNBOOK.md) — it has
  the FabricaToken-specific OZ v4→v5 storage migration pattern.
- **One-off Cast calls** for setting roles or paused state — use `cast send`,
  not `forge script`.
- **Reading deployed state** for diagnostics — `cast call`, `cast storage`.

## Common gotchas

- **Optimizer settings**: `foundry.toml` has `optimizer_runs = 1` (size
  over gas). For a contract that will see many transactions over its
  lifetime, consider raising to `optimizer_runs = 200` at deploy time
  by passing `--optimizer-runs 200` to `forge script`. This is a
  per-deploy decision; it doesn't change the toml file.
- **`via_ir = false`**: don't flip this on for a specific deploy without
  understanding the compilation-time-vs-bytecode-size tradeoff. The IR
  pipeline is slow (10+ min builds) and produces different bytecode.
- **Etherscan API rate limits**: free-tier keys hit limits quickly when
  verifying many contracts in sequence. Either upgrade the key or
  space deploys out.
- **`--legacy` for non-EIP-1559 networks**: some sidechains require it.
  Mainnet, sepolia, base-sepolia don't.
- **Foundry version drift**: `foundry.lock` pins the toolchain. Always
  `foundryup --version $(cat foundry.lock | jq -r .version)` (or
  equivalent) before deploying. Don't deploy with a newer-than-locked
  toolchain on mainnet.
