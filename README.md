## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```bash
set -a
. ./.env
set +a
: "${ORACLE_SIGNER_ADDRESS:?set ORACLE_SIGNER_ADDRESS}"
forge script script/FabricaMarketplaceZone.s.sol \
  --rpc-url sepolia \
  --account "$DEPLOYER_ACCOUNT" \
  --broadcast \
  --verifier etherscan \
  --verify \
  --sig "run(address)" \
  "$ORACLE_SIGNER_ADDRESS"
```

### Cast

```shell
cast --help
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

### Deploying

See **[`DEPLOYMENT.md`](./DEPLOYMENT.md)** for the full deploy flow —
environment setup, script conventions, pre-deploy checklist, Safe
multisig pattern for mainnet, and post-deploy address-recording
discipline.

For UUPS-proxy upgrades to existing deployments (FabricaToken,
FabricaValidator), see **[`UPGRADE-RUNBOOK.md`](./UPGRADE-RUNBOOK.md)**.
The Fabrica lending pool stack lives in the
[`fabrica-land/metastreet-contracts-v2`](https://github.com/fabrica-land/metastreet-contracts-v2)
fork, with its own deploy scripts and upgrade runbook.

For the guarded lending price oracle used by future pool launches, see
**[`GUARDED-PRICE-ORACLE-RUNBOOK.md`](./GUARDED-PRICE-ORACLE-RUNBOOK.md)**.

Quick reference (sepolia / dev only — mainnet uses Safe multisig per
DEPLOYMENT.md):

```bash
set -a
. ./.env
set +a
: "${ORACLE_SIGNER_ADDRESS:?set ORACLE_SIGNER_ADDRESS}"

forge script \
    --rpc-url sepolia \
    script/FabricaMarketplaceZone.s.sol \
    --account "$DEPLOYER_ACCOUNT" \
    --broadcast \
    --verifier etherscan \
    --verify \
    --sig "run(address)" \
    "$ORACLE_SIGNER_ADDRESS"
```
