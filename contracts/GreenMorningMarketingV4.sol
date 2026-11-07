// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IWrappedGM is IERC20 {function deposit() external payable;}
interface IV2FactoryGM {function getPair(address,address) external view returns(address);function createPair(address,address) external returns(address);}
interface IV2PairGM {
    function token0() external view returns(address);function token1() external view returns(address);function factory() external view returns(address);
    function getReserves() external view returns(uint112,uint112,uint32);function mint(address) external returns(uint256);
    function price0CumulativeLast() external view returns(uint256);function price1CumulativeLast() external view returns(uint256);
}
interface IV2RouterGM {
    function factory() external view returns(address);function WETH() external view returns(address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
}

/// @notice Burn-style issuance, public marketing accounting, fixed 2% pair tax.
/// @dev Owner-authorized UUPS upgrades can change future behavior; disclose ownership.
contract GreenMorningMarketingV4 is ERC20Upgradeable,Ownable2StepUpgradeable,UUPSUpgradeable {
    using SafeERC20 for IERC20;
    uint256 public constant MAX_LOTS=8888;
    uint256 public constant MAX_PER_TX=10;
    uint256 public constant BASE_QUOTA=10;
    uint256 public constant FIRST_TIER_LOTS=3000;
    uint256 public constant OPEN_AT=8888;
    uint256 public constant BASE_PRICE=0.003 ether;
    uint256 public constant incrementBps=1000; // Additive 10% of base, not compounded.
    uint256 public constant TAX_BPS=200;
    uint256 public constant MARKETING_PAYMENT_GAS=35000;
    uint256 public constant AUTO_SWAP_GAS=500000;
    uint256 public constant AUTO_SWAP_GAS_RESERVE=200000;
    uint256 public constant AUTO_SWAP_SLIPPAGE_BPS=100; // 1% below a guarded V2 quote.
    uint256 public constant MAX_AUTO_SWAP_RESERVE_BPS=10; // At most 0.1% of GM reserves.
    uint256 public constant MAX_MARKETING_BATCH=58_000_000 ether;
    // Preserve the V3 LP processing cap independently of the distribution of new tax.
    uint256 public constant MAX_AUTO_LP_BATCH=MAX_MARKETING_BATCH/12;
    uint256 public constant MIN_AUTO_LP_TOKENS=100_000 ether;
    uint256 public constant AUTO_LP_GAS=500000;
    uint256 public constant tokensPerLot=50_000_000 ether; // Before pool opening only.
    uint256 public constant liquidityTokensPerLot=35_000_000 ether; // Base-price seed allocation only.
    uint256 public constant SEED_TOKENS=105_000_000_000 ether; // Seed ratio numerator, not a fixed bootstrap amount.
    uint256 public constant SEED_WBNB=5.4 ether; // Seed ratio denominator.
    uint32 public constant ORACLE_WINDOW=30 minutes;
    uint256 private constant Q112=1<<112;
    address public constant DEAD=0x000000000000000000000000000000000000dEaD;
    address public router;
    address public pair;
    address public wrappedNative;
    address public marketingWallet;
    IERC721 public idCollection;
    mapping(address=>uint256) public mintedByWallet;
    mapping(uint256=>uint256) public mintedById;
    mapping(address=>uint256) public inviteBonusByWallet;
    mapping(uint256=>uint256) public inviteBonusById;
    mapping(address=>address) public referrerWallet;
    mapping(address=>uint256) public referrerId;
    mapping(address=>bool) public referralQualified;
    uint256 public marketingThreshold;
    uint256 public totalMintedLots;
    uint256 public pendingLiquidityTokens; // Unprocessed trading-tax LP allocation in GM.
    uint256 public pendingLiquidityBnb; // Held as WBNB, reserved for LP.
    uint256 public pendingMarketingTokens;
    uint256 public marketingCredits; // Native BNB owed across historical recipients.
    mapping(address=>uint256) public marketingCreditOf;
    uint256 public totalLiquidityBnbAdded;
    uint256 public totalLiquidityTokensAdded;
    uint256 public averageRateX112;
    uint256 private observationCumulative;
    uint32 private observationTime;
    bool public mintOpen;
    bool public opened;
    bool private gmIs0;
    bool private processing;
    uint256 private entered;
    // Append state in the reserved gap; preserve preceding UUPS storage positions.
    mapping(uint256=>address) public referrerWalletById;
    mapping(uint256=>uint256) public referrerIdById;
    mapping(uint256=>bool) public referralQualifiedById;
    uint256 public maxMarketingSwap;
    uint256[16] private __gap;
    /// @custom:storage-location erc7201:greenmorning.storage.MarketingCycle.v2
    struct MarketingCycleState {uint256 remaining;}
    bytes32 private constant MARKETING_CYCLE_SLOT=0x50b20b453119470e074d2714f5d57ae380fc55e108b56f5d4a0e437c09064100;
    /// @custom:storage-location erc7201:greenmorning.storage.TaxV3
    struct TaxV3State {bool initialized;uint256 legacyTokens;uint256 legacyWbnb;uint256 autoTokens;uint256 autoWbnb;}
    bytes32 private constant TAX_V3_SLOT=0x4394d6fadd669d724c595934bd72e86029c574445967c4b54cf52053c00da600;
    struct InitConfig {address owner;address router;address registry;address marketingWallet;uint256 marketingThreshold;uint256 maxMarketingSwap;}
    error InvalidInput();error MintClosed();error TradingNotOpen();error IncorrectPayment();error StaleQuote();error Slippage();
    error ReservePriceOutsideWindow();error ExternalCallFailed();error ReentrantCall();
    error AutoSwapGasBudget();
    event LotsMinted(address indexed buyer,uint256 firstLot,uint256 quantity,uint256 cost,uint256 tokens);
    event PoolOpened(address indexed pair,uint256 wrappedAmount,uint256 tokenAmount);
    event PoolOpenedEarly(uint256 lots,uint256 wrappedAmount,uint256 tokenAmount);
    event LiquidityAdded(uint256 tokensUsed,uint256 bnbUsed,uint256 lpTokens,address indexed recipient);
    event MarketingThresholdChanged(uint256 oldThreshold,uint256 newThreshold);
    event MaxMarketingSwapChanged(uint256 oldMaximum,uint256 newMaximum);
    event AutoMarketingProcessed(uint256 tokens,uint256 bnb);
    event AutoMarketingDeferred(uint256 pendingTokens);
    event AutoMarketingDeferredReason(uint256 pendingTokens,bytes4 reasonSelector);
    event MarketingCycleStarted(uint256 principal);
    event MarketingCycleProcessed(uint256 amount,uint256 remaining);
    event TaxV3Initialized(uint256 previousMarketing,uint256 reallocatedLp,uint256 burned,uint256 marketing,uint256 legacyLpTokens,uint256 legacyLpWbnb);
    event AutoLiquidityAdded(uint256 tokensSwapped,uint256 tokensAdded,uint256 wbnbAdded,uint256 lpMinted);
    event AutoLiquidityDeferred(uint256 queuedTokens,bytes4 reasonSelector);
    event MarketingWalletChanged(address indexed oldWallet,address indexed newWallet);
    event MarketingCredited(address indexed wallet,uint256 amount);
    event MarketingPaid(address indexed wallet,uint256 amount);
    event MarketingClaimed(address indexed wallet,uint256 amount);
    event MarketingTokensProcessed(uint256 tokens,uint256 bnb);
    event LiquidityTokensSwapped(uint256 tokens,uint256 bnb);
    event MintOpenChanged(bool open);
    /// @dev In V4, `burn` is GM credited to DEAD. This transfer preserves totalSupply.
    event TaxCollected(address indexed from,address indexed to,uint256 burn,uint256 liquidity,uint256 marketing);
    event InviteBound(address indexed invitee,address indexed inviter,uint256 indexed inviterId);
    event InviteCredited(address indexed invitee,address indexed inviter,uint256 indexed inviterId);
    event InviteBoundById(uint256 indexed inviteeId,address indexed inviter,uint256 indexed inviterId);
    event InviteCreditedById(uint256 indexed inviteeId,address indexed inviter,uint256 indexed inviterId);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(){_disableInitializers();}
    modifier nonReentrant(){if(entered==2)revert ReentrantCall();entered=2;_;entered=1;}
    function initialize(InitConfig calldata c) external initializer {
        if(c.owner==address(0)||c.router.code.length==0||c.registry.code.length==0||c.marketingWallet==address(0)||c.marketingWallet==address(this)||c.marketingThreshold==0||c.maxMarketingSwap==0)revert InvalidInput();
        __ERC20_init("GREEN MORNING","GM");__Ownable_init(c.owner);__Ownable2Step_init();
        router=c.router;marketingWallet=c.marketingWallet;marketingThreshold=c.marketingThreshold;entered=1;
        maxMarketingSwap=c.maxMarketingSwap;
        idCollection=IERC721(c.registry);
        address f=IV2RouterGM(c.router).factory();wrappedNative=IV2RouterGM(c.router).WETH();
        if(f.code.length==0||wrappedNative.code.length==0)revert InvalidInput();
        address p=IV2FactoryGM(f).getPair(address(this),wrappedNative);if(p==address(0))p=IV2FactoryGM(f).createPair(address(this),wrappedNative);
        if(p.code.length==0)revert InvalidInput();address t0=IV2PairGM(p).token0();address t1=IV2PairGM(p).token1();
        if(IV2PairGM(p).factory()!=f||!((t0==address(this)&&t1==wrappedNative)||(t1==address(this)&&t0==wrappedNative)))revert InvalidInput();
        pair=p;gmIs0=t0==address(this);
        if(c.marketingWallet==p||c.marketingWallet==c.router)revert InvalidInput();
    }
    function liquidityReceiver() external pure returns(address){return DEAD;}
    function _taxV3() private pure returns(TaxV3State storage state){bytes32 slot=TAX_V3_SLOT;assembly("memory-safe"){state.slot:=slot}}
    function taxV3Initialized() external view returns(bool){return _taxV3().initialized;}
    function autoLpTokens() external view returns(uint256){return _taxV3().autoTokens;}
    function autoLpWbnb() external view returns(uint256){return _taxV3().autoWbnb;}
    function legacyLpTokens() external view returns(uint256){return _taxV3().legacyTokens;}
    function legacyLpWbnb() external view returns(uint256){return _taxV3().legacyWbnb;}
    function taxV3Slot() external pure returns(bytes32){return TAX_V3_SLOT;}
    /// @notice Reclassifies ONLY the current marketing bucket once; old LP and extra GM remain untouched.
    function initializeTaxV3() external onlyOwner onlyProxy nonReentrant {
        TaxV3State storage state=_taxV3();if(state.initialized)revert InvalidInput();
        uint256 previous=pendingMarketingTokens;uint256 legacy=pendingLiquidityTokens;uint256 legacyNative=pendingLiquidityBnb;
        if(balanceOf(address(this))<previous+legacy||IERC20(wrappedNative).balanceOf(address(this))<legacyNative)revert InvalidInput();
        uint256 lp=Math.mulDiv(previous,5,100);uint256 burned=Math.mulDiv(previous,35,100);uint256 marketing=previous-lp-burned;
        state.initialized=true;state.legacyTokens=legacy;state.legacyWbnb=legacyNative;state.autoTokens=lp;
        pendingLiquidityTokens=legacy+lp;pendingMarketingTokens=marketing;_marketingCycle().remaining=0;
        if(burned!=0)_burn(address(this),burned);
        emit TaxV3Initialized(previous,lp,burned,marketing,legacy,legacyNative);
    }
    function quotaOfWallet(address wallet) public view returns(uint256){return BASE_QUOTA+inviteBonusByWallet[wallet];}
    function quotaOfId(uint256 id) public view returns(uint256){return BASE_QUOTA+inviteBonusById[id];}
    function remainingQuota(uint256 id) external view returns(uint256){
        address wallet=idCollection.ownerOf(id);uint256 wq=quotaOfWallet(wallet);uint256 iq=quotaOfId(id);
        uint256 wr=mintedByWallet[wallet]>=wq?0:wq-mintedByWallet[wallet];uint256 ir=mintedById[id]>=iq?0:iq-mintedById[id];return Math.min(wr,ir);
    }
    function priceAt(uint256 lot) public pure returns(uint256){
        if(lot==0||lot>MAX_LOTS)revert InvalidInput();uint256 tier=lot<=FIRST_TIER_LOTS?0:1+(lot-FIRST_TIER_LOTS-1)/1000;
        return BASE_PRICE+tier*(BASE_PRICE/10);
    }
    function _batch(uint256 quantity) private view {if(quantity==0||quantity>MAX_PER_TX||quantity>MAX_LOTS-totalMintedLots)revert InvalidInput();}
    function quoteMint(uint256 quantity) public view returns(uint256 cost){_batch(quantity);for(uint256 i=1;i<=quantity;++i)cost+=priceAt(totalMintedLots+i);}
    /// @notice Pre-opening LP token amount describes the proportional future seed; reserves await owner opening or lot8888.
    function previewMint(uint256 quantity) external view returns(uint256 cost,uint256 recipientTokens,uint256 liquidityTokens,uint256 liquidityBnb){
        _batch(quantity);uint256 rb;uint256 rw;
        if(!opened){
            cost=quoteMint(quantity);recipientTokens=quantity*tokensPerLot;liquidityBnb=cost*60/100;
            liquidityTokens=Math.mulDiv(liquidityBnb,SEED_TOKENS,SEED_WBNB);return(cost,recipientTokens,liquidityTokens,liquidityBnb);
        }
        _guardPrice();(rb,rw,)=_reserves();
        for(uint256 i=1;i<=quantity;++i){
            uint256 s=totalMintedLots+i;uint256 price=priceAt(s);uint256 lp=price*60/100;cost+=price;liquidityBnb+=lp;
            recipientTokens+=Math.mulDiv(price*100,rb,rw*99);uint256 added=Math.mulDiv(lp,rb,rw);liquidityTokens+=added;rb+=added;rw+=lp;
        }
    }
    /// @notice Quote is bound to first lot and minimum received tokens.
    function mint(uint256 id,uint256 quantity,uint256 expectedStart,uint256 minTokens,uint256 deadline) external payable nonReentrant {
        _mintUnits(id,quantity,expectedStart,minTokens,deadline,false,0);
    }
    function mintWithInviter(uint256 id,uint256 quantity,uint256 expectedStart,uint256 minTokens,uint256 deadline,uint256 inviter) external payable nonReentrant {
        _mintUnits(id,quantity,expectedStart,minTokens,deadline,true,inviter);
    }
    function _mintUnits(uint256 id,uint256 quantity,uint256 expectedStart,uint256 minTokens,uint256 deadline,bool bind,uint256 inviter) private {
        if(!mintOpen)revert MintClosed();_deadline(deadline);_batch(quantity);uint256 first=totalMintedLots+1;
        if(idCollection.ownerOf(id)!=msg.sender||mintedByWallet[msg.sender]+quantity>quotaOfWallet(msg.sender)
            ||mintedById[id]+quantity>quotaOfId(id))revert InvalidInput();
        if(bind){
            if(mintedById[id]!=0||inviter==id)revert InvalidInput();address ref=idCollection.ownerOf(inviter);
            if(ref==address(0)||ref==msg.sender)revert InvalidInput();
            referrerWalletById[id]=ref;referrerIdById[id]=inviter;
            // Legacy wallet getters mirror only its first paid-Mint binding.
            if(mintedByWallet[msg.sender]==0){referrerWallet[msg.sender]=ref;referrerId[msg.sender]=inviter;}
            emit InviteBound(msg.sender,ref,inviter);emit InviteBoundById(id,ref,inviter);
        }
        if(first!=expectedStart||minTokens==0)revert StaleQuote();uint256 cost=quoteMint(quantity);if(msg.value!=cost)revert IncorrectPayment();
        mintedByWallet[msg.sender]+=quantity;mintedById[id]+=quantity;
        uint256 last=first+quantity-1;totalMintedLots=last;uint256 issued;uint256 allLiquidity;uint256 postStart=first;
        if(!opened){postStart=last+1;issued=quantity*tokensPerLot;
            uint256 lp=cost*60/100;IWrappedGM(wrappedNative).deposit{value:lp}();pendingLiquidityBnb+=lp;allLiquidity+=lp;
            if(last==OPEN_AT)_open(false);
        }
        if(postStart<=last){_guardPrice();_checkpoint();for(uint256 s=postStart;s<=last;++s){
            (uint256 rb,uint256 rw,)=_reserves();uint256 price=priceAt(s);issued+=Math.mulDiv(price*100,rb,rw*99);
            uint256 lp=price*60/100;uint256 added=Math.mulDiv(lp,rb,rw);allLiquidity+=lp;IWrappedGM(wrappedNative).deposit{value:lp}();_addPool(lp,added);
        }}
        if(issued<minTokens)revert StaleQuote();_mint(msg.sender,issued);_creditMarketing(cost-allLiquidity);
        _qualifyReferral(id);
        emit LotsMinted(msg.sender,first,quantity,cost,issued);
    }
    function _qualifyReferral(uint256 id) private {
        address referrer=referrerWalletById[id];
        if(referrer!=address(0)&&!referralQualifiedById[id]){
            referralQualifiedById[id]=true;referralQualified[msg.sender]=true;
            inviteBonusByWallet[referrer]++;inviteBonusById[referrerIdById[id]]++;
            emit InviteCredited(msg.sender,referrer,referrerIdById[id]);emit InviteCreditedById(id,referrer,referrerIdById[id]);
        }
    }
    function earlyOpenQuote() public view returns(uint256 lots,uint256 wbnb,uint256 tokens,bool eligible) {
        lots=totalMintedLots;wbnb=pendingLiquidityBnb;tokens=Math.mulDiv(wbnb,SEED_TOKENS,SEED_WBNB);
        eligible=!opened&&lots>0&&lots<OPEN_AT&&wbnb>0;
    }
    /// @notice Owner can only open with all reserved LP funds at the published ratio; no withdrawal or custom recipient.
    function openEarly(uint256 expectedLots,uint256 expectedWbnb,uint256 deadline) external onlyOwner nonReentrant {
        _deadline(deadline);(uint256 lots,uint256 wbnb,,bool eligible)=earlyOpenQuote();
        if(!eligible)revert InvalidInput();if(lots!=expectedLots||wbnb!=expectedWbnb)revert StaleQuote();_open(true);
    }
    function _open(bool manual) private {
        uint256 lp=pendingLiquidityBnb;if(opened||lp==0||(!manual&&totalMintedLots!=OPEN_AT))revert InvalidInput();
        uint256 seed=Math.mulDiv(lp,SEED_TOKENS,SEED_WBNB);pendingLiquidityBnb=0;opened=true;_addPool(lp,seed);
        (averageRateX112,observationCumulative,observationTime)=_oracle();emit PoolOpened(pair,lp,seed);
        if(manual)emit PoolOpenedEarly(totalMintedLots,lp,seed);
    }
    function _addPool(uint256 bnbAmount,uint256 tokenAmount) private {
        if(bnbAmount==0||tokenAmount==0)revert InvalidInput();_mint(pair,tokenAmount);IERC20(wrappedNative).safeTransfer(pair,bnbAmount);
        uint256 lp=IV2PairGM(pair).mint(DEAD);if(lp==0)revert Slippage();totalLiquidityBnbAdded+=bnbAmount;totalLiquidityTokensAdded+=tokenAmount;
        emit LiquidityAdded(tokenAmount,bnbAmount,lp,DEAD);
    }
    function _reserves() private view returns(uint256 rb,uint256 rw,uint32 ts){(uint112 r0,uint112 r1,uint32 t)=IV2PairGM(pair).getReserves();return gmIs0?(r0,r1,t):(r1,r0,t);}
    function _oracle() private view returns(uint256 spot,uint256 cumulative,uint32 now32){
        (uint256 rb,uint256 rw,uint32 ts)=_reserves();if(rb==0||rw==0)revert InvalidInput();now32=uint32(block.timestamp);spot=Math.mulDiv(rb,Q112,rw);
        cumulative=gmIs0?IV2PairGM(pair).price1CumulativeLast():IV2PairGM(pair).price0CumulativeLast();unchecked{cumulative+=spot*(now32-ts);}
    }
    function _guardPrice() private view {
        (uint256 spot,uint256 c,uint32 t)=_oracle();uint256 avg=averageRateX112;unchecked{uint32 delta=t-observationTime;if(delta>=ORACLE_WINDOW)avg=(c-observationCumulative)/delta;}
        uint256 diff=spot>avg?spot-avg:avg-spot;if(avg==0||diff>avg/20)revert ReservePriceOutsideWindow();
    }
    /// @dev GM/BNB is the inverse price: a lower spot means better BNB proceeds.
    /// Marketing allows favorable appreciation but retains the old 5% downside cap.
    function _guardMarketingPrice() private view {
        if(!_marketingPriceAllowed())revert ReservePriceOutsideWindow();
    }
    function _marketingPriceAllowed() private view returns(bool) {
        (uint256 spot,uint256 c,uint32 t)=_oracle();uint256 avg=averageRateX112;
        unchecked{uint32 delta=t-observationTime;if(delta>=ORACLE_WINDOW)avg=(c-observationCumulative)/delta;}
        return avg!=0&&spot<=avg+avg/20;
    }
    function _checkpoint() private {
        (,uint256 c,uint32 t)=_oracle();unchecked{uint32 delta=t-observationTime;if(delta>=ORACLE_WINDOW){averageRateX112=(c-observationCumulative)/delta;observationCumulative=c;observationTime=t;}}
    }
    function checkpoint() external nonReentrant {if(!opened)revert TradingNotOpen();_checkpoint();}
    function setMintOpen(bool open) external onlyOwner {mintOpen=open;emit MintOpenChanged(open);}
    function setMarketingThreshold(uint256 threshold) external onlyOwner {if(threshold==0)revert InvalidInput();emit MarketingThresholdChanged(marketingThreshold,threshold);marketingThreshold=threshold;}
    function setMaxMarketingSwap(uint256 maximum) external onlyOwner {
        if(maximum==0||maximum>MAX_MARKETING_BATCH)revert InvalidInput();emit MaxMarketingSwapChanged(maxMarketingSwap,maximum);maxMarketingSwap=maximum;
    }
    function setMarketingWallet(address wallet) external onlyOwner {
        if(wallet==address(0)||wallet==address(this)||wallet==pair||wallet==router)revert InvalidInput();emit MarketingWalletChanged(marketingWallet,wallet);marketingWallet=wallet;
    }
    /// @dev Called only inside nonReentrant Mint / processing entrypoints.
    /// Credit first; a rejected bounded direct payment remains claimable by that recipient.
    function _creditMarketing(uint256 amount) private {
        if(amount==0)return;address wallet=marketingWallet;
        marketingCredits+=amount;marketingCreditOf[wallet]+=amount;emit MarketingCredited(wallet,amount);
        (bool ok,)=payable(wallet).call{value:amount,gas:MARKETING_PAYMENT_GAS}("");
        if(ok){marketingCredits-=amount;marketingCreditOf[wallet]-=amount;emit MarketingPaid(wallet,amount);}
    }
    function claimMarketing(address wallet) public nonReentrant {
        uint256 amount=marketingCreditOf[wallet];if(amount==0)revert InvalidInput();marketingCreditOf[wallet]=0;marketingCredits-=amount;
        (bool ok,)=payable(wallet).call{value:amount}("");if(!ok)revert ExternalCallFailed();emit MarketingClaimed(wallet,amount);
    }
    /// @notice Threshold is GM base units; it applies to trading-tax marketing conversions.
    function processMarketingTokens(uint256 amount,uint256 minBnbOut,uint256 deadline) external onlyOwner nonReentrant {
        uint256 floor=_marketingMinimum(amount);if(minBnbOut<floor)revert Slippage();
        _startMarketingCycle();_consumeMarketingCycle(amount);
        uint256 received=_swapForBnb(amount,minBnbOut,deadline,1);_creditMarketing(received);emit MarketingTokensProcessed(amount,received);
    }
    function _marketingCycle() private pure returns(MarketingCycleState storage state) {
        bytes32 slot=MARKETING_CYCLE_SLOT;assembly("memory-safe"){state.slot:=slot}
    }
    function marketingCycleRemaining() external view returns(uint256){return _marketingCycle().remaining;}
    function marketingCycleUncommitted() external view returns(uint256){return pendingMarketingTokens-_marketingCycle().remaining;}
    function marketingCycleSlot() external pure returns(bytes32){return MARKETING_CYCLE_SLOT;}
    /// @notice Self-only, isolated transaction frame: a failed automatic conversion rolls back before the sell continues.
    function processAutoMarketing() external nonReentrant returns(uint256 amount,uint256 received) {
        if(msg.sender!=address(this))revert InvalidInput();
        (amount,received)=_processMarketingBatch();emit AutoMarketingProcessed(amount,received);
    }
    function _marketingAmount() private view returns(uint256 amount) {
        if(!opened||balanceOf(address(this))<pendingMarketingTokens+pendingLiquidityTokens)revert InvalidInput();
        uint256 available=_marketingCycle().remaining;
        if(available>pendingMarketingTokens)revert InvalidInput();
        if(available==0){if(pendingMarketingTokens<marketingThreshold)revert InvalidInput();available=pendingMarketingTokens;}
        (uint256 rb,,)=_reserves();
        amount=Math.min(available,Math.min(MAX_MARKETING_BATCH,Math.min(maxMarketingSwap,Math.mulDiv(rb,MAX_AUTO_SWAP_RESERVE_BPS,10000))));
        if(amount==0)revert InvalidInput();
    }
    function _startMarketingCycle() private {
        MarketingCycleState storage state=_marketingCycle();
        if(state.remaining==0){state.remaining=pendingMarketingTokens;emit MarketingCycleStarted(state.remaining);}
    }
    function _consumeMarketingCycle(uint256 amount) private {
        MarketingCycleState storage state=_marketingCycle();state.remaining-=amount;pendingMarketingTokens-=amount;
        emit MarketingCycleProcessed(amount,state.remaining);
    }
    function _marketingMinimum(uint256 amount) private view returns(uint256 minOut) {
        if(amount==0||amount>_marketingAmount())revert InvalidInput();
        _guardMarketingPrice();(uint256 rb,uint256 rw,)=_reserves();
        return _currentMinimum(amount,rb,rw);
    }
    function _currentMinimum(uint256 amount,uint256 rb,uint256 rw) private pure returns(uint256 minOut) {
        // Pinned Pancake V2 router uses a0.25% exchange fee (9975/10000).
        uint256 inputWithFee=amount*9975;
        uint256 quoted=Math.mulDiv(inputWithFee,rw,rb*10000+inputWithFee);
        minOut=Math.mulDiv(quoted,10000-AUTO_SWAP_SLIPPAGE_BPS,10000);
        if(minOut==0)revert Slippage();
    }
    function _processMarketingBatch() private returns(uint256 amount,uint256 received) {
        amount=_marketingAmount();uint256 minOut=_marketingMinimum(amount);
        _startMarketingCycle();_consumeMarketingCycle(amount);
        received=_swapForBnb(amount,minOut,block.timestamp+5 minutes,1);
        _creditMarketing(received);emit MarketingTokensProcessed(amount,received);
    }
    function _taxBudgets(uint256 gross) private view returns(uint256 normal,uint256 adverse) {
        (uint256 rb,uint256 rw,)=_reserves();if(rb==0||rw==0)return(0,0);
        normal=Math.min(MAX_MARKETING_BATCH,Math.min(maxMarketingSwap,rb/1000));
        adverse=Math.min(normal,Math.min(gross/10,rb/10000));
    }
    function _autoLpAmount(uint256 normal,uint256 adverse) private view returns(uint256 amount) {
        TaxV3State storage state=_taxV3();if(!state.initialized||state.autoTokens<MIN_AUTO_LP_TOKENS)return 0;
        // LP goes first, but reserves capacity for marketing even in adverse markets.
        amount=Math.min(state.autoTokens,Math.min(MAX_AUTO_LP_BATCH,2*Math.min(normal/24,adverse/2)));
        if(amount<2)return 0;
    }
    function _reason(bytes memory data) private pure returns(bytes4 value){if(data.length>=4){assembly("memory-safe"){value:=mload(add(data,32))}}}
    function _tryAutoTaxV3(uint256 gross) private {
        (uint256 normal,uint256 adverse)=_taxBudgets(gross);if(normal==0)return;
        bool lp=_autoLpAmount(normal,adverse)!=0;
        bool marketing=_marketingCycle().remaining!=0||pendingMarketingTokens>=marketingThreshold;
        if(!lp&&!marketing)return;
        // Conditional aggregate gas budget prevents estimateGas from selecting a
        // cheap skipped helper. Only actual consumed gas is charged to the seller.
        if(gasleft()<(lp?AUTO_LP_GAS:0)+(marketing?AUTO_SWAP_GAS:0)+AUTO_SWAP_GAS_RESERVE)revert AutoSwapGasBudget();
        uint256 sold;
        if(lp){try this.processAutoLpV3{gas:AUTO_LP_GAS}(gross,normal,adverse) returns(uint256 amount){sold=amount;}
            catch(bytes memory reason){emit AutoLiquidityDeferred(_taxV3().autoTokens,_reason(reason));}}
        if(marketing){try this.processAutoMarketingV3{gas:AUTO_SWAP_GAS}(gross,sold,normal,adverse) {} catch(bytes memory reason){
            emit AutoMarketingDeferred(pendingMarketingTokens);emit AutoMarketingDeferredReason(pendingMarketingTokens,_reason(reason));}}
    }
    /// @notice Self-only sell hook; fresh-reserve minimum applies even when an adverse TWAP permits only a small batch.
    function processAutoMarketingV3(uint256 gross,uint256 alreadySold,uint256 normalLimit,uint256 adverseLimit) external nonReentrant returns(uint256 amount,uint256 received) {
        if(msg.sender!=address(this))revert InvalidInput();
        (uint256 normal,uint256 adverse)=_taxBudgets(gross);
        uint256 limit=_marketingPriceAllowed()?Math.min(normal,normalLimit):Math.min(adverse,adverseLimit);
        if(limit<=alreadySold)return(0,0);
        amount=Math.min(_marketingAmount(),limit-alreadySold);
        (uint256 rb,uint256 rw,)=_reserves();uint256 minOut=_currentMinimum(amount,rb,rw);
        _startMarketingCycle();_consumeMarketingCycle(amount);
        received=_swapForBnb(amount,minOut,block.timestamp+5 minutes,2);
        _creditMarketing(received);emit MarketingTokensProcessed(amount,received);emit AutoMarketingProcessed(amount,received);
    }
    /// @notice Uses only V3's dedicated GM/WBNB queues and mints all new LP directly to DEAD.
    function processAutoLpV3(uint256 gross,uint256 normalLimit,uint256 adverseLimit) external nonReentrant returns(uint256 sold) {
        if(msg.sender!=address(this))revert InvalidInput();
        (uint256 normal,uint256 adverse)=_taxBudgets(gross);
        uint256 batch=_autoLpAmount(Math.min(normal,normalLimit),Math.min(adverse,adverseLimit));if(batch==0)return 0;
        TaxV3State storage state=_taxV3();
        if(balanceOf(address(this))<pendingMarketingTokens+pendingLiquidityTokens||state.legacyTokens+state.autoTokens!=pendingLiquidityTokens
            ||state.legacyWbnb+state.autoWbnb!=pendingLiquidityBnb)revert InvalidInput();
        sold=batch/2;(uint256 rb,uint256 rw,)=_reserves();uint256 minOut=_currentMinimum(sold,rb,rw);
        state.autoTokens-=sold;pendingLiquidityTokens-=sold;
        uint256 received=_swapForBnb(sold,minOut,block.timestamp+5 minutes,2);
        IWrappedGM(wrappedNative).deposit{value:received}();state.autoWbnb+=received;pendingLiquidityBnb+=received;
        (rb,rw,)=_reserves();uint256 tokens=Math.min(batch-sold,Math.mulDiv(state.autoWbnb,rb,rw));uint256 native=Math.mulDiv(tokens,rw,rb);
        if(tokens==0||native==0)revert Slippage();
        state.autoTokens-=tokens;pendingLiquidityTokens-=tokens;state.autoWbnb-=native;pendingLiquidityBnb-=native;
        super._update(address(this),pair,tokens);IERC20(wrappedNative).safeTransfer(pair,native);
        uint256 beforeLp=IERC20(pair).balanceOf(DEAD);uint256 minted=IV2PairGM(pair).mint(DEAD);
        if(minted==0||IERC20(pair).balanceOf(DEAD)-beforeLp!=minted)revert Slippage();
        totalLiquidityBnbAdded+=native;totalLiquidityTokensAdded+=tokens;
        emit LiquidityAdded(tokens,native,minted,DEAD);emit AutoLiquidityAdded(sold,tokens,native,minted);
    }
    function swapLiquidityTokens(uint256 amount,uint256 minBnbOut,uint256 deadline) external onlyOwner nonReentrant {
        TaxV3State storage state=_taxV3();
        if(!state.initialized||!opened||amount==0||amount>state.legacyTokens)revert InvalidInput();pendingLiquidityTokens-=amount;state.legacyTokens-=amount;
        uint256 received=_swapForBnb(amount,minBnbOut,deadline,0);IWrappedGM(wrappedNative).deposit{value:received}();pendingLiquidityBnb+=received;state.legacyWbnb+=received;
        emit LiquidityTokensSwapped(amount,received);
    }
    /// @notice Adds accounted trading-tax reserves at a guarded ratio, without extra issuance.
    function processPendingLiquidity(uint256 bnbAmount,uint256 minTokens,uint256 maxTokens,uint256 deadline) external onlyOwner nonReentrant {
        TaxV3State storage state=_taxV3();
        _deadline(deadline);if(!state.initialized||!opened||bnbAmount==0||bnbAmount>state.legacyWbnb)revert InvalidInput();_guardPrice();_checkpoint();
        (uint256 rb,uint256 rw,)=_reserves();uint256 amount=Math.mulDiv(bnbAmount,rb,rw);
        if(amount==0||amount<minTokens||amount>maxTokens||amount>state.legacyTokens)revert Slippage();pendingLiquidityTokens-=amount;pendingLiquidityBnb-=bnbAmount;state.legacyTokens-=amount;state.legacyWbnb-=bnbAmount;
        super._update(address(this),pair,amount);IERC20(wrappedNative).safeTransfer(pair,bnbAmount);
        uint256 lp=IV2PairGM(pair).mint(DEAD);if(lp==0)revert Slippage();totalLiquidityBnbAdded+=bnbAmount;totalLiquidityTokensAdded+=amount;
        emit LiquidityAdded(amount,bnbAmount,lp,DEAD);
    }
    function _swapForBnb(uint256 amount,uint256 minBnbOut,uint256 deadline,uint8 policy) private returns(uint256 received){
        _deadline(deadline);if(minBnbOut==0)revert Slippage();if(policy==1)_guardMarketingPrice();else if(policy==0)_guardPrice();_checkpoint();address[] memory path=new address[](2);path[0]=address(this);path[1]=wrappedNative;
        uint256 beforeNative=address(this).balance;uint256 beforeTokens=balanceOf(address(this));processing=true;_approve(address(this),router,amount);
        IV2RouterGM(router).swapExactTokensForETHSupportingFeeOnTransferTokens(amount,minBnbOut,path,address(this),deadline);
        _approve(address(this),router,0);processing=false;received=address(this).balance-beforeNative;
        if(received<minBnbOut||beforeTokens-balanceOf(address(this))!=amount)revert Slippage();
    }
    function _deadline(uint256 deadline) private view {if(deadline<block.timestamp||deadline>block.timestamp+30 minutes)revert StaleQuote();}
    function _update(address from,address to,uint256 value) internal override {
        if(from==address(0)||to==address(0)||value==0){super._update(from,to,value);return;}if(!opened)revert TradingNotOpen();
        if(!processing&&(from==pair||to==pair)){
            // Only a later sell starts a cycle. This sell's tax is not in its
            // principal: the nested conversion finishes before collecting it or
            // forwarding this sell's net input to the pair.
            if(to==pair&&from!=pair&&entered!=2)_tryAutoTaxV3(value);
            uint256 fee = Math.mulDiv(value, TAX_BPS, 10_000);
            uint256 toDead = fee / 4;
            uint256 toLiquidity = fee / 20;
            // Keep integer rounding dust in the 70% marketing allocation.
            uint256 retained = fee - toDead;
            uint256 toMarketing = retained - toLiquidity;

            if (toDead != 0) super._update(from, DEAD, toDead);
            if (retained != 0) super._update(from, address(this), retained);
            pendingLiquidityTokens += toLiquidity;
            pendingMarketingTokens += toMarketing;
            if (_taxV3().initialized) _taxV3().autoTokens += toLiquidity;
            super._update(from, to, value - fee);
            emit TaxCollected(from, to, toDead, toLiquidity, toMarketing);
        }else super._update(from,to,value);
    }
    function _authorizeUpgrade(address) internal override onlyOwner {}
    receive() external payable {if(msg.sender!=router)revert InvalidInput();}
}
