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
  |                 |<-- Morpho pulls principal; settlement returns to its starting USDC balance         |
```

The payer is `msg.sender` and need not be the buyer. The zone and its signed `extraData` remain part of the seller's Seaport order; settlement passes them through unchanged. Seaport receives a zero fulfiller conduit key and sends the ERC-1155 directly to `buyer`.

Each call explicitly selects its payoff funding mode. `PriceHeadroom` requires the payer's `price` to cover both all signed consideration legs and the receipt's rounded-up maximum repayment. It is the Shape A mode and never uses a seller allowance. `SellerAllowance` only requires `price` to cover the consideration legs and pulls any payoff shortfall from the seller; it is the Shape B mode.

## Unified math

Let `P = price`, `C = legsTotal` (the sum of all static ERC-20 consideration legs), `M = receipt.repayment` (maximum payoff), and `L = actual payoff`, measured from the settlement contract's USDC balance delta.

- Pre-funded flash principal: `F = max(0, C + M - P)`.
- Sale headroom: `H = P - C`.
- Seller clawback: `sellerOwes = max(0, L - H)`.
- Seller residual: `sellerGets = max(0, H - L)`.
- At most one of `sellerOwes` and `sellerGets` is nonzero.

`M` is required before `repay`; if `L < M`, the larger pre-funded flash principal remains available for Morpho. After pool repayment, Seaport legs, and seller true-up, the settlement's balance increase equals `F`. Morpho pulls exactly `F`, and the contract asserts the currency balance has returned to its pre-settlement value after the flash call returns. Without a flash, the same path asserts the same net-zero invariant directly. Pre-existing currency donations remain untouched and can be recovered by the owner with `rescueERC20`.

## Supported currency behavior

Only conventional, non-fee-on-transfer, non-rebasing ERC-20 currencies that return a boolean from `transfer` and `transferFrom` are supported (for example, USDC). Currencies with missing return values or ERC-777-style transfer callbacks are also unsupported. Although settlement uses `SafeERC20`, the pool repayment path uses a bare `transferFrom` and expects a returned boolean, and the settlement accounting assumes exact balance deltas. The owner pool allowlist implicitly constrains supported currencies because settlement reads the currency from `pool.currencyToken()`. Currency decimals must remain at most 18.

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
| Pool is not owner-allowlisted | `PoolNotAllowed`. |
| Bad receipt encoding/version | `InvalidReceiptEncoding`. |
| Partial/zero fraction or offer count other than one | `InvalidOrder`. |
| Offer is not one static ERC-1155 unit | `ReceiptOrderMismatch`. |
| Receipt borrower is not offerer | `ReceiptOrderMismatch`. |
| Receipt collateral token/id differs from offer | `ReceiptOrderMismatch`. |
| Empty, non-ERC-20, non-static, identified, or wrong-currency consideration | `InvalidConsideration`. |
| Consideration total exceeds the declared full price | `PriceBelowConsideration`. |
| `PriceHeadroom` price does not cover consideration plus maximum repayment | `PriceBelowHeadroom`. |
| `PriceHeadroom` unexpectedly reaches a seller clawback | `UnexpectedClawback`. |
| Loan already repaid/inactive | Pool `repay` reverts; the transaction is atomic. |
| Live payoff cannot be funded | Pool transfer or seller clawback reverts. |
| Missing seller allowance in a clawback shape | Seller `safeTransferFrom` reverts. |
| Invalid/expired zone permission or invalid Seaport signature/order | Seaport/zone reverts. |
| Seaport returns false | `SeaportFulfillmentFailed`. |
| Callback is not configured Morpho, not in flight, or data differs | `UnauthorizedFlashCallback`. |
| Morpho callback reports a different principal | `FlashAmountMismatch`. |
| Flash provider underfunds or cannot pull repayment | Settlement balance check or token transfer reverts. |
| Settlement changes its currency balance unexpectedly | `SettlementBalanceNotZero`; pre-existing donations remain untouched. |
| Non-owner pause/unpause/rescue | OZ `OwnableUnauthorizedAccount`. |
| Rescue recipient is zero | `InvalidAddress`. |

## Trust model

Settlement only calls pools explicitly approved by the owner. This allowlist is a security boundary, not merely discovery metadata: without it, an attacker could reuse a seller's still-valid signed Shape B order after the seller manually repaid, supply a fake pool and crafted receipt that mirror the order's borrower and collateral, have the fake `repay` consume settlement funds, and make the clawback branch pull real USDC through the seller's lingering settlement allowance. The fake pool would retain those funds. Operations must validate pool implementations and addresses before allowlisting them and remove pools that should no longer receive settlements.

The caller must also choose the funding model explicitly. `PriceHeadroom` is for Shape A and enforces `price >= legsTotal + maxRepayment`, so payoff drift is refunded to the seller and seller clawback is treated as an invariant violation. `SellerAllowance` is for Shape B and retains the maximum-sized flash plus seller-clawback flow; the seller must approve settlement for the required shortfall. A Shape A order submitted as `SellerAllowance` does not gain price-headroom protection and will revert at clawback when the seller has not approved settlement.

As an additional operational safeguard, soil should set the settlement contract's USDC allowance to zero as part of the manual payoff flow. Clearing that approval prevents stale Shape B allowances from remaining usable after the loan has been repaid.

## Residual race condition

If the seller self-repays and then a third party directly fills a still-live Shape A Seaport order, that order can execute at its signed floor price without this contract's residual-headroom payment. V1 does not add an on-chain restriction. The mitigation is API cancel-on-repay plus a short oracle permission expiry.

## Known limitation: caller-chosen buyer / front-running (deferred to pre-mainnet hardening)

`settleAndBuy` is permissionless and takes `buyer` as an explicit argument (this is intentional: it lets Coinflow's relayer settle on a buyer's behalf, where `msg.sender != buyer`). A watcher can therefore copy a pending settlement transaction and substitute a different `buyer`. This is a griefing / queue-jump vector, not a theft vector: `price` is always pulled from `msg.sender`, so a front-runner must fund the full price from their own wallet to snipe a property, and no path can drain the original buyer's or the seller's funds (verified by adversarial review 2026-07-11). In the Coinflow path the relayer is `msg.sender`, so a front-runner pays their own USDC and the original buyer is simply refunded by Coinflow. Decision (Fede, 2026-07-11): ship v1 with this documented, rely on short oracle-permission expiry and private/relayer submission for Coinflow, and add signed buyer-binding (oracle signs `orderHash + buyer`) in the pre-mainnet hardening pass. Mainnet is separately gated by ENG-3115.

## Deployment

Morpho Blue is deployed on Sepolia at the canonical address `0xBBBBBbbBBb9cC5e90e3b3Af64bDAF62C37EEFFCb` (bytecode verified 2026-07-11), the same address as mainnet, so the `morpho_` constructor argument is identical across networks. If a network lacks a Morpho deployment, operations must supply or deploy a compatible zero-fee flash provider and set its address explicitly.

```sh
export SEAPORT_ADDRESS=0x0000000000000068F116a894984e2DB1123eB395
export MORPHO_ADDRESS=<chain flash provider>
export SETTLEMENT_OWNER=<support multisig>
export SETTLEMENT_INITIAL_POOLS=<pool address[,pool address...]>
forge script script/FabricaSettlementDeploy.s.sol:FabricaSettlementDeployScript \
  --rpc-url <rpc> --broadcast --verify
```

The script performs one operation and reads all constructor arguments from environment variables. Dry-run without `--broadcast`; verification uses the repository's Etherscan configuration and `--verify`.
