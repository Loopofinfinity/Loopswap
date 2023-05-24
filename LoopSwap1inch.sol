// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./I1inch.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface I1inch {
    function getExpectedReturn(
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 parts,
        uint256 flags
    )
        external
        view
        returns (uint256, uint256[] memory);
}
contract LoopSwap is ReentrancyGuard {
    using SafeMath for uint256;
    address public owner;
    I1inch public oneInch;
    mapping(address => mapping(address => uint256)) public balances;
    mapping(address => bool) public tokensListed;
     bool public paused = false; // Add a pause variable

    // ...

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }
    // Add the `whenNotPaused` modifier to the functions that should only execute when the contract is not paused

    event Deposit(address indexed token, address indexed user, uint256 amount);
    event Withdraw(address indexed token, address indexed user, uint256 amount);
    event Trade(
        address indexed user,
        address indexed fromToken,
        address indexed toToken,
        uint256 fromAmount,
        uint256 toAmount
    );
    event AddLiquidity(
        address indexed user,
        address indexed token1,
        address indexed token2,
        uint256 amount1,
        uint256 amount2,
        uint256 liquidity
    );
    event RemoveLiquidity(
        address indexed user,
        address indexed token1,
        address indexed token2,
        uint256 amount1,
        uint256 amount2,
        uint256 liquidity
    );
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(I1inch _oneInch) {
    owner = msg.sender;
    require(_oneInch != I1inch(address(0)), "Invalid 1inch contract address");
    oneInch = _oneInch;
}

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    modifier tokenListed(address _token) {
    require(tokensListed[_token], "Token not listed");
    _;
}

    function approve(address _token, address _spender, uint256 _amount) external onlyOwner tokenListed(_token) whenNotPaused {
    require(_amount > 0 && _amount <= IERC20(_token).balanceOf(address(this)), "Approval amount should be greater than zero and not exceed contract balance");
    require(_token != address(0) && _spender != address(0), "Invalid token address");
    require(tokensListed[_token], "Token not listed");
    require(IERC20(_token).approve(_spender, _amount), "Approval failed");
    require(IERC20(_token).allowance(address(this), _spender) == _amount, "Approval failed");

    // Check if the _spender is a valid contract that implements the IERC20 interface
   (bool success, bytes memory result) = _spender.call(abi.encodeWithSignature("supportsInterface(bytes4)", bytes4(keccak256("approve(address,uint256)"))));
require(success && keccak256(result) == keccak256("true"), "Invalid spender contract or cannot receive approval");

    emit Approval(msg.sender, _spender, _amount);
}

function transferFrom(address _token, address _from, address _to, uint256 _amount) external tokenListed(_token) whenNotPaused {
    require(_token != address(0) && _from != address(0) && _to != address(0), "Invalid address");
    require(tokensListed[_token], "Token not listed");
    require(IERC20(_token).balanceOf(_from) >= _amount, "Insufficient balance");
    require(IERC20(_token).allowance(_from, msg.sender) >= _amount, "Allowance not set");
    require(msg.sender == _from || msg.sender == owner, "Only the owner or the token holder can call this function");

    // Check if the recipient is a valid Ethereum address
    uint32 size;
    assembly {
        size := extcodesize(_to)
    }
    require(size == 0, "Recipient cannot be a contract");

    require(IERC20(_token).transferFrom(_from, _to, _amount), "Transfer failed");
    balances[_token][_from] = balances[_token][_from].sub(_amount); // update the sender's balance
    balances[_token][_to] = balances[_token][_to].add(_amount); // update the recipient's balance
}

function deposit(address _token, uint256 _amount) external whenNotPaused {
    require(_token != address(0), "Invalid token address");
    require(tokensListed[_token], "Token not listed");
    require(_amount > 0, "Deposit amount should be greater than zero");

    // Check if the sender has already approved the contract to transfer the deposited tokens on their behalf
    require(IERC20(_token).allowance(msg.sender, address(this)) >= _amount, "Contract not authorized to transfer tokens on behalf of the sender");

    require(IERC20(_token).transferFrom(msg.sender, address(this), _amount), "Transfer failed");
    balances[_token][msg.sender] = balances[_token][msg.sender].add(_amount);

    emit Deposit(_token, msg.sender, _amount);
}


function withdraw(address _token, uint256 _amount) external whenNotPaused {
    require(_token != address(0), "Invalid token address");
    require(_amount > 0, "Amount should be greater than zero");
    require(balances[_token][msg.sender] >= _amount, "Insufficient balance");
    require(tokensListed[_token], "Token not listed");
    require(IERC20(_token).transfer(msg.sender, _amount), "Withdrawal failed");
    balances[_token][msg.sender] = balances[_token][msg.sender].sub(_amount); // update the balances mapping
    emit Withdraw(_token, msg.sender, _amount);
}

