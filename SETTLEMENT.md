# FabricaSettlement v1

`FabricaSettlement` atomically pays off one active Fabrica/MetaStreet v2 loan and fills one full-price, static Seaport 1.6 ERC-1155 sale. It deliberately has no financing, downpayment, reduced-price, or caller-selected funding mode.

## Sequence

```text
caller/buyer        settlement          Morpho              pool              Seaport          seller / buyer
  | full price P ------>|                  |                   |                  |                    |
  |                     |-- flash M ------>|                   |                  |                    |
  |                     |<---- USDC -------|                   |                  |                    |
  |                     |-- repay(receipt) ------------------->|                  |                    |
  |                     |<-- collateral returned to seller ---|----------------------------> seller  |
  |                     |-- fulfillAdvancedOrder(recipient=buyer) ------------->| NFT -------------> buyer
  |                     |<----------- full signed consideration P pulled -------|----> recipients    |
  |                     |<-- actual payoff L pulled from seller allowance ---------------- seller    |
  |                     |-- approve flash principal M --> Morpho                                      |
  |                     |<-- Morpho pulls M; settlement returns to its entry USDC balance             |
```

The caller is `msg.sender` and pays exactly the sum of the signed consideration legs. The caller need not be `buyer`, which supports relayed purchases. The zone and signed `extraData` pass through unchanged. Seaport sends the ERC-1155 directly to `buyer`, saving an intermediate transfer.

## Accounting

Let `P = legsTotal`, `M = receipt.maxRepayment` after decimal scaling, and `L = actual payoff` measured from the settlement contract's balance delta.

- The caller funds exactly `P`.
- The flash bridge is computed as `P + M - P = M`.
- Pool repayment consumes `L`, where `L <= M` for a valid receipt.
- Seaport consumes `P` and pays every signed consideration leg.
- Settlement pulls exactly `L` from the seller (`receipt.borrower`).
- The unused `M - L` plus the clawed-back `L` repays the full flash principal `M`.

The contract snapshots its currency balance at entry and requires the same balance after settlement. Pre-existing donations therefore remain untouched and do not block settlement; the owner can recover them with `rescueERC20`.

## Worked example

For a full signed price `P = $100` and actual loan payoff `L = $20`, the buyer pays `$100`. Seaport pays the signed `$100` consideration, including the seller's proceeds and any fee legs. The seller receives their signed proceeds and is then charged `$20`, so ignoring any separately signed fee legs the seller nets `$80`. The loan is cleared, the flash loan is repaid, and settlement nets `$0`.

## Seller allowance safety

The seller's standing USDC allowance to settlement is safe in this full-price-only design. The prior fund-loss vector required a reduced-price order whose consideration legs were below the true price, allowing a buyer to underpay and turn loan headroom into a discount. Here the buyer always pays the complete signed consideration total, and the seller is charged only the balance-delta-measured payoff of their own loan during their own authorized sale. There is no caller-chosen price or payoff mode to abuse.

A single-use EIP-2612 or Permit2 authorization can replace the standing allowance as optional future hardening, but it is not a security requirement.

## Validation and trust model

Only owner-allowlisted pools may be repaid. The allowlist is a security boundary: operations must validate pool implementations and addresses before adding them and remove pools that should no longer receive settlements.

The receipt borrower must be the Seaport offerer. The receipt collateral must match the order's single static ERC-1155 offer of amount one. As defense in depth, the borrower must be a recipient of at least one consideration leg. All consideration legs must be static ERC-20 amounts in the pool currency, and appended Seaport tips are rejected. Currency decimals must be at most 18.

Only conventional, non-fee-on-transfer, non-rebasing ERC-20 currencies are supported. The owner pool allowlist implicitly constrains supported currencies because settlement reads the currency from `pool.currencyToken()`.

## Revert matrix

| Condition | Result / reason |
|---|---|
| Paused entrypoint | OZ `EnforcedPause`. |
| Reentrant `settleAndBuy` | OZ `ReentrancyGuardReentrantCall`. |
| Zero pool or buyer | `InvalidAddress`. |
| Constructor Seaport, Morpho, or initial pool has no code | `NotAContract`. |
| Pool is not owner-allowlisted | `PoolNotAllowed`. |
| Bad receipt encoding/version | `InvalidReceiptEncoding`. |
| Partial/zero fraction, nonzero conduit key, or offer count other than one | `InvalidOrder`. |
| Offer is not one static ERC-1155 unit, borrower is not offerer, or collateral differs | `ReceiptOrderMismatch`. |
| Empty, non-ERC-20, non-static, identified, wrong-currency, or overflowing consideration | `InvalidConsideration`. |
| Borrower/offerer receives no consideration leg | `SellerRecipientMismatch`. |
| Appended consideration changes the original consideration count | `UnexpectedConsiderationTip`. |
| Pool currency has more than 18 decimals | `UnsupportedCurrencyDecimals`. |
| Loan already repaid/inactive or payoff exceeds the receipt maximum | Pool `repay` reverts; the transaction is atomic. |
| Missing or insufficient seller allowance | Seller `safeTransferFrom` reverts. |
| Invalid/expired zone permission or invalid Seaport signature/order | Seaport/zone reverts. |
| Seaport returns false | `SeaportFulfillmentFailed`. |
| Callback is not configured Morpho, not in flight, or data differs | `UnauthorizedFlashCallback`. |
| Morpho callback reports a different principal | `FlashAmountMismatch`. |
| Flash provider underfunds or cannot pull repayment | Token transfer or balance invariant reverts. |
| Settlement changes its currency balance unexpectedly | `SettlementBalanceNotZero`; pre-existing donations remain untouched. |
| Non-owner pool management, pause/unpause, or rescue | OZ `OwnableUnauthorizedAccount`. |
| Rescue token or recipient is zero | `InvalidAddress`. |

## Known limitation: caller-chosen buyer / front-running

`settleAndBuy` is permissionless and takes `buyer` explicitly so a Coinflow relayer can settle on a buyer's behalf. A watcher can copy a pending transaction and substitute another buyer, but must fund the full signed price from their own wallet. This is a queue-jump/griefing vector rather than a drain of the original buyer or seller. Short oracle-permission expiry and private/relayer submission mitigate it; signed buyer-binding remains a possible pre-mainnet hardening.

## Deployment

Morpho Blue is deployed on Sepolia at `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`, the same address as mainnet. The Sepolia Fabrica fork pool is `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B`. If a network lacks Morpho, supply a compatible zero-fee flash provider and export `SETTLEMENT_ALLOW_NON_CANONICAL_MORPHO=true`.

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
