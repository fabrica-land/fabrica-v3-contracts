# FabricaSettlement v1

`FabricaSettlement` fills one full-price, static Seaport 1.6 ERC-1155 sale. If an allowlisted Fabrica/MetaStreet v2 pool still holds the raw ERC-1155, settlement atomically pays off the active loan first. If the pool no longer holds it, settlement directly fills the order without a flash loan, repayment, or seller clawback. It deliberately has no financing, downpayment, reduced-price, or caller-selected funding mode.

## Under-loan payoff path

Settlement detects an active loan by checking whether the supplied pool holds at least one unit of the order's raw ERC-1155 token ID. When it does, the existing payoff sequence is unchanged:

```text
caller/buyer        settlement          Morpho              pool              Seaport          seller / buyer
  |                     |-- flash M ------>|                   |                  |                    |
  |                     |<---- USDC -------|                   |                  |                    |
  |                     |-- repay(receipt) ------------------->|                  |                    |
  |                     |<-- collateral returned to seller ---|----------------------------> seller  |
  | full price P ------>|                  |                   |                  |                    |
  |                     |-- fulfillAdvancedOrder(recipient=buyer) ------------->| NFT -------------> buyer
  |                     |<----------- full signed consideration P pulled -------|----> recipients    |
  |                     |<-- actual payoff L pulled from seller allowance ---------------- seller    |
  |                     |-- approve flash principal M --> Morpho                                      |
  |                     |<-- Morpho pulls M; settlement returns to its entry USDC balance             |
```

The caller is `msg.sender` and pays exactly the sum of the signed consideration legs. The caller need not be `buyer`, which supports relayed purchases. The zone and signed `extraData` pass through unchanged. Seaport sends the ERC-1155 directly to `buyer`, saving an intermediate transfer.

Morpho Blue liveness and sufficient flash liquidity are hard dependencies of every under-loan settlement with a nonzero scaled `maxRepayment`. The contract requests and repays a flash principal of exactly `maxRepayment` and approves Morpho for exactly that amount. A degenerate receipt whose scaled `maxRepayment` is zero bypasses Morpho because canonical Morpho rejects zero-asset flash loans. This hard-assumes a zero-fee flash provider for nonzero flashes: `SETTLEMENT_ALLOW_NON_CANONICAL_MORPHO` must only ever authorize deployment against a compatible zero-fee provider.

## No-loan direct path

If the allowlisted pool no longer holds the offered token, settlement pulls the full signed consideration total from the caller and calls `fulfillAdvancedOrder(..., recipient=buyer)` directly. It does not decode or validate the loan receipt, request a Morpho flash loan, call `pool.repay`, or pull a payoff from the seller. `SettlementExecuted` reports both `payoffPaid` and `sellerClawback` as zero.

This path handles the Coinflow race where a buyer's relayed transaction is in flight but the seller repays the loan before `settleAndBuy` executes. Once repayment returns the raw token to the seller, the signed Seaport sale can still complete and deliver it to the buyer.

## Accounting

Let `P = legsTotal`, `M = receipt.maxRepayment` after decimal scaling, and `L = actual payoff` measured from the settlement contract's balance delta.

- The caller funds exactly `P`.
- The flash bridge is computed as `P + M - P = M`.
- Pool repayment consumes `L`, where `L <= M` for a valid receipt.
- Seaport consumes `P` and pays every signed consideration leg.
- Settlement pulls exactly `L` from the seller (`receipt.borrower`).
- The unused `M - L` plus the clawed-back `L` repays the full flash principal `M`.

The contract snapshots its currency balance at entry and requires the same balance after settlement on both paths. On the direct path, the caller's `P` enters settlement and Seaport consumes the same `P`, restoring the entry balance. Pre-existing donations therefore remain untouched and do not block settlement; the owner can recover them with `rescueERC20`.

## Worked example

For a full signed price `P = $100`, actual loan payoff `L = $20`, and signed fee leg of `$5`, the buyer pays `$100`. Seaport pays `$95` to the seller and `$5` to the fee recipient. Settlement then claws back `$20` from the seller, so the seller nets `$75`. The loan is cleared, the flash loan is repaid, and settlement nets `$0`.

## Seller allowance safety

The seller's standing USDC allowance to settlement is safe in this full-price-only design. The prior fund-loss vector required a reduced-price order whose consideration legs were below the true price, allowing a buyer to underpay and turn loan headroom into a discount. Here the buyer always pays the complete signed consideration total, and the seller is charged only the balance-delta-measured payoff of their own loan during their own authorized sale. There is no caller-chosen price or payoff mode to abuse.

The under-loan path has two explicit seller-side preconditions:

1. The seller's live currency allowance to settlement must be at least `maxRepayment`.
2. After Seaport pays the signed proceeds leg, that proceeds amount and/or the seller's existing wallet balance must cover the actual payoff `L`.

If either precondition is not met, the transaction reverts atomically: no NFT is delivered, no consideration leg remains paid, and the loan cannot be left repaid but unfunded. The API is expected to gate the BUY by withholding settlement permission whenever `maxRepayment`, including accrual headroom, exceeds the seller's net proceeds. This `UNDERWATER` buy-gate is the primary guard; the on-chain revert is its backstop.

