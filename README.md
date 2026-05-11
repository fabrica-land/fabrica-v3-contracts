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

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
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

Quick reference (sepolia / dev only — mainnet uses Safe multisig per
DEPLOYMENT.md):

```
forge script \
    --rpc-url sepolia \
    script/FabricaMarketplaceZone.s.sol \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --broadcast \
    --verify \
    # Only if the run function has parameters:
    --sig "run(address)" \
    0x3fE51ba59dDA319d5Ac3Bf372993Ec0705dC62CB
```
