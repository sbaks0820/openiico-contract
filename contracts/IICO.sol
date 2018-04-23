/** @title Interactive Coin Offering
 *  @author Clément Lesaege - <clement@lesaege.com>
 */

pragma solidity ^0.4.18;

import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";

/** @title Interactive Coin Offering
 *  This contract implements the Interactive Coin Offering token sale as described in this paper:
 *  https://people.cs.uchicago.edu/~teutsch/papers/ico.pdf
 *  Implementation details and modifications compared to the paper:
 *  -A fixed amount of tokens is sold. This allows more flexibility for the distribution of the remaining tokens (rounds, team tokens which can be preallocated, non-initial sell of some cryptographic assets).
 *  -The valuation pointer is only moved when the sale is over. This greatly reduces the amount of write operations and code complexity. However, at least one party must make one or multiple calls to finalize the sale.
 *  -Buckets are not used as they are not required and increase code complexity.
 *  -The bid submitter must provide the insertion spot. A search of the insertion spot is still done in the contract just in case the one provided was wrong or other bids were added between when the TX got signed and executed, but giving the search starting point greatly lowers gas consumption.
 *  -Automatic withdrawals are only possible at the end of the sale. This decreases code complexity and possible interactions between different parts of the code.
 *  -We put a full bonus, free withdrawal period at the beginning. This allows everyone to have a chance to place bids with full bonus and avoids clogging the network just after the sale starts. Note that at this moment, no information can be taken for granted as parties can withdraw freely.
 *  -Calling the fallback function while sending ETH places a bid with an infinite maximum valuation. This allows buyers who want to buy no matter the price not need to use a specific interface and just send ETH. Without ETH, a call to the fallback function redeems the bids of the caller.
 */