function trade(address _fromToken, address _toToken, uint256 _fromAmount, uint256 _expectedReturn) external whenNotPaused {
    require(_fromAmount > 0, "Amount should be greater than zero");
    require(tokensListed[_fromToken], "From token not listed");
    require(tokensListed[_fromToken] && tokensListed[_toToken], "Tokens not listed");
    require(_fromToken != address(0) && _toToken != address(0), "Invalid token address");
    require(IERC20(_fromToken).allowance(msg.sender, address(this)) >= _fromAmount, "Allowance not set");

    (uint256 expected, uint256[] memory distribution) = oneInch.getExpectedReturn(_fromToken, _toToken, _fromAmount, 10, 0);

    require(expected > 0 && expected <= _expectedReturn, "Unexpected return amount from 1inch");

    require(IERC20(_fromToken).transferFrom(msg.sender, address(this), _fromAmount), "Transfer from failed");

    uint256 fee = _fromAmount.mul(3).div(1000);
    uint256 amountAfterFee = _fromAmount.sub(fee);

    (bool success, ) = _toToken.call(abi.encodeWithSelector(0x23b872dd, amountAfterFee, distribution, address(this), type(uint256).max));
    require(success, "1inch swap failed");

    uint256 received = IERC20(_toToken).balanceOf(address(this));
    require(received > 0, "Received amount should be greater than zero");

    require(IERC20(_toToken).transfer(owner, received), "Transfer to owner failed");

    emit Trade(msg.sender, _fromToken, _toToken, _fromAmount, received);
}

function swap(address _fromToken, address _toToken, uint256 _fromAmount) external whenNotPaused {
    require(_fromAmount > 0, "Amount should be greater than zero");
    require(tokensListed[_fromToken] && tokensListed[_toToken], "Tokens not listed");
    require(_fromToken != address(0) && _toToken != address(0), "Invalid token address");
    require(IERC20(_fromToken).allowance(msg.sender, address(this)) >= _fromAmount, "Allowance not set");

    // Transfer input token from user to contract
    require(IERC20(_fromToken).transferFrom(msg.sender, address(this), _fromAmount), "Transfer from failed");
    
    // Get expected output amount from 1inch
    (uint256 toAmount, ) = oneInch.getExpectedReturn(_fromToken, _toToken, _fromAmount, 1, 100);
    require(toAmount > 0, "No tokens received from exchange");

    // Transfer output token to user
    require(IERC20(_toToken).transfer(msg.sender, toAmount), "Transfer to failed");
    
    emit Trade(msg.sender, _fromToken, _toToken, _fromAmount, toAmount);
}

function withdrawFee(address _token) external onlyOwner tokenListed(_token) whenNotPaused {
    require(_token != address(0), "Invalid token address");
    uint256 balance = IERC20(_token).balanceOf(address(this));
    require(balance > 0, "No balance to withdraw");
    require(IERC20(_token).transfer(owner, balance), "Transfer failed");
}

  function addLiquidity(
    address _token1,
    address _token2,
    uint256 _amount1,
    uint256 _amount2
) external {
    require(_token1 != address(0) && _token2 != address(0), "Invalid token address");
    require(_amount1 > 0 && _amount2 > 0, "Amounts should be greater than zero");
    require(IERC20(_token1).balanceOf(msg.sender) >= _amount1, "Insufficient balance of token 1");
    require(IERC20(_token2).balanceOf(msg.sender) >= _amount2, "Insufficient balance of token 2");
    
    uint256 liquidity;
    if (balances[_token1][msg.sender] == 0 || balances[_token2][msg.sender] == 0) {
        liquidity = _amount1 < _amount2 ? _amount1 : _amount2;
    } else {
        uint256 existingLiquidity = balances[_token1][msg.sender];
        liquidity = (existingLiquidity * _amount1) / balances[_token1][msg.sender];
    }

    IERC20(_token1).transferFrom(msg.sender, address(this), _amount1);
    IERC20(_token2).transferFrom(msg.sender, address(this), _amount2);
    
    balances[_token1][msg.sender] += _amount1;
    balances[_token2][msg.sender] += _amount2;
    tokensListed[_token1] = true;
    tokensListed[_token2] = true;

    emit AddLiquidity(msg.sender, _token1, _token2, _amount1, _amount2, liquidity);
}

function removeLiquidity(address _token1, address _token2, uint256 _liquidity) external whenNotPaused {
    require(_token1 != address(0) && _token2 != address(0), "Invalid token address");
    require(_liquidity > 0, "Liquidity should be greater than zero");
    require(balances[_token1][msg.sender] >= _liquidity && balances[_token2][msg.sender] >= _liquidity, "Not enough liquidity");

    uint256 amount1 = (_liquidity * IERC20(_token1).balanceOf(address(this))) / balances[_token1][msg.sender];
    uint256 amount2 = (_liquidity * IERC20(_token2).balanceOf(address(this))) / balances[_token2][msg.sender];

    require(amount1 > 0 && amount2 > 0, "Insufficient liquidity in the pool");

    balances[_token1][msg.sender] -= _liquidity;
    balances[_token2][msg.sender] -= _liquidity;

    IERC20(_token1).transfer(msg.sender, amount1);
    IERC20(_token2).transfer(msg.sender, amount2);

    emit RemoveLiquidity(msg.sender, _token1, _token2, amount1, amount2, _liquidity);
}

function setTokenListed(address _token, bool _isListed) external {
    require(msg.sender == owner, "Not authorized");
    tokensListed[_token] = _isListed;
}

function removeToken(address _token) external onlyOwner whenNotPaused {
    require(tokensListed[_token], "Token not listed");
    tokensListed[_token] = false;
}

function getBalance(address _token, address _user) external view returns (uint256) {
    return balances[_token][_user];
}

}
