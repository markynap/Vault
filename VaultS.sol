// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./SafeMath.sol";
import "./Address.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router02.sol";
import "./IDistributor.sol";
import "./IERC20.sol";

/**
 * @dev The official Vault-S Token Smart Contract
 * 
 * developed by MoonMark (DeFi Mark)
 */
contract VAULTS is IERC20 {
    
    using SafeMath for uint256;
    using Address for address;
    
    // General Info
    string private constant _name = "Vault-S";
    string private constant _symbol = "VAULT-S";
    uint8  private constant _decimals = 9;
    
    // Liquidity Settings
    IUniswapV2Router02 public _router;  // DEX Router
    address public _pair;               // LP Address
    
    // prevent infinite swap loop
    bool currentlySwapping;
    modifier lockSwapping {
        currentlySwapping = true;
        _;
        currentlySwapping = false;
    }
    
    // Dead Wallet
    address public constant _burnWallet = 0x000000000000000000000000000000000000dEaD;
    
    // This -> BNB
    address[] path;

    // Balances
    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    // Exclusions
    mapping (address => bool) private _isExcluded; // both self and external reflections

    struct Exemptions {
        bool isFeeExempt;
        bool isTxLimitExempt;
        bool isLiquidityPool;
        bool isGasExempt;
    }

    mapping ( address => Exemptions ) exemptions;
    address[] private _excluded;

    // Supply
    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 1 * 10**9 * (10 ** _decimals);
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _totalReflections;    // Total reflections
    
    // Sell Fee Breakdown
    uint256 public _burnPercentage = 10;                    // 10% of taxes are burned

    // Token Tax Settings
    uint256 public _sellFee = 100;                          // 1% sell tax 
    uint256 public _buyFee = 100;                           // 1% buy tax
    uint256 public _transferFee = 100;                      // 1% transfer tax
    uint256 public constant feeDenominator = 10000;

    // Token Limits
    uint256 public _maxTxAmount        = _tTotal.div(100);   // 10 million
    uint256 public _tokenSwapThreshold = _tTotal.div(1000);  // 1 million
    
    // gas for distributor
    IDistributor _distributor;
    uint256 _distributorGas = 500000;
    
    // Ownership
    address public _owner;
    modifier onlyOwner() {
        require(msg.sender == _owner); _;
    }
    
    // initalize BabyCrib
    constructor (address distributor) {
        
        // Initalize Router
        _router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        
        // Create Liquidity Pair
        _pair = IUniswapV2Factory(_router.factory())
            .createPair(address(this), _router.WETH());

        // Set Distributor
        _distributor = IDistributor(distributor);

        // dividend + reward exclusions
        _excludeFromReward(address(this));
        _excludeFromReward(_burnWallet);
        _excludeFromReward(_pair);
        
        // fee exclusions 
        exemptions[address(this)].isFeeExempt = true;
        exemptions[_burnWallet].isFeeExempt = true;
        exemptions[msg.sender].isFeeExempt = true;
        
        // tx limit exclusions
        exemptions[msg.sender].isTxLimitExempt = true;
        exemptions[address(this)].isTxLimitExempt = true;

        // liquidity pool exemptions
        exemptions[_pair].isLiquidityPool = true;
     
        // ownership
        _owner = msg.sender;
        _rOwned[msg.sender] = _rTotal;
        
        // Token -> BNB
        path = new address[](2);
        path[0] = address(this);
        path[1] = _router.WETH();

        // Transfer
        emit Transfer(address(0), msg.sender, _tTotal);
    }
    

    ////////////////////////////////////////////
    ////////      OWNER FUNCTIONS      /////////
    ////////////////////////////////////////////
    
    /**
     * @notice Transfers Ownership To New Account
     */
    function transferOwnership(address newOwner) external onlyOwner {
        _owner = newOwner;  
        emit TransferOwnership(newOwner);
    }
    
    /**
     * @notice Withdraws BNB from the contract
     */
    function withdrawBNB(uint256 amount) external onlyOwner {
        (bool s,) = payable(msg.sender).call{value: amount}("");
        require(s, 'Failure on BNB Withdraw');
        emit OwnerWithdraw(_router.WETH(), amount);
    }
    
    /**
     * @notice Withdraws non-CRIB tokens that are stuck as to not interfere with the liquidity
     */
    function withdrawForeignToken(address token) external onlyOwner {
        require(token != address(this), "Cannot Withdraw BabyCrib Tokens");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).transfer(msg.sender, bal);
        }
        emit OwnerWithdraw(token, bal);
    }
    
    /**
     * @notice Allows the contract to change the router, in the instance of BabySwap V2 making the contract future proof
     */
    function setRouterAddress(address router) external onlyOwner {
        require(router != address(0));
        _router = IUniswapV2Router02(router);
        emit UpdatedRouterAddress(router);
    }
    
    function setPairAddress(address newPair) external onlyOwner {
        require(newPair != address(0));
        _pair = newPair;
        exemptions[newPair].isLiquidityPool = true;
        _excludeFromReward(newPair);
        _distributor.setShare(newPair, 0);
        emit UpdatedPairAddress(newPair);
    }
    
     /**
     * @notice Excludes an address from receiving reflections
     */
    function excludeFromRewards(address account) external onlyOwner {
        require(account != address(this) && account != _pair);
        
        _excludeFromReward(account);
        _distributor.setShare(account, 0);
        emit ExcludeFromRewards(account);
    }

    function setExemptions(address account, bool feeExempt, bool isLP, bool txLimitExempt, bool gasExempt) external onlyOwner {
        
        exemptions[account].isFeeExempt = feeExempt;
        exemptions[account].isLiquidityPool = isLP;
        exemptions[account].isTxLimitExempt = txLimitExempt;
        exemptions[account].isGasExempt = gasExempt;

        emit SetExemptions(account, feeExempt, isLP, txLimitExempt, gasExempt);
    }

    function setMaxTxAmount(uint256 maxTxAmount) external onlyOwner {
        _maxTxAmount = maxTxAmount;
        emit SetMaxTxAmount(maxTxAmount);
    }
    
    function upgradeDistributor(address newDistributor) external onlyOwner {
        require(newDistributor != address(0));
        _distributor = IDistributor(newDistributor);
        emit UpgradedDistributor(newDistributor); 
    }
    
    function setTokenSwapThreshold(uint256 tokenSwapThreshold) external onlyOwner {
        require(tokenSwapThreshold > 0);
        _tokenSwapThreshold = tokenSwapThreshold;
        emit SetTokenSwapThreshold(tokenSwapThreshold);
    }
    
    /** Sets Various Fees */
    function setFees(uint256 burnPercentage, uint256 sellFee, uint256 buyFee, uint256 transferFee) external onlyOwner {
        
        // set burn percentage
        _burnPercentage = burnPercentage;

        // set total fees
        _sellFee = sellFee;
        _buyFee = buyFee;
        _transferFee = transferFee;

        // require fee limits
        require(_sellFee < 2500);
        require(buyFee < 2500);
        require(transferFee < 2500);
        require(_burnPercentage <= 100);

        // log changes
        emit SetFees(burnPercentage, sellFee, buyFee, transferFee);
    }
    
    /**
     * @notice Includes an address back into the reflection system
     */
    function includeInReward(address account) external onlyOwner {
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                // updating _rOwned to make sure the balances stay the same
                if (_tOwned[account] > 0)
                {
                    uint256 newrOwned = _tOwned[account].mul(_getRate());
                    _rTotal = _rTotal.sub(_rOwned[account]-newrOwned);
                    _totalReflections = _totalReflections.add(_rOwned[account]-newrOwned);
                    _rOwned[account] = newrOwned;
                }
                else
                {
                    _rOwned[account] = 0;
                }

                _tOwned[account] = 0;
                _excluded[i] = _excluded[_excluded.length - 1];
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
        _distributor.setShare(account, balanceOf(account));
        emit IncludeInRewards(account);
    }
    
    function setDistributorGas(uint256 gas) external onlyOwner {
        require(gas < 10000000);
        _distributorGas = gas;
        emit SetDistributorGas(gas);
    }
    
    
    ////////////////////////////////////////////
    ////////      IERC20 FUNCTIONS     /////////
    ////////////////////////////////////////////
    

    function name() external pure override returns (string memory) {
        return _name;
    }

    function symbol() external pure override returns (string memory) {
        return _symbol;
    }

    function decimals() external pure override returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        return _transferFrom(sender, recipient, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    
    
    ////////////////////////////////////////////
    ////////       READ FUNCTIONS      /////////
    ////////////////////////////////////////////
    
    
    function getTotalReflections() external view returns (uint256) {
        return _totalReflections;
    }
    
    function isExcludedFromFee(address account) external view returns(bool) {
        return exemptions[account].isFeeExempt;
    }
    
    function isExcludedFromRewards(address account) external view returns(bool) {
        return _isExcluded[account];
    }
    
    function isGasExempt(address account) external view returns(bool) {
        return exemptions[account].isGasExempt;
    }

    function isTxLimitExempt(address account) external view returns(bool) {
        return exemptions[account].isTxLimitExempt;
    }

    function isLiquidityPool(address account) external view returns(bool) {
        return exemptions[account].isLiquidityPool;
    }
    
    function getDistributorAddress() external view returns (address) {
        return address(_distributor);
    }
 
    
    /**
     * @notice Converts a reflection value to a token value
     */
    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }

    /**
     * @notice Calculates transfer reflection values
     */
    function _getRValues(uint256 tAmount, uint256 tFee, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee);
        return (rAmount, rTransferAmount, rFee);
    }

    /**
     * @notice Calculates the rate of reflections to tokens
     */
    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }
    
    /**
     * @notice Gets the current supply values
     */
    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
    
    function getIncludedTotalSupply() external view returns (uint256) {
        (, uint256 tSupply) = _getCurrentSupply();
        return tSupply;
    }

    function deliver(uint256 tAmount) external {
        require(!_isExcluded[msg.sender], "Excluded addresses cannot call this function");
        uint256 rAmount = tAmount.mul(_getRate());
        _rOwned[msg.sender] = _rOwned[msg.sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
    }

    function updateDistributorBalance() external {
        require(!_isExcluded[msg.sender], 'excluded addresses can not call');
        require(balanceOf(msg.sender) > 0, 'Zero Balance');
        _distributor.setShare(msg.sender, balanceOf(msg.sender));
    }
    
    ////////////////////////////////////////////
    ////////    INTERNAL FUNCTIONS     /////////
    ////////////////////////////////////////////

    /**
     * @notice Handles the before and after of a token transfer, such as taking fees and firing off a swap and liquify event
     */
    function _transferFrom(address from, address to, uint256 amount) private returns(bool){
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        
        // Check TX Amount Exemptions
        require(amount <= _maxTxAmount || exemptions[from].isTxLimitExempt, "TX Limit");
        
        if (currentlySwapping) { // tokens being sent to Router or marketing
            _tokenTransfer(from, to, amount, false);
            return true;
        }
        
        // Should fee be taken 
        bool takeFee = !(exemptions[from].isFeeExempt || exemptions[to].isFeeExempt);
        
        // Should Swap For BNB
        if (shouldSwapBack(from)) {
            // Fuel distributors
            swapBack(_tokenSwapThreshold);
            // transfer token
            _tokenTransfer(from, to, amount, takeFee);
        } else {
            // transfer token
            _tokenTransfer(from, to, amount, takeFee);

            // process dividends
            if (!exemptions[msg.sender].isGasExempt) {
                try _distributor.process(_distributorGas) {} catch {}
            }            
        }
        
        // update distributor values
        if (!_isExcluded[from]) {
            _distributor.setShare(from, balanceOf(from));
        }
        if (!_isExcluded[to]) {
            _distributor.setShare(to, balanceOf(to));
        }
        return true;
    }
    
    /** Should Contract Sell Down Tokens For BNB */
    function shouldSwapBack(address from) public view returns(bool) {
        return balanceOf(address(this)) >= _tokenSwapThreshold 
            && !currentlySwapping 
            && !exemptions[from].isLiquidityPool
            && !exemptions[msg.sender].isGasExempt;
    }
    
    function getFee(address sender, address recipient, bool takeFee) internal view returns (uint256) {
        if (!takeFee) return 0;
        return exemptions[recipient].isLiquidityPool ? _sellFee : exemptions[sender].isLiquidityPool ? _buyFee : _transferFee;
    }
    
    /**
     * @notice Handles the transfer of tokens
     */
    function _tokenTransfer(address sender, address recipient, uint256 tAmount, bool takeFee) private {

        // Calculate the values required to execute a transfer
        uint256 fee = getFee(sender, recipient, takeFee);
        // take fee out of transfer amount
        uint256 tFee = tAmount.mul(fee).div(feeDenominator);
        // new transfer amount
        uint256 tTransferAmount = tAmount.sub(tFee);
        // get R Values
        (uint256 rAmount, uint256 rTransferAmount,) = _getRValues(tAmount, tFee, _getRate());
        
        // Take Tokens From Sender
		if (_isExcluded[sender]) {
		    _tOwned[sender] = _tOwned[sender].sub(tAmount);
		}
		_rOwned[sender] = _rOwned[sender].sub(rAmount);
		
		// Give Taxed Amount To Recipient
		if (_isExcluded[recipient]) {
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
		}
		_rOwned[recipient] = _rOwned[recipient].add(rTransferAmount); 
		
		// apply fees if applicable
		if (takeFee) {
		    
            // burn tokens
	    	uint256 burnAmount = tFee.mul(_burnPercentage).div(100);
            if (burnAmount > 0) {
                _burnTokens(sender, burnAmount);
            }

            // amount to reflect in either BNB or self
            uint256 reflectAmount = tFee.sub(burnAmount);

            if (exemptions[recipient].isLiquidityPool) {      // sold
                _takeTokens(sender, reflectAmount);
            } else if (exemptions[sender].isLiquidityPool) {  // bought
                _reflectTokens(reflectAmount);
            } else {                                          // transferred
                _reflectTokens(reflectAmount);
            }
        
            // Emit Fee Distribution
            emit FeesDistributed(burnAmount, reflectAmount);
		}
		
        // Emit Transfer
        emit Transfer(sender, recipient, tTransferAmount);
    }
    
    /**
     * @notice Burns CRIB tokens straight to the burn address
     */
    function _burnTokens(address sender, uint256 tFee) private {
        _sendTokens(sender, _burnWallet, tFee);
    }
    
    /**
     * @notice The contract takes a portion of tokens from taxed transactions
     */
    function _takeTokens(address sender, uint256 tTakeAmount) private {
        _sendTokens(sender, address(this), tTakeAmount);
    }
    
    /**
     * @notice Allocates Tokens To Address
     */
    function _sendTokens(address sender, address receiver, uint256 tAmount) private {
        uint256 rAmount = tAmount.mul(_getRate());
        _rOwned[receiver] = _rOwned[receiver].add(rAmount);
        if(_isExcluded[receiver]) {
            _tOwned[receiver] = _tOwned[receiver].add(tAmount);
        }
        emit Transfer(sender, receiver, tAmount);
    }

    /**
     * @notice Increases the rate of how many reflections each token is worth
     */
    function _reflectTokens(uint256 tFee) private {
        uint256 rFee = tFee.mul(_getRate());
        _rTotal = _rTotal.sub(rFee);
        _totalReflections = _totalReflections.add(tFee);
    }
    
    /**
     * @notice Excludes an address from receiving reflections
     */
    function _excludeFromReward(address account) private {
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }
    
    /**
     * @notice Sells Down Tokens For BNB - Sends To Distributor For Rewards
     */
    function swapBack(uint256 tokenAmount) private lockSwapping {

        // Swap Tokens for BNB
        swapTokensForBNB(tokenAmount);

        // Send BNB received to the distributor
        if (address(this).balance > 0) {
            (bool success,) = payable(address(_distributor)).call{value: address(this).balance}("");
            require(success, 'Failure on Distributor Payment');
        }
        
        emit SwappedBack(tokenAmount);
    }

    /**
     * @notice Swap tokens for BNB storing the resulting BNB in the contract
     */
    function swapTokensForBNB(uint256 tokenAmount) private {
        
        // approve router for token amount
        _allowances[address(this)][address(_router)] = 2*tokenAmount;

        // Execute the swap
        _router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp + 300
        );
    }
    
    receive() external payable {}  // to receive bnb
    
    
    ////////////////////////////////////////////
    ////////          EVENTS           /////////
    ////////////////////////////////////////////
    
    event SwappedBack(uint256 swapAmount);
    event SetExemptions(address account, bool feeExempt, bool isLP, bool txLimitExempt, bool gasExempt);
    event FeesDistributed(uint256 burnPortion, uint256 reflectPortion);
    event TransferOwnership(address newOwner);
    event OwnerWithdraw(address token, uint256 amount);
    event UpdatedRouterAddress(address newRouter);
    event UpdatedPairAddress(address newPair);
    event ExcludeFromRewards(address account);
    event SetMaxTxAmount(uint256 newAmount);
    event UpgradedDistributor(address newDistributor); 
    event SetTokenSwapThreshold(uint256 tokenSwapThreshold);
    event SetFees(uint256 burnPercentage, uint256 sellFee, uint256 buyFee, uint256 transferFee);
    event IncludeInRewards(address account);
    event SetDistributorGas(uint256 gas);
    
}