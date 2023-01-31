// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./interfaces/IErrorsTokenomics.sol";
import "./interfaces/IGenericBondCalculator.sol";
import "./interfaces/IToken.sol";
import "./interfaces/ITokenomics.sol";
import "./interfaces/ITreasury.sol";

/*
* In this contract we consider OLAS tokens. The initial numbers will be as follows:
*  - For the first 10 years there will be the cap of 1 billion (1e27) tokens;
*  - After 10 years, the inflation rate is capped at 2% per year.
* Starting from a year 11, the maximum number of tokens that can be reached per the year x is 1e27 * (1.02)^x.
* To make sure that a unit(n) does not overflow the total supply during the year x, we have to check that
* 2^n - 1 >= 1e27 * (1.02)^x. We limit n by 96, thus it would take 220+ years to reach that total supply.
*
* We then limit each time variable to last until the value of 2^32 - 1 in seconds.
* 2^32 - 1 gives 136+ years counted in seconds starting from the year 1970.
* Thus, this counter is safe until the year 2106.
*
* The number of blocks cannot be practically bigger than the number of seconds, since there is more than one second
* in a block. Thus, it is safe to assume that uint32 for the number of blocks is also sufficient.
*
* In conclusion, this contract is only safe to use until 2106.
*/

/// @title Bond Depository - Smart contract for OLAS Bond Depository
/// @author AL
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
contract Depository is IErrorsTokenomics {
    event OwnerUpdated(address indexed owner);
    event TokenomicsUpdated(address indexed tokenomics);
    event TreasuryUpdated(address indexed treasury);
    event CreateBond(address indexed token, uint256 productId, uint256 amountOLAS, uint256 tokenAmount);
    event CreateProduct(address indexed token, uint256 productId, uint256 supply);
    event CloseProduct(address indexed token, uint256 productId);

    // The size of the struct is 160 + 96 + 32 * 2 + 8 = 328 bits (2 full slots)
    struct Bond {
        // Account address
        address account;
        // OLAS remaining to be paid out
        // After 10 years, the OLAS inflation rate is 2% per year. It would take 220+ years to reach 2^96 - 1
        uint96 payout;
        // Bond maturity time
        // 2^32 - 1 is enough to count 136 years starting from the year of 1970. This counter is safe until the year of 2106
        uint32 maturity;
        // Product Id of a bond
        // We assume that the number of products will not be bigger than the number of seconds
        uint32 productId;
    }

    // The size of the struct is 224 + 32 + 160 + 96 = 512 bits (2 full slots)
    struct Product {
        // priceLP (reserve0 / totalSupply or reserve1 / totalSupply) with 18 additional decimals
        // priceLP = 2 * r0/L * 10^18 = 2*r0*10^18/sqrt(r0*r1) ~= 61 + 96 - sqrt(96 * 112) ~= 53 bit (if LP is balanced)
        // or 2* r0/sqrt(r0) * 10^18 => 87 bit + 60 bit = 147 bit (if LP is unbalanced)
        uint224 priceLP;
        // Product expiry time (initialization time + vesting time)
        // 2^32 - 1 is enough to count 136 years starting from the year of 1970. This counter is safe until the year of 2106
        uint32 expiry;
        // Token to accept as a payment
        address token;
        // Supply of remaining OLAS tokens
        // After 10 years, the OLAS inflation rate is 2% per year. It would take 220+ years to reach 2^96 - 1
        uint96 supply;
    }

    // TODO finalize the value and also define the value of MAX_VESTING
    // Minimum bond vesting value
    uint256 public constant MIN_VESTING = 1 weeks;
    
    // Owner address
    address public owner;
    // Individual bond counter
    // We assume that the number of bonds will not be bigger than the number of seconds
    uint32 public bondCounter;
    // Bond product counter
    // We assume that the number of products will not be bigger than the number of seconds
    uint32 public productCounter;
    // Reentrancy lock
    uint8 internal _locked;

    // OLAS token address
    address public olas;
    // Tkenomics contract address
    address public tokenomics;
    // Treasury contract address
    address public treasury;
    // Bond Calculator contract address
    address public bondCalculator;

    // Mapping of bond Id => account bond instance
    mapping(uint256 => Bond) public mapUserBonds;
    // Mapping of product Id => bond product instance
    mapping(uint256 => Product) public mapBondProducts;

    /// @dev Depository constructor.
    /// @param _olas OLAS token address.
    /// @param _treasury Treasury address.
    /// @param _tokenomics Tokenomics address.
    constructor(address _olas, address _tokenomics, address _treasury, address _bondCalculator)
    {
        owner = msg.sender;
        _locked = 1;

        // Check for at least one zero contract address
        if (_olas == address(0) || _tokenomics == address(0) || _treasury == address(0) || _bondCalculator == address(0)) {
            revert ZeroAddress();
        }
        olas = _olas;
        tokenomics = _tokenomics;
        treasury = _treasury;
        bondCalculator = _bondCalculator;
    }

    /// @dev Changes the owner address.
    /// @param newOwner Address of a new owner.
    /// #if_succeeds {:msg "Changing owner"} old(owner) == msg.sender ==> owner == newOwner;
    function changeOwner(address newOwner) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for the zero address
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }

        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    /// @dev Changes various managing contract addresses.
    /// @param _tokenomics Tokenomics address.
    /// @param _treasury Treasury address.
    /// #if_succeeds {:msg "tokenomics changed"} _tokenomics != address(0) ==> tokenomics == _tokenomics;
    /// #if_succeeds {:msg "treasury changed"} _treasury != address(0) ==> treasury == _treasury;
    function changeManagers(address _tokenomics, address _treasury) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Change Tokenomics contract address
        if (_tokenomics != address(0)) {
            tokenomics = _tokenomics;
            emit TokenomicsUpdated(_tokenomics);
        }
        // Change Treasury contract address
        if (_treasury != address(0)) {
            treasury = _treasury;
            emit TreasuryUpdated(_treasury);
        }
    }

    /// @dev Changes Bond Calculator contract address
    /// #if_succeeds {:msg "bondCalculator changed"} _bondCalculator != address(0) ==> bondCalculator == _bondCalculator;
    function changeBondCalculator(address _bondCalculator) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (_bondCalculator != address(0)) {
            bondCalculator = _bondCalculator;
        }
    }

    /// @dev Deposits tokens in exchange for a bond from a specified product.
    /// @param productId Product Id.
    /// @param tokenAmount Token amount to deposit for the bond.
    /// @return payout The amount of OLAS tokens due.
    /// @return expiry Timestamp for payout redemption.
    /// @return bondId Id of a newly created bond.
    /// #if_succeeds {:msg "token is valid"} mapBondProducts[productId].token != address(0);
    /// #if_succeeds {:msg "input supply is non-zero"} old(mapBondProducts[productId].supply) > 0 && mapBondProducts[productId].supply <= type(uint96).max;
    /// #if_succeeds {:msg "expiry is non-zero"} mapBondProducts[productId].expiry > 0 && mapBondProducts[productId].expiry <= type(uint32).max;
    /// #if_succeeds {:msg "bond Id"} bondCounter == old(bondCounter) + 1 && bondCounter <= type(uint32).max;
    /// #if_succeeds {:msg "payout"} old(mapBondProducts[productId].supply) == mapBondProducts[productId].supply + payout;
    /// #if_succeeds {:msg "OLAS balances"} IToken(mapBondProducts[productId].token).balanceOf(treasury) == old(IToken(mapBondProducts[productId].token).balanceOf(treasury)) + tokenAmount;
    function deposit(uint256 productId, uint256 tokenAmount) external
        returns (uint256 payout, uint256 expiry, uint256 bondId)
    {
        // Check the token amount
        if (tokenAmount == 0) {
            revert ZeroValue();
        }

        // Get the bonding product
        Product storage product = mapBondProducts[productId];

        // Get the LP token address
        address token = product.token;

        // Check for the product expiry
        // Note that if the token or productId are invalid, the expiry will be zero by default and revert the function
        expiry = product.expiry;
        if (expiry < block.timestamp) {
            revert ProductExpired(token, productId, product.expiry, block.timestamp);
        }

        // Calculate the payout in OLAS tokens based on the LP pair with the discount factor (DF) calculation
        // Note that payout cannot be zero since the price LP is non-zero, otherwise the product would not be created
        payout = IGenericBondCalculator(bondCalculator).calculatePayoutOLAS(tokenAmount, product.priceLP);

        // Check for the sufficient supply
        uint256 supply = product.supply;
        if (payout > supply) {
            revert ProductSupplyLow(token, productId, payout, supply);
        }

        // Decrease the supply for the amount of payout
        supply -= payout;
        product.supply = uint96(supply);

        // Create and add a new bond, update the bond counter
        bondId = bondCounter;
        mapUserBonds[bondId] = Bond(msg.sender, uint96(payout), uint32(expiry), uint32(productId));
        bondCounter = uint32(bondId + 1);

        // Deposit that token amount to mint OLAS tokens in exchange
        ITreasury(treasury).depositTokenForOLAS(msg.sender, tokenAmount, token, payout);

        emit CreateBond(token, productId, payout, tokenAmount);
    }

    /// @dev Redeem account bonds.
    /// @param bondIds Bond Ids to redeem.
    /// @return payout Total payout sent in OLAS tokens.
    /// #if_succeeds {:msg "payout > 0"} payout > 0;
    /// #if_succeeds {:msg "msg.sender is the only owner"} old(forall (uint k in bondIds) mapUserBonds[bondIds[k]].account == msg.sender);
    /// #if_succeeds {:msg "accounts deleted"} forall (uint k in bondIds) mapUserBonds[bondIds[k]].account == address(0);
    /// #if_succeeds {:msg "payouts are zeroed"} forall (uint k in bondIds) mapUserBonds[bondIds[k]].payout == 0;
    /// #if_succeeds {:msg "maturities are zeroed"} forall (uint k in bondIds) mapUserBonds[bondIds[k]].maturity == 0;
    function redeem(uint256[] memory bondIds) public returns (uint256 payout) {
        for (uint256 i = 0; i < bondIds.length; i++) {
            // Get the amount to pay and the maturity status
            uint256 pay = mapUserBonds[bondIds[i]].payout;
            bool matured = block.timestamp >= mapUserBonds[bondIds[i]].maturity;

            // Revert if the bond does not exist or is not matured yet
            if (pay == 0 || !matured) {
                revert BondNotRedeemable(bondIds[i]);
            }

            // Check that the msg.sender is the owner of the bond
            if (mapUserBonds[bondIds[i]].account != msg.sender) {
                revert OwnerOnly(msg.sender, mapUserBonds[bondIds[i]].account);
            }

            // Get the productId for its status check
            uint256 productId = mapUserBonds[bondIds[i]].productId;

            // Close the program if it was not yet closed
            if (mapBondProducts[productId].expiry > 0) {
                uint256 supply = mapBondProducts[productId].supply;
                // Refund unused OLAS supply from the program if not used completely
                if (supply > 0) {
                    ITokenomics(tokenomics).refundFromBondProgram(supply);
                }
                address token = mapBondProducts[productId].token;
                delete mapBondProducts[productId];

                emit CloseProduct(token, productId);
            }
            // Increase the payout
            payout += pay;
            // Delete the Bond struct and release the gas
            delete mapUserBonds[bondIds[i]];
        }

        // Check for the non-zero payout
        if (payout == 0) {
            revert ZeroValue();
        }
        // No reentrancy risk here since it's the last operation, and originated from the OLAS token
        // No need to check for the return value, since it either reverts or returns true, see the ERC20 implementation
        IToken(olas).transfer(msg.sender, payout);
    }

    /// @dev Gets bond Ids of all pending bonds for the account address.
    /// @param account Account address to query bonds for.
    /// @param matured Flag to record matured bonds only or all of them.
    /// @return bondIds Pending bond Ids.
    /// @return payout Cumulative expected OLAS payout.
    /// #if_succeeds {:msg "matured bonds"} matured == true ==> forall (uint k in bondIds)
    /// mapUserBonds[bondIds[k]].account == account && block.timestamp >= mapUserBonds[bondIds[k]].maturity;
    function getPendingBonds(address account, bool matured) external view
        returns (uint256[] memory bondIds, uint256 payout)
    {
        // Check the address
        if (account == address(0)) {
            revert ZeroAddress();
        }

        uint256 numAccountBonds;
        // Calculate the number of pending bonds
        uint256 numBonds = bondCounter;
        bool[] memory positions = new bool[](numBonds);
        // Record the bond number if it belongs to the account address and was not yet redeemed
        for (uint256 i = 0; i < numBonds; i++) {
            // Check if the bond belongs to the account
            // If not and the address is zero, the bond was redeemed or never existed
            if (mapUserBonds[i].account == account) {
                // Check if requested bond is not matured but owned by the account address
                if (!matured ||
                    // Or if the requested bond is matured, i.e., the bond maturity timestamp passed
                    block.timestamp >= mapUserBonds[i].maturity)
                {
                    positions[i] = true;
                    ++numAccountBonds;
                    // The payout is always bigger than zero if the bond exists
                    payout += mapUserBonds[i].payout;
                }
            }
        }

        // Form pending bonds index array
        bondIds = new uint256[](numAccountBonds);
        uint256 numPos;
        for (uint256 i = 0; i < numBonds; i++) {
            if (positions[i]) {
                bondIds[numPos] = i;
                ++numPos;
            }
        }
    }

    /// @dev Calculates the maturity and payout to claim for a single bond.
    /// @param bondId The account bond Id.
    /// @return payout The payout amount in OLAS.
    /// @return matured True if the payout can be redeemed.
    function getBondStatus(uint256 bondId) external view returns (uint256 payout, bool matured) {
        payout = mapUserBonds[bondId].payout;
        // If payout is zero, the bond has been redeemed or never existed
        if (payout > 0) {
            matured = block.timestamp >= mapUserBonds[bondId].maturity;
        }
    }

    /// @dev Creates a new bond product.
    /// @param token LP token to be deposited for pairs like OLAS-DAI, OLAS-ETH, etc.
    /// @param priceLP LP token price with 18 additional decimals.
    /// @param supply Supply in OLAS tokens.
    /// @param vesting Vesting period (in seconds).
    /// @return productId New bond product Id.
    /// #if_succeeds {:msg "productCounter increases"} productCounter == old(productCounter) + 1;
    /// #if_succeeds {:msg "isActive"} mapBondProducts[productId].supply > 0 && mapBondProducts[productId].expiry == block.timestamp + vesting;
    function create(address token, uint256 priceLP, uint256 supply, uint256 vesting) external returns (uint256 productId) {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for the pool liquidity as the LP price being greater than zero
        if (priceLP == 0) {
            revert ZeroValue();
        }

        // Check that the supply is greater than zero
        if (supply == 0) {
            revert ZeroValue();
        }

        // Check the supply limit value
        if (supply > type(uint96).max) {
            revert Overflow(supply, type(uint96).max);
        }

        // Check the vesting minimum limit value
        if (vesting < MIN_VESTING) {
            revert LowerThan(vesting, MIN_VESTING);
        }

        // Check for the expiration time overflow
        uint256 expiry = block.timestamp + vesting;
        if (expiry > type(uint32).max) {
            revert Overflow(expiry, type(uint32).max);
        }
        
        // Check if the LP token is enabled
        if (!ITreasury(treasury).isEnabled(token)) {
            revert UnauthorizedToken(token);
        }

        // Check if the bond amount is beyond the limits
        if (!ITokenomics(tokenomics).reserveAmountForBondProgram(supply)) {
            revert LowerThan(ITokenomics(tokenomics).effectiveBond(), supply);
        }

        // Push newly created bond product into the list of products
        productId = productCounter;
        mapBondProducts[productId] = Product(uint224(priceLP), uint32(expiry), token, uint96(supply));
        // Even if we create a bond product every second, 2^32 - 1 is enough for the next 136 years
        productCounter = uint32(productId + 1);
        emit CreateProduct(token, productId, supply);
    }

    /// @dev Close bonding products.
    /// @notice This will terminate the program regardless of the expiration time.
    /// @param productIds Set of product Ids.
    /// #if_succeeds {:msg "productCounter not touched"} productCounter == old(productCounter);
    /// #if_succeeds {:msg "success closed"} forall (uint k in productIds) mapBondProducts[productIds[k]].expiry == 0 && mapBondProducts[productIds[k]].supply == 0;
    function close(uint256[] memory productIds) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        for (uint256 i = 0; i < productIds.length; ++i) {
            uint256 productId = productIds[i];
            // Check if the product is still open
            if (mapBondProducts[productId].expiry == 0) {
                revert ProductClosed(productId);
            }

            uint256 supply = mapBondProducts[productId].supply;
            // Refund unused OLAS supply from the program if not used completely
            if (supply > 0) {
                ITokenomics(tokenomics).refundFromBondProgram(supply);
            }
            address token = mapBondProducts[productId].token;
            delete mapBondProducts[productId];

            emit CloseProduct(token, productId);
        }
    }

    /// @dev Gets activity information about a given product.
    /// @param productId Product Id.
    /// @return status True if the product is active.
    function isActiveProduct(uint256 productId) external view returns (bool status) {
        status = (mapBondProducts[productId].supply > 0 && mapBondProducts[productId].expiry > block.timestamp);
    }

    /// @dev Gets an array of all active product Ids for a specific token.
    /// @param active Flag to select active or inactive products.
    /// @return productIds Active product Ids.
    function getProducts(bool active) external view returns (uint256[] memory productIds) {
        // Calculate the number of active products
        uint256 numProducts = productCounter;
        bool[] memory positions = new bool[](numProducts);
        uint256 numSelectedProducts;
        if (active) {
            for (uint256 i = 0; i < numProducts; i++) {
                if (mapBondProducts[i].supply > 0 && mapBondProducts[i].expiry > block.timestamp) {
                    positions[i] = true;
                    ++numSelectedProducts;
                }
            }
        } else {
            for (uint256 i = 0; i < numProducts; i++) {
                if (mapBondProducts[i].token != address(0) && mapBondProducts[i].expiry <= block.timestamp) {
                    positions[i] = true;
                    ++numSelectedProducts;
                }
            }
        }

        // Form the active products index array
        productIds = new uint256[](numSelectedProducts);
        uint256 numPos;
        for (uint256 i = 0; i < numProducts; i++) {
            if (positions[i]) {
                productIds[numPos] = i;
                ++numPos;
            }
        }
        return productIds;
    }

    /// @dev Gets current reserves of OLAS / totalSupply of LP tokens.
    /// @param token Token address.
    /// @return priceLP Resulting reserveX / totalSupply ratio with 18 decimals.
    function getCurrentPriceLP(address token) external view returns (uint256 priceLP) {
        return IGenericBondCalculator(bondCalculator).getCurrentPriceLP(token);
    }
}
