# ENG-2556 / ENG-3450 Sepolia Deployment Evidence

Broadcast base commit: `a6eb23ff81958fb54d569e26d9af826424361610`
Network: Sepolia (`11155111`)
Signer address: `0xBF03076547a99857b796717faF4034dea94569dF`

The implementation deployments use bytecode from merged source at the broadcast
base commit. The token proxy upgrade required `runNoInit(address,address)`
because the live proxy was already initialized to version 6; Foundry recorded
the base commit in the broadcast JSON while that local script helper was still
uncommitted. This PR commits and reviews the `runNoInit` helper that produced
the empty-data token upgrade transaction.

## Deployment Summary

| Step | Address | Tx | Block | Status |
| --- | --- | --- | --- | --- |
| Deploy `FabricaToken` implementation | `0x632eB7A76041B33b070213Cf11d518e84E556391` | `0x1a2c8cd3ccf8009bb1d39b59f7fa9e847baae8ee7c10aca28d1198081a2f2b3f` | `11218200` | success |
| Upgrade `FabricaToken` proxy | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` | `0x31926b4329da6de191647792575de7f98f048d38f0a3d4cbfd64808e2146c31a` | `11218207` | success |
| Deploy `FabricaFeeCollector` implementation | `0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296` | `0x51d61ce396373ffd20797179eebb32c2adb7f5807d080032bedd19ed2007c476` | `11218208` | success |
| Upgrade fee collector prod proxy | `0x404f53869aD67e167a8C89035f55572e653d7B22` | `0x01d01ad3c0daddef3d99b0a826c1871b4fd0cc703b8fca79345a6f8edd80fa3e` | `11218213` | success |
| Upgrade fee collector staging proxy | `0x98e819BF78081f4343E71Ed4096C59d74948C166` | `0xa2ce7d46d4964a2bfd51fdd74622ae7e71b3025f3e8a5ca493d02973a1ee24b6` | `11218214` | success |
| Upgrade fee collector develop proxy | `0x24888646723ae14C83E5354431753675A3d12D3c` | `0xf5729f088e7915734d078f1566a886b120113db97a9582be0b216f219fad34c0` | `11218215` | success |

Implementation source verification:

- `FabricaToken`: https://sepolia.etherscan.io/address/0x632eB7A76041B33b070213Cf11d518e84E556391#code
- `FabricaFeeCollector`: https://sepolia.etherscan.io/address/0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296#code

The implementation deployment receipts are checked in at:

- `broadcast/FabricaTokenDeployImpl.s.sol/11155111/run-1783375614404.json`
- `broadcast/FabricaFeeCollectorDeployImpl.s.sol/11155111/run-1783375738184.json`

## Broadcast Artifacts

- `broadcast/FabricaTokenDeployImpl.s.sol/11155111/run-1783375614404.json`
- `broadcast/FabricaTokenDeployImpl.s.sol/11155111/run-latest.json`
- `broadcast/FabricaTokenUpgrade.s.sol/11155111/run-1783375681406.json`
- `broadcast/FabricaTokenUpgrade.s.sol/11155111/runNoInit-latest.json`
- `broadcast/FabricaFeeCollectorDeployImpl.s.sol/11155111/run-1783375738184.json`
- `broadcast/FabricaFeeCollectorDeployImpl.s.sol/11155111/run-latest.json`
- `broadcast/FabricaFeeCollectorUpgrade.s.sol/11155111/run-1783375754560.json`
- `broadcast/FabricaFeeCollectorUpgrade.s.sol/11155111/run-1783375765228.json`
- `broadcast/FabricaFeeCollectorUpgrade.s.sol/11155111/run-1783375777657.json`
- `broadcast/FabricaFeeCollectorUpgrade.s.sol/11155111/run-latest.json`

## Live Post-Upgrade Reads

```text
## token
implementation 0x632eB7A76041B33b070213Cf11d518e84E556391
owner 0xBF03076547a99857b796717faF4034dea94569dF
defaultValidator 0xAAA7FDc1A573965a2eD47Ab154332b6b55098008
validatorRegistry 0xb54392209537606F30bC056f3D83d0771A69c9ba

## fee collectors
proxy=0x404f53869aD67e167a8C89035f55572e653d7B22
  implementation 0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296
  protocolContractAddress 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
  protocolSharePercent 100
proxy=0x98e819BF78081f4343E71Ed4096C59d74948C166
  implementation 0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296
  protocolContractAddress 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
  protocolSharePercent 100
proxy=0x24888646723ae14C83E5354431753675A3d12D3c
  implementation 0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296
  protocolContractAddress 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
  protocolSharePercent 100
```

## Functional Verification

ENG-2556 live revert:

```text
transactionHash      0x40bd5b5a9abc47f13c4c8d0f8acb436b76877642fe7f55d5197d7735d0816e8f
blockNumber          11218220
to                   0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
status               0 (failed)
```

The matching `eth_call` reverted with selector `0x8c3b41ca`, which equals `DefaultValidatorZero()`.

ENG-2556 positive control:

```text
transactionHash      0xa3b9c905fe0c8a93385f87bd61de9d34c64f23b5c93ab3beba1ed119cf4ba0b3
blockNumber          11218222
to                   0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
status               1 (success)
final-default-validator 0xAAA7FDc1A573965a2eD47Ab154332b6b55098008
```

ENG-3450 live discriminator:

```text
FabricaToken.defaultValidator() = 0xAAA7FDc1A573965a2eD47Ab154332b6b55098008
```

The live default validator is nonzero, so the zero-resolved-validator burn path cannot be triggered on shared Sepolia without mutating live token validator/default state. The mutation-free proof is a fork-of-Sepolia simulation pinned after the upgrades. Required manual FV sets `FABRICA_REQUIRE_SEPOLIA_FV=1`, which makes the test fail loudly if `SEPOLIA_RPC_URL` is absent; ordinary CI runs without that flag skip the fork test when the RPC env is absent.

```text
FABRICA_REQUIRE_SEPOLIA_FV=1 forge test --match-path test/Eng2556Eng3450SepoliaForkFV.t.sol -vvv

fork block: 11218223
token implementation: 0x632eB7A76041B33b070213Cf11d518e84E556391
fee collector implementation: 0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296

Ran 1 test for test/Eng2556Eng3450SepoliaForkFV.t.sol:Eng2556Eng3450SepoliaForkFVTest
[PASS] test_fork_collectFee_revertsWhenResolvedValidatorZeroAfterSepoliaUpgrade() (gas: 1013674)
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

The fork test zeroes only the forked `defaultValidator` storage slot, calls all three upgraded fee collector proxies, expects `ValidatorAddressZero()`, and asserts the ERC-20 transfer rolls back for each proxy.