A single-use EIP-2612 or Permit2 authorization can replace the standing allowance as optional future hardening, but it is not a security requirement.

## Validation and trust model

Only owner-allowlisted pools may be supplied, including on the no-loan path. The allowlist is a security boundary: operations must validate pool implementations and addresses before adding them and remove pools that should no longer receive settlements.

Every order must contain one static ERC-1155 offer of amount one, use no conduit, represent a full fill, and contain only static ERC-20 consideration in the pool currency with no appended tips. On the under-loan path, the receipt borrower must additionally be the Seaport offerer, the receipt collateral must match the offer, and the borrower must receive at least one consideration leg. The receipt is intentionally ignored on the no-loan path. Currency decimals must be at most 18 when scaling an active loan's maximum repayment.

Only conventional, non-fee-on-transfer, non-rebasing ERC-20 currencies are supported. The owner pool allowlist implicitly constrains supported currencies because settlement reads the currency from `pool.currencyToken()`.

## Revert matrix

| Condition | Result / reason |
|---|---|
| Paused entrypoint | OZ `EnforcedPause`. |
| Reentrant `settleAndBuy` | OZ `ReentrancyGuardReentrantCall`. |
| Zero pool or buyer | `InvalidAddress`. |
| Constructor Seaport, Morpho, or initial pool has no code | `NotAContract`. |
| Pool is not owner-allowlisted | `PoolNotAllowed`. |
| Bad receipt encoding/version | Under-loan: `InvalidReceiptEncoding`. No-loan: receipt is not decoded or validated. |
| Partial/zero fraction, nonzero conduit key, or offer count other than one | `InvalidOrder`. |
| Offer is not one static ERC-1155 unit | `InvalidOrder`. |
| Receipt borrower is not offerer or receipt collateral differs | Under-loan: `ReceiptOrderMismatch`. No-loan: receipt is ignored. |
| Empty, non-ERC-20, non-static, identified, wrong-currency, or overflowing consideration | `InvalidConsideration`. |
| Borrower/offerer receives no consideration leg | Under-loan: `SellerRecipientMismatch`. No-loan: no seller-recipient receipt check is needed. |
| Appended consideration changes the original consideration count | Both paths: `UnexpectedConsiderationTip`. |
| Pool currency has more than 18 decimals | `UnsupportedCurrencyDecimals`. |
| Pool holds the collateral but repayment is inactive | Pool `repay` reverts; the transaction is atomic. |
| Measured payoff exceeds the receipt maximum | `PayoffExceedsMaxRepayment`; the transaction is atomic. |
| Seller allowance is below `maxRepayment`, or seller funds after proceeds are below actual payoff | Under-loan transfer reverts atomically; no-loan performs no clawback. |
| Invalid/expired zone permission or invalid Seaport signature/order | Seaport/zone reverts. |
| Seaport returns false | `SeaportFulfillmentFailed`. |
| Callback is not configured Morpho, not in flight, or data differs | `UnauthorizedFlashCallback`. |
| Morpho callback reports a different principal | `FlashAmountMismatch`. |
| Nonzero flash provider underfunds or cannot pull repayment | Token transfer or balance invariant reverts. |
| Settlement changes its currency balance unexpectedly | `SettlementBalanceNotZero`; pre-existing donations remain untouched. |
| Non-owner pool management, pause/unpause, or rescue | OZ `OwnableUnauthorizedAccount`. |
| Rescue token or recipient is zero | `InvalidAddress`. |

## Known limitation: caller-chosen buyer / front-running

`settleAndBuy` is permissionless and takes `buyer` explicitly so a Coinflow relayer can settle on a buyer's behalf. A watcher can copy a pending transaction and substitute another buyer, but must fund the full signed price from their own wallet. This is a queue-jump/griefing vector rather than a drain of the original buyer or seller. Short oracle-permission expiry and private/relayer submission mitigate it; signed buyer-binding remains a possible pre-mainnet hardening.

## Deployment

Morpho Blue is deployed on Sepolia at `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`, the same address as mainnet. The Sepolia Fabrica fork pool is `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B`. If a network lacks Morpho, supply a compatible zero-fee flash provider and export `SETTLEMENT_ALLOW_NON_CANONICAL_MORPHO=true`. That override must never point at a fee-charging provider because settlement approves repayment of exactly the requested principal.

The runtime entrypoint is:

```solidity
settleAndBuy(AdvancedOrder order, address pool, bytes encodedLoanReceipt, address buyer)
```

Sepolia deployment:

```sh
export SETTLEMENT_SEAPORT=0x0000000000000068F116a894984e2DB1123eB395
export SETTLEMENT_MORPHO=0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
export SETTLEMENT_OWNER=<Sepolia owner address>
export SETTLEMENT_INITIAL_POOLS=0x6C56d0953377D7AB479BBA85Da8d61050F774c0B
export SEPOLIA_RPC_URL=<Sepolia RPC URL>
export ETHERSCAN_API_KEY=<Etherscan API key>

forge script script/FabricaSettlementDeploy.s.sol:FabricaSettlementDeployScript \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast --verify
```

After deployment, verify every configured `allowedPools` entry and `owner()`, add settlement to the Coinflow merchant allowlist, and record verification links. Mainnet deployment remains gated by ENG-3115 and must use the Safe.