contract IICO {

    /* *** General *** */
    address public owner;       // The one setting up the contract.
    address public beneficiary; // The address which will get the funds.

    /* *** Bid *** */
    uint constant HEAD = 0;            // Minimum value used for both the maxVal and bidID of the head of the linked list.
    uint constant TAIL = uint(-1);     // Maximum value used for both the maxVal and bidID of the tail of the linked list.
    uint constant INFINITY = uint(-2); // A value so high that a bid using it is guaranteed to succeed. Still lower than TAIL to be placed before TAIL.
    // A bid to buy tokens as long as the personal maximum valuation is not exceeded.
    // Bids are in a sorted doubly linked list.
    // They are sorted in ascending order by (maxVal,bidID) where bidID is the ID and key of the bid in the mapping.
    // The list contains two artificial bids HEAD and TAIL having respectively the minimum and maximum bidID and maxVal.
    struct Bid {
        /* *** Linked List Members *** */
        uint prev;            // bidID of the previous element.
        uint next;            // bidID of the next element.
        /* ***     Bid Members     *** */
        uint maxVal;          // Maximum valuation in wei beyond which the contributor prefers refund.
        uint contrib;         // Contribution in wei.
        uint bonus;           // The numerator of the bonus that will be divided by BONUS_DIVISOR.
        address contributor;  // The contributor who placed the bid.
        bool withdrawn;       // True if the bid has been withdrawn.
        bool redeemed;        // True if the ETH or tokens have been redeemed.
    }
    mapping (uint => Bid) public bids; // Map bidID to bid.
    mapping (address => uint[]) public contributorBidIDs; // Map contributor to a list of its bid ID.
    uint public lastBidID = 0; // The last bidID not accounting TAIL.

    /* *** Sale parameters *** */
    uint public startTime;                      // When the sale starts.
    uint public endFullBonusTime;               // When the full bonus period ends.
    uint public withdrawalLockTime;             // When the contributors can't withdraw their bids manually anymore.
    uint public endTime;                        // When the sale ends.
    ERC20 public token;                         // The token which is sold.
    uint public tokensForSale;                  // The amount of tokens which will be sold.
    uint public maxBonus;                       // The maximum bonus. Will be normalized by BONUS_DIVISOR. For example for a 20% bonus, _maxBonus must be 0.2 * BONUS_DIVISOR.
    uint constant BONUS_DIVISOR = 1E9;          // The quantity we need to divide by to normalize the bonus.

    /* *** Finalization variables *** */
    bool public finalized;                 // True when the cutting bid has been found. The following variables are final only after finalized==true.
    uint public cutOffBidID = TAIL;        // The first accepted bid. All bids after it are accepted.
    uint public sumAcceptedContrib;        // The sum of accepted contributions.
    uint public sumAcceptedVirtualContrib; // The sum of virtual (taking into account bonuses) contributions.

    modifier onlyOwner{ require(owner == msg.sender); _; }

    /* *** Functions Modifying the state *** */

    /** @dev Constructor. First contract set up (tokens will also need to be transferred to the contract and then setToken needs to be called to finish the setup).
     *  @param _startTime Time the sale will start in seconds since the Unix Epoch.
     *  @param _fullBonusLength Amount of seconds the sale lasts in the full bonus period.
     *  @param _partialWithdrawalLength Amount of seconds the sale lasts in the partial withdrawal period.
     *  @param _withdrawalLockUpLength Amount of seconds the sale lasts in the withdrawal lockup period.
     *  @param _maxBonus The maximum bonus. Will be normalized by BONUS_DIVISOR. For example for a 20% bonus, _maxBonus must be 0.2 * BONUS_DIVISOR.
     *  @param _beneficiary The party which will get the funds of the token sale.
     */
    function IICO(uint _startTime, uint _fullBonusLength, uint _partialWithdrawalLength, uint _withdrawalLockUpLength, uint _maxBonus, address _beneficiary) public {
        owner = msg.sender;
        startTime = _startTime;
        endFullBonusTime = startTime + _fullBonusLength;
        withdrawalLockTime = endFullBonusTime + _partialWithdrawalLength;
        endTime = withdrawalLockTime + _withdrawalLockUpLength;
        maxBonus = _maxBonus;
        beneficiary = _beneficiary;

        // Add the virtual bids. This simplifies other functions.
        bids[HEAD] = Bid({
            prev: TAIL,
            next: TAIL,
            maxVal: HEAD,
            contrib: 0,
            bonus: 0,
            contributor: 0x0,
            withdrawn: false,
            redeemed: false
        });
        bids[TAIL] = Bid({
            prev: HEAD,
            next: HEAD,
            maxVal: TAIL,
            contrib: 0,
            bonus: 0,
            contributor: 0x0,
            withdrawn: false,
            redeemed: false
        });
    }

    /** @dev Set the token. Must only be called after the IICO contract receives the tokens to be sold.
     *  @param _token The token to be sold.
     */
    function setToken(ERC20 _token) public onlyOwner {
        require(address(token) == 0x0);

        token = _token;
        tokensForSale = token.balanceOf(this);
    }

    /** @dev Submit a bid. The caller must give the exact position the bid must be inserted into in the list.
     *  In practice, use searchAndBid to avoid the position being incorrect due to a new bid being inserted and changing the position the bid must be inserted at.
     *  @param _maxVal The maximum valuation given by the contributor. If the amount raised is higher, the bid is cancelled and the contributor refunded because it prefers a refund instead of this level of dilution. To buy no matter what, use INFINITY.
     *  @param _next The bidID of the next bid in the list.
     */
    function submitBid(uint _maxVal, uint _next) public payable {
        Bid storage nextBid = bids[_next];
        uint prev = nextBid.prev;
        Bid storage prevBid = bids[prev];
        require(_maxVal >= prevBid.maxVal && _maxVal < nextBid.maxVal); // The new bid maxVal is higher than the previous one and strictly lower than the next one.
        require(now >= startTime && now < endTime); // Check that the bids are still open.

        ++lastBidID; // Increment the lastBidID. It will be the new bid's ID.
        // Update the pointers of neighboring bids.
        prevBid.next = lastBidID;
        nextBid.prev = lastBidID;

        // Insert the bid.
        bids[lastBidID] = Bid({
            prev: prev,
            next: _next,
            maxVal: _maxVal,
            contrib: msg.value,
            bonus: bonus(),
            contributor: msg.sender,
            withdrawn: false,
            redeemed: false
        });

        // Add the bid to the list of bids by this contributor.
        contributorBidIDs[msg.sender].push(lastBidID);
    }


    /** @dev Search for the correct insertion spot and submit a bid.
     *  This function is O(n), where n is the amount of bids between the initial search position and the insertion position.
     *  The UI must first call search to find the best point to start the search so it consumes the least amount of gas possible.
     *  Using this function instead of calling submitBid directly prevents it from failing in the case where new bids are added before the transaction is executed.
     *  @param _maxVal The maximum valuation given by the contributor. If the amount raised is higher, the bid is cancelled and the contributor refunded because it prefers a refund instead of this level of dilution. To buy no matter what, use INFINITY.
     *  @param _next The bidID of the next bid in the list.
     */
    function searchAndBid(uint _maxVal, uint _next) public payable {
        submitBid(_maxVal, search(_maxVal,_next));
    }

    /** @dev Withdraw a bid. Can only be called before the end of the withdrawal lock period.
     *  Withdrawing a bid divides its bonus by 3.
     *  For retrieving ETH after an automatic withdrawal, use the redeem function.
     *  @param _bidID The ID of the bid to withdraw.
     */
    function withdraw(uint _bidID) public {
        Bid storage bid = bids[_bidID];
        require(msg.sender == bid.contributor);
        require(now < withdrawalLockTime);
        require(!bid.withdrawn);

        bid.withdrawn = true;

        // Before endFullBonusTime, everything is refunded. Otherwise, an amount decreasing linearly from endFullBonusTime to withdrawalLockTime is refunded.
        uint refund = (now < endFullBonusTime) ? bid.contrib : (bid.contrib * (withdrawalLockTime - now)) / (withdrawalLockTime - endFullBonusTime);
        assert(refund <= bid.contrib); // Make sure that we don't refund more than the contribution. Would a bug arise, we prefer blocking withdrawal than letting someone steal money.
        bid.contrib -= refund;
        bid.bonus /= 3; // Divide the bonus by 3.

        msg.sender.transfer(refund);
    }

    /** @dev Finalize by finding the cut-off bid.
     *  Since the amount of bids is not bounded, this function may have to be called multiple times.
     *  The function is O(min(n,_maxIt)) where n is the amount of bids. In total it will perform O(n) computations, possibly in multiple calls.
     *  Each call only has a O(1) storage write operations.
     *  @param _maxIt The maximum amount of bids to go through. This value must be set in order to not exceed the gas limit.
     */
    function finalize(uint _maxIt) public {
        require(now >= endTime);
        require(!finalized);

        // Make local copies of the finalization variables in order to avoid modifying storage in order to save gas.
        uint localCutOffBidID = cutOffBidID;
        uint localSumAcceptedContrib = sumAcceptedContrib;
        uint localSumAcceptedVirtualContrib = sumAcceptedVirtualContrib;

        // Search for the cut-off bid while adding the contributions.
        for (uint it = 0; it < _maxIt && !finalized; ++it) {
            Bid storage bid = bids[localCutOffBidID];
            if (bid.contrib+localSumAcceptedContrib < bid.maxVal) { // We haven't found the cut-off yet.
                localSumAcceptedContrib        += bid.contrib;
                localSumAcceptedVirtualContrib += bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR;
                localCutOffBidID = bid.prev; // Go to the previous bid.
            } else { // We found the cut-off. This bid will be taken partially.
                finalized = true;
                uint contribCutOff = bid.maxVal >= localSumAcceptedContrib ? bid.maxVal - localSumAcceptedContrib : 0; // The amount of the contribution of the cut-off bid that can stay in the sale without spilling over the maxVal.
                contribCutOff = contribCutOff < bid.contrib ? contribCutOff : bid.contrib; // The amount that stays in the sale should not be more than the original contribution. This line is not required but it is added as an extra security measure.
                bid.contributor.send(bid.contrib-contribCutOff); // Send the non-accepted part. Use send in order to not block if the contributor's fallback reverts.
                bid.contrib = contribCutOff; // Update the contribution value.
                localSumAcceptedContrib += bid.contrib;
                localSumAcceptedVirtualContrib += bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR;
                beneficiary.send(localSumAcceptedContrib); // Use send in order to not block if the contributor's fallback reverts.
            }
        }

        // Update storage.
        cutOffBidID = localCutOffBidID;
        sumAcceptedContrib = localSumAcceptedContrib;
        sumAcceptedVirtualContrib = localSumAcceptedVirtualContrib;
    }

    /** @dev Redeem a bid. If the bid is accepted, send the tokens, otherwise refund the ETH.
     *  Note that anyone can call this function, not only the party which made the bid.
     *  @param _bidID ID of the bid to withdraw.
     */
    function redeem(uint _bidID) public {
        Bid storage bid = bids[_bidID];
        Bid storage cutOffBid = bids[cutOffBidID];
        require(finalized);
        require(!bid.redeemed);

        bid.redeemed=true;
        if (bid.maxVal > cutOffBid.maxVal || (bid.maxVal == cutOffBid.maxVal && _bidID >= cutOffBidID)) // Give tokens if the bid is accepted.
            token.transfer(bid.contributor, (tokensForSale * (bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR)) / sumAcceptedVirtualContrib);
        else                                                                                            // Reimburse ETH otherwise.
            bid.contributor.transfer(bid.contrib);
    }

    /** @dev Fallback. Make a bid if ETH are sent. Redeem all the bids of the contributor otherwise.
     *  This allows users to bid and get their tokens back using only send operations.
     */
    function () public payable {
        if (msg.value != 0 && now >= startTime && now < endTime) // Make a bid with an infinite maxVal if some ETH was sent.
            submitBid(INFINITY, TAIL);
        else if (msg.value == 0 && finalized)                    // Else, redeem all the non redeemed bids if no ETH was sent.
            for (uint i = 0; i < contributorBidIDs[msg.sender].length; ++i)
                if (!bids[contributorBidIDs[msg.sender][i]].redeemed)
                    redeem(contributorBidIDs[msg.sender][i]);
        else                                                     // Otherwise, no actions are possible.
            revert();
    }

    /* *** Constant and View *** */

    /** @dev Search for the correct insertion spot of a bid.
     *  This function is O(n), where n is the amount of bids between the initial search position and the insertion position.
     *  @param _maxVal The maximum valuation given by the contributor. Or INFINITY if no maximum valuation is given.
     *  @param _nextStart The bidID of the next bid from the initial position to start the search from.
     *  @return nextInsert The bidID of the next bid from the position the bid must be inserted at.
     */
    function search(uint _maxVal, uint _nextStart) constant public returns(uint nextInsert) {
        uint next = _nextStart;
        bool found;

        while(!found) { // While we aren't at the insertion point.
            Bid storage nextBid = bids[next];
            uint prev = nextBid.prev;
            Bid storage prevBid = bids[prev];

            if (_maxVal < prevBid.maxVal)       // It should be inserted before.
                next = prev;
            else if (_maxVal >= nextBid.maxVal) // It should be inserted after. The second value we sort by is bidID. Those are increasing, thus if the next bid is of the same maxVal, we should insert after it.
                next = nextBid.next;
            else                                // We found the insertion point.
                found = true;
        }

        return next;
    }

    /** @dev Return the current bonus. The bonus only changes in 1/BONUS_DIVISOR increments.
     *  @return b The bonus expressed in 1/BONUS_DIVISOR. Will be normalized by BONUS_DIVISOR. For example for a 20% bonus, _maxBonus must be 0.2 * BONUS_DIVISOR.
     */
    function bonus() public constant returns(uint b) {
        if (now < endFullBonusTime) // Full bonus.
            return maxBonus;
        else if (now > endTime)     // Assume no bonus after end.
            return 0;
        else                        // Compute the bonus decreasing linearly from endFullBonusTime to endTime.
            return (maxBonus * (endTime - now)) / (endTime - endFullBonusTime);
    }

    /** @dev Get the total contribution of an address.
     *  This can be used for a KYC threshold.
     *  This function is O(n) where n is the amount of bids made by the contributor.
     *  This means that the contributor can make totalContrib(contributor) revert due to an out of gas error on purpose.
     *  @param _contributor The contributor whose contribution will be returned.
     *  @return contribution The total contribution of the contributor.
     */
    function totalContrib(address _contributor) public constant returns (uint contribution) {
        for (uint i = 0; i < contributorBidIDs[_contributor].length; ++i)
            contribution += bids[contributorBidIDs[_contributor][i]].contrib;
    }

    /* *** Interface Views *** */

    /**
     * @dev Get the current valuation and the amount of ETH committed to the sale.
     * @return The current valuation and the amount of ETH committed to the sale.
     */
    function valuationAndAmountCommitted() public view returns (uint valuation, uint amountCommitted, uint virtualValuation) {
        bool capped = false;
        uint localCutOffBidID = bids[TAIL].prev;

        // Loop over all bids
        while (localCutOffBidID != TAIL) {
            Bid storage bid = bids[localCutOffBidID];
            if (!capped && (bid.contrib + valuation < bid.maxVal)) { // We haven't found the cut-off yet.
                valuation += bid.contrib;
                virtualValuation += bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR;
                amountCommitted += bid.contrib;
            } else { // We found the cut-off bid. This bid will be taken partially.
                valuation += bid.contrib;
                virtualValuation += bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR;
                if (!capped) {
                    uint contribCutOff = bid.maxVal >= valuation ? bid.maxVal - valuation : 0; // The amount of the contribution of the cut-off bid that can stay in the sale without spilling over the maxVal.
                    amountCommitted += contribCutOff;
                    capped = true;
                }
            }
            localCutOffBidID = bid.prev; // Go to the previous bid.
        }

        if (now < withdrawalLockTime) amountCommitted = 0;
    }
}
