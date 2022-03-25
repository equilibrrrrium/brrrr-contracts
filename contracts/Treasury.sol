// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBrrrrbank.sol";

contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
    address[] public excludedFromTotalSupply = [
        address(0x780eEE810AB71e449EC3450D5506FF942ff70AEF),// Bnb/brrr GenesisPool
        address(0xfa84F491f43640aDA6957CAD4A1eB526E668426c),// BnbGenesisPool
        address(0x3510AEa310Dd45A62c479884e9B554F45ceA0F4b)// BusdGenesisPool
    ];

    // core components
    address public brrrr;
    address public brrrrbond;
    address public brrrrshare;

    address public brrrrbank;
    address public brrrrOracle;

    // price
    uint256 public brrrrPriceOne;
    uint256 public brrrrPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 3% expansion regardless of BRRRR price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochBrrrrPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra BRRRR during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 brrrrAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 brrrrAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BrrrrbankFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getBrrrrPrice() > brrrrPriceCeiling) ? 0 : getBrrrrCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(brrrr).operator() == address(this) &&
                IBasisAsset(brrrrbond).operator() == address(this) &&
                IBasisAsset(brrrrshare).operator() == address(this) &&
                Operator(brrrrbank).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getBrrrrPrice() public view returns (uint256 brrrrPrice) {
        try IOracle(brrrrOracle).consult(brrrr, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult BRRRR price from the oracle");
        }
    }

    function getBrrrrUpdatedPrice() public view returns (uint256 _brrrrPrice) {
        try IOracle(brrrrOracle).twap(brrrr, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult BRRRR price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableBrrrrLeft() public view returns (uint256 _burnableBrrrrLeft) {
        uint256 _brrrrPrice = getBrrrrPrice();
        if (_brrrrPrice <= brrrrPriceOne) {
            uint256 _brrrrSupply = getBrrrrCirculatingSupply();
            uint256 _bondMaxSupply = _brrrrSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(brrrrbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableBrrrr = _maxMintableBond.mul(_brrrrPrice).div(1e15);
                _burnableBrrrrLeft = Math.min(epochSupplyContractionLeft, _maxBurnableBrrrr);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _brrrrPrice = getBrrrrPrice();
        if (_brrrrPrice > brrrrPriceCeiling) {
            uint256 _totalBrrrr = IERC20(brrrr).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalBrrrr.mul(1e15).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _brrrrPrice = getBrrrrPrice();
        if (_brrrrPrice <= brrrrPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = brrrrPriceOne;
            } else {
                uint256 _bondAmount = brrrrPriceOne.mul(1e18).div(_brrrrPrice); // to burn 1 BRRRR
                uint256 _discountAmount = _bondAmount.sub(brrrrPriceOne).mul(discountPercent).div(10000);
                _rate = brrrrPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _brrrrPrice = getBrrrrPrice();
        if (_brrrrPrice > brrrrPriceCeiling) {
            uint256 _brrrrPricePremiumThreshold = brrrrPriceOne.mul(premiumThreshold).div(100);
            if (_brrrrPrice >= _brrrrPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _brrrrPrice.sub(brrrrPriceOne).mul(premiumPercent).div(10000);
                _rate = brrrrPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = brrrrPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _brrrr,
        address _brrrrbond,
        address _brrrrshare,
        address _brrrrOracle,
        address _brrrrbank,
        uint256 _startTime
    ) public notInitialized {
        brrrr = _brrrr;
        brrrrbond = _brrrrbond;
        brrrrshare = _brrrrshare;
        brrrrOracle = _brrrrOracle;
        brrrrbank = _brrrrbank;
        startTime = _startTime;

        brrrrPriceOne = 10**15; // This is to allow a PEG of 1,000 BRRRR per BNB
        brrrrPriceCeiling = brrrrPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500_000 ether, 2_000_000 ether, 4_000_000 ether, 8_000_000 ether, 20_000_000 ether];
        maxExpansionTiers = [300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for brrrrbank
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn BRRRR and mint BRRRRBOND)
        maxDebtRatioPercent = 4500; // Upto 45% supply of BRRRRBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 3% expansion
        bootstrapEpochs = 0;
        bootstrapSupplyExpansionPercent = 300;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(brrrr).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBrrrrbank(address _brrrrbank) external onlyOperator {
        brrrrbank = _brrrrbank;
    }

    function setBrrrrOracle(address _brrrrOracle) external onlyOperator {
        brrrrOracle = _brrrrOracle;
    }

    function setBrrrrPriceCeiling(uint256 _brrrrPriceCeiling) external onlyOperator {
        require(_brrrrPriceCeiling >= brrrrPriceOne && _brrrrPriceCeiling <= brrrrPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        brrrrPriceCeiling = _brrrrPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < supplyTiers.length, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < supplyTiers.length - 1) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < maxExpansionTiers.length, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= brrrrPriceCeiling, "_premiumThreshold exceeds brrrrPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateBrrrrPrice() internal {
        try IOracle(brrrrOracle).update() {} catch {}
    }

    function getBrrrrCirculatingSupply() public view returns (uint256) {
        IERC20 brrrrErc20 = IERC20(brrrr);
        uint256 totalSupply = brrrrErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(brrrrErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _brrrrAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_brrrrAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 brrrrPrice = getBrrrrPrice();
        require(brrrrPrice == targetPrice, "Treasury: BRRRR price moved");
        require(
            brrrrPrice < brrrrPriceOne, // price < $1
            "Treasury: brrrrPrice not eligible for bond purchase"
        );

        require(_brrrrAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _brrrrAmount.mul(_rate).div(1e15);
        uint256 brrrrSupply = getBrrrrCirculatingSupply();
        uint256 newBondSupply = IERC20(brrrrbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= brrrrSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(brrrr).burnFrom(msg.sender, _brrrrAmount);
        IBasisAsset(brrrrbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_brrrrAmount);
        _updateBrrrrPrice();

        emit BoughtBonds(msg.sender, _brrrrAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 brrrrPrice = getBrrrrPrice();
        require(brrrrPrice == targetPrice, "Treasury: BRRRR price moved");
        require(
            brrrrPrice > brrrrPriceCeiling, // price > $1.01
            "Treasury: brrrrPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _brrrrAmount = _bondAmount.mul(_rate).div(1e15);
        require(IERC20(brrrr).balanceOf(address(this)) >= _brrrrAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _brrrrAmount));

        IBasisAsset(brrrrbond).burnFrom(msg.sender, _bondAmount);
        IERC20(brrrr).safeTransfer(msg.sender, _brrrrAmount);

        _updateBrrrrPrice();

        emit RedeemedBonds(msg.sender, _brrrrAmount, _bondAmount);
    }

    function _sendToBrrrrbank(uint256 _amount) internal {
        IBasisAsset(brrrr).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(brrrr).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(brrrr).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(brrrr).safeApprove(brrrrbank, 0);
        IERC20(brrrr).safeApprove(brrrrbank, _amount);
        IBrrrrbank(brrrrbank).allocateSeigniorage(_amount);
        emit BrrrrbankFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _brrrrSupply) internal returns (uint256) {
        for (uint8 tierId = uint8(supplyTiers.length - 1); tierId >= 0; --tierId) {
            if (_brrrrSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateBrrrrPrice();
        previousEpochBrrrrPrice = getBrrrrPrice();
        uint256 brrrrSupply = getBrrrrCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 3% expansion
            _sendToBrrrrbank(brrrrSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochBrrrrPrice > brrrrPriceCeiling) {
                // Expansion ($BRRRR Price > 1 $BNB): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(brrrrbond).totalSupply();
                uint256 _percentage = previousEpochBrrrrPrice.sub(brrrrPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBrrrrbank;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(brrrrSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBrrrrbank = brrrrSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = brrrrSupply.mul(_percentage).div(1e18);
                    _savedForBrrrrbank = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBrrrrbank);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBrrrrbank > 0) {
                    _sendToBrrrrbank(_savedForBrrrrbank);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(brrrr).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(brrrr), "brrrr");
        require(address(_token) != address(brrrrbond), "bond");
        require(address(_token) != address(brrrrshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function brrrrbankSetOperator(address _operator) external onlyOperator {
        IBrrrrbank(brrrrbank).setOperator(_operator);
    }

    function brrrrbankSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBrrrrbank(brrrrbank).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function brrrrbankAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBrrrrbank(brrrrbank).allocateSeigniorage(amount);
    }

    function brrrrbankGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IBrrrrbank(brrrrbank).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
