// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TaxOracle is Ownable {
    using SafeMath for uint256;

    IERC20 public brrrr;
    IERC20 public wbnb;
    address public pair;

    constructor(
        address _brrrr,
        address _wbnb,
        address _pair
    ) public {
        require(_brrrr != address(0), "brrrr address cannot be 0");
        require(_wbnb != address(0), "wbnb address cannot be 0");
        require(_pair != address(0), "pair address cannot be 0");
        brrrr = IERC20(_brrrr);
        wbnb = IERC20(_wbnb);
        pair = _pair;
    }

    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        require(_token == address(brrrr), "token needs to be brrrr");
        uint256 brrrrBalance = brrrr.balanceOf(pair);
        uint256 wbnbBalance = wbnb.balanceOf(pair);
        return uint144(brrrrBalance.mul(_amountIn).div(wbnbBalance));
    }

    function getBrrrrBalance() external view returns (uint256) {
	return brrrr.balanceOf(pair);
    }

    function getWbnbBalance() external view returns (uint256) {
	return wbnb.balanceOf(pair);
    }

    function getPrice() external view returns (uint256) {
        uint256 brrrrBalance = brrrr.balanceOf(pair);
        uint256 wbnbBalance = wbnb.balanceOf(pair);
        return brrrrBalance.mul(1e18).div(wbnbBalance);
    }


    function setBrrrr(address _brrrr) external onlyOwner {
        require(_brrrr != address(0), "brrrr address cannot be 0");
        brrrr = IERC20(_brrrr);
    }

    function setWbnb(address _wbnb) external onlyOwner {
        require(_wbnb != address(0), "wbnb address cannot be 0");
        wbnb = IERC20(_wbnb);
    }

    function setPair(address _pair) external onlyOwner {
        require(_pair != address(0), "pair address cannot be 0");
        pair = _pair;
    }
}