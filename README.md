1. (Relative Stability) Pegged -> $1.00 
    - Achieved via Chainlink Price Feed.
    - Set a function to exchange ETH & BTC for their $ equivalent.
2. Stability Mechanism (Minting): Algorithmic (Decentralised)
    - People can only mint the stablecoin if they have enough collateral (programatic)
3. Collateral Type: Exogenous (Crypto)
    - ETH (Probably WETH)
    - BTC (Probably WBTC)


## Developing the DSC Engine
We begin by defining the functions / interface the contract should adhere to.
```
function depositCollateralAndMintDsc() external {}
function depositCollateral() external {}
function redeemCollateralForDsc() external {}
function redeemCollateral() external {}
function mintDsc() external {}
function burnDsc() external {}
function liquidate() external {}
function getHealthFactor() external view {}
```

The first thing the user would do is deposit collateral:
- Parameters:
    1. `address` of token being deposited as collateral
    2. `amount` of collateral to deposit. [Must be greater than zero]
- Considerations: 
    1. We should ideally be keeping track of "for a given token used as collateral how much has the user provided".
    2. How can we get the real-time USD value of the users deposited collateral: Chainlink Pricefeeds. (PriceFeeds have their own address, we would need to map the collateralTokenAddress to the priceFeedAdress)
    3. We should not accept all collateral only WETH & WBTC, so we must ensure we are only able to accept two types of collateral and keep track of this. (use constructor to set this up.)
