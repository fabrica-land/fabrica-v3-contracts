# FabricaSettlement v1

`FabricaSettlement` atomically pays off one active Fabrica/MetaStreet v2 loan and fills one static Seaport 1.6 ERC-1155 sale. It deliberately has no financing or downpayment behavior.

## Sequence

```text
payer          settlement          Morpho (if needed)       pool             Seaport             seller/buyer
  | price -------->|                       |                   |                  |                       |
  |                 |-- flash(max gap) --->|                   |                  |                       |
  |                 |<----- USDC ----------|                   |                  |                       |
  |                 |-- repay(receipt) ----------------------->|                  |                       |
  |                 |<-- raw ERC-1155 returned to seller -----|-------------------------------> seller  |
  |                 |-- fulfillAdvancedOrder(recipient=buyer) ------------------>| seller NFT ----------> buyer
  |                 |<---------------- order ERC-20 legs pulled by Seaport ------|                       |
  |                 |<-- seller clawback, or --> seller residual headroom                                |
  |                 |-- approve exact flash principal --> Morpho                                         |
  |                 |<-- Morpho pulls principal; final USDC balance = 0                                  |
```

The payer is `msg.sender` and need not be the buyer. The zone and its signed `extraData` remain part of the seller's Seaport order; settlement passes them through unchanged. Seaport receives a zero fulfiller conduit key and sends the ERC-1155 directly to `buyer`.

## Unified math

Let `P = price`, `C = legsTotal` (the sum of all static ERC-20 consideration legs), `M = receipt.repayment` (maximum payoff), and `L = actual payoff`, measured from the settlement contract's USDC balance delta.

- Pre-funded flash principal: `F = max(0, C + M - P)`.
- Sale headroom: `H = P - C`.
- Seller clawback: `sellerOwes = max(0, L - H)`.
- Seller residual: `sellerGets = max(0, H - L)`.
- At most one of `sellerOwes` and `sellerGets` is nonzero.

`M` is required before `repay`; if `L < M`, the larger pre-funded flash principal remains available for Morpho. After pool repayment, Seaport legs, and seller true-up, the settlement balance equals `F`. Morpho pulls exactly `F`, and the contract asserts the currency balance is zero after the flash call returns. Without a flash, the same path asserts zero directly.

## Worked order shapes

Use `P = 100,000 USDC`, Fabrica fee `= 5,000 USDC`, `M = 22,000 USDC`, and `L = 21,000 USDC`.

Shape A, listed while under loan: seller floor leg is `100,000 - 5,000 - 22,000 = 73,000`; fee is `5,000`, so `C = 78,000`, `H = 22,000`, and `F = 0`. Repayment consumes `21,000`, Seaport pays the signed `73,000 + 5,000` legs, and the unused headroom `sellerGets = 22,000 - 21,000 = 1,000` goes to the seller. Total seller proceeds are `74,000`.

Shape B, loan taken after listing: seller leg is `95,000`; fee is `5,000`, so `C = 100,000`, `H = 0`, and `F = 22,000`. The settlement repays `L = 21,000`, Seaport pays `95,000 + 5,000`, and `sellerOwes = 21,000` is pulled from the seller's just-received proceeds. The extra `1,000` in the maximum-sized flash remains in settlement; Morpho then pulls the full `22,000`. Total seller proceeds are `74,000`.

Hybrids use exactly the same equations.

## Revert matrix

| Condition | Result / reason |
|---|---|
| Paused entrypoint | OZ `EnforcedPause`; operations can stop new settlements. |
| Reentrant `settle` | OZ `ReentrancyGuardReentrantCall`. |
| Zero pool or buyer | `InvalidAddress`. |
| Bad receipt encoding/version | `InvalidReceiptEncoding`. |
| Partial/zero fraction or offer count other than one | `InvalidOrder`. |
| Offer is not one static ERC-1155 unit | `ReceiptOrderMismatch`. |
| Receipt borrower is not offerer | `ReceiptOrderMismatch`. |
| Receipt collateral token/id differs from offer | `ReceiptOrderMismatch`. |
| Empty, non-ERC-20, non-static, identified, or wrong-currency consideration | `InvalidConsideration`. |
| Consideration total exceeds the declared full price | `PriceBelowConsideration`. |
| Loan already repaid/inactive | Pool `repay` reverts; the transaction is atomic. |
| Live payoff cannot be funded | Pool transfer or seller clawback reverts. |
| Missing seller allowance in a clawback shape | Seller `safeTransferFrom` reverts. |
| Invalid/expired zone permission or invalid Seaport signature/order | Seaport/zone reverts. |
| Seaport returns false | `SeaportFulfillmentFailed`. |
| Callback is not configured Morpho, not in flight, or data differs | `UnauthorizedFlashCallback`. |
| Morpho callback reports a different principal | `FlashAmountMismatch`. |
| Flash provider underfunds or cannot pull repayment | Settlement balance check or token transfer reverts. |
| Currency dust or unexpected token behavior | `SettlementBalanceNotZero`; no funds persist. |
| Non-owner pause/unpause/rescue | OZ `OwnableUnauthorizedAccount`. |
| Rescue recipient is zero | `InvalidAddress`. |

## Trust and permissionlessness

The per-call pool is intentionally not checked against a factory or registry. This keeps settlement composable with Fabrica-forked pools and avoids coupling execution to registry availability or upgrades. The off-chain Fabrica API decides which pools it offers to users. A caller who supplies an untrusted pool is trusting that pool's `currencyToken` and `repay` behavior; approvals are reset after the call, and atomic balance checks limit persistent exposure.

## Residual race condition

If the seller self-repays and then a third party directly fills a still-live Shape A Seaport order, that order can execute at its signed floor price without this contract's residual-headroom payment. V1 does not add an on-chain restriction. The mitigation is API cancel-on-repay plus a short oracle permission expiry.

## Deployment

There is no verified Morpho Blue deployment on Sepolia. Operations must supply or deploy a compatible zero-fee flash provider there and set its address explicitly.

```sh
export SEAPORT_ADDRESS=0x0000000000000068F116a894984e2DB1123eB395
export MORPHO_ADDRESS=<chain flash provider>
export SETTLEMENT_OWNER=<support multisig>
forge script script/FabricaSettlementDeploy.s.sol:FabricaSettlementDeployScript \
  --rpc-url <rpc> --broadcast --verify
```

The script performs one operation and reads all constructor arguments from environment variables. Dry-run without `--broadcast`; verification uses the repository's Etherscan configuration and `--verify`.
