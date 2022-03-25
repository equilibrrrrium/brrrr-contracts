// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IERC20.sol";

contract TaxOfficeV2 is Operator {
    using SafeMath for uint256;

    address public brrrr = address(0x98b7ABe62cd8A694e3725618881B41CE00aBD4BC);
    address public weth = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address public uniRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    mapping(address => bool) public taxExclusionEnabled;

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(brrrr).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(brrrr).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(brrrr).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(brrrr).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(brrrr).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(brrrr).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(brrrr).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return _excludeAddressFromTax(_address);
    }

    function _excludeAddressFromTax(address _address) private returns (bool) {
        if (!ITaxable(brrrr).isAddressExcluded(_address)) {
            return ITaxable(brrrr).excludeAddress(_address);
        }
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return _includeAddressInTax(_address);
    }

    function _includeAddressInTax(address _address) private returns (bool) {
        if (ITaxable(brrrr).isAddressExcluded(_address)) {
            return ITaxable(brrrr).includeAddress(_address);
        }
    }

    function taxRate() external returns (uint256) {
        return ITaxable(brrrr).taxRate();
    }

    function addLiquidityTaxFree(
        address token,
        uint256 amtBrrrr,
        uint256 amtToken,
        uint256 amtBrrrrMin,
        uint256 amtTokenMin
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtBrrrr != 0 && amtToken != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(brrrr).transferFrom(msg.sender, address(this), amtBrrrr);
        IERC20(token).transferFrom(msg.sender, address(this), amtToken);
        _approveTokenIfNeeded(brrrr, uniRouter);
        _approveTokenIfNeeded(token, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtBrrrr;
        uint256 resultAmtToken;
        uint256 liquidity;
        (resultAmtBrrrr, resultAmtToken, liquidity) = IUniswapV2Router(uniRouter).addLiquidity(
            brrrr,
            token,
            amtBrrrr,
            amtToken,
            amtBrrrrMin,
            amtTokenMin,
            msg.sender,
            block.timestamp
        );

        if (amtBrrrr.sub(resultAmtBrrrr) > 0) {
            IERC20(brrrr).transfer(msg.sender, amtBrrrr.sub(resultAmtBrrrr));
        }
        if (amtToken.sub(resultAmtToken) > 0) {
            IERC20(token).transfer(msg.sender, amtToken.sub(resultAmtToken));
        }
        return (resultAmtBrrrr, resultAmtToken, liquidity);
    }

    function addLiquidityETHTaxFree(
        uint256 amtBrrrr,
        uint256 amtBrrrrMin,
        uint256 amtEthMin
    )
        external
        payable
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtBrrrr != 0 && msg.value != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(brrrr).transferFrom(msg.sender, address(this), amtBrrrr);
        _approveTokenIfNeeded(brrrr, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtBrrrr;
        uint256 resultAmtEth;
        uint256 liquidity;
        (resultAmtBrrrr, resultAmtEth, liquidity) = IUniswapV2Router(uniRouter).addLiquidityETH{value: msg.value}(
            brrrr,
            amtBrrrr,
            amtBrrrrMin,
            amtEthMin,
            msg.sender,
            block.timestamp
        );

        if (amtBrrrr.sub(resultAmtBrrrr) > 0) {
            IERC20(brrrr).transfer(msg.sender, amtBrrrr.sub(resultAmtBrrrr));
        }
        return (resultAmtBrrrr, resultAmtEth, liquidity);
    }

    function setTaxableBrrrrOracle(address _brrrrOracle) external onlyOperator {
        ITaxable(brrrr).setBrrrrOracle(_brrrrOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(brrrr).setTaxOffice(_newTaxOffice);
    }

    function taxFreeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _amt
    ) external {
        require(taxExclusionEnabled[msg.sender], "Address not approved for tax free transfers");
        _excludeAddressFromTax(_sender);
        IERC20(brrrr).transferFrom(_sender, _recipient, _amt);
        _includeAddressInTax(_sender);
    }

    function setTaxExclusionForAddress(address _address, bool _excluded) external onlyOperator {
        taxExclusionEnabled[_address] = _excluded;
    }

    function _approveTokenIfNeeded(address _token, address _router) private {
        if (IERC20(_token).allowance(address(this), _router) == 0) {
            IERC20(_token).approve(_router, type(uint256).max);
        }
    }
}
