// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Morpho} from "../lib/morpho-blue/src/Morpho.sol";
import {FiatTokenV2_2} from "../lib/stablecoin-evm/contracts/v2/FiatTokenV2_2.sol";
import {Pool} from "../lib/metastreet-contracts-v2/contracts/Pool.sol";

contract BuyUnderMetaStreetLoan is IMorphoFlashLoanCallback {
  Pool metaStreetPool;
  Morpho morpho;
  FiatTokenV2_2 usdc;

  constructor(
    address usdcAddress,
    address morphoAddress,
    address metaStreetPoolAddress
  ) {
    usdc = FiatTokenV2_2(usdcAddress);
    morpho = Morpho(morphoAddress);
    metaStreetPool = Pool(metaStreetPoolAddress);
  }

  function buyUnderMetaStreetLoan(
    LoanReceipt.LoanReceiptV2 calldata loanReceipt,
    uint256 repaymentAmount
  ) public {
    morpho.flashLoan(
      address(usdc),
      repaymentAmount,
      bytes()
    );
  }

  function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
    require(msg.sender == address(morpho));
  }
}
