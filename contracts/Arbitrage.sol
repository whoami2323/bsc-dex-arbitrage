//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WBNB.sol";
import "./interfaces/IChiToken.sol";

import "./libraries/PancakeLibrary.sol";

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router02.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Arbitrage is Ownable {
    using SafeMath for uint;
    
    event Gordon(address tokenBorrow, uint amountIn, uint amount0, uint amount1);
    
    IChiToken public chiToken;
    mapping(address => bool) public arbWallets;

    receive() payable external {}

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }
    modifier gasTokenRefund {
        uint256 gasStart = gasleft();
        _;
        uint256 gasSpent = 21000 + gasStart - gasleft() + 16 * msg.data.length;
        chiToken.freeUpTo((gasSpent + 14154) / 41947);
    }
    modifier onlyArbs {
        require(arbWallets[msg.sender] == true, "No Soup You");
        _;
    }

    constructor (address _gasToken, address[] _arbWallets) {
        chiToken = IChiToken(_gasToken);
        arbWallets[this.owner()] = true;
        if (_arbWallets.length > 0) {
            for (uint i=0;i<_arbWallets.length;i++) {
                arbWallets[_arbWallets[i]] = true;
            }
        }
    }
    function mintGasToken(uint amount) public {
        chiToken.mint(amount);
    }
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))),"TransferHelper: TRANSFER_FROM_FAILED");
    }
    function _swap(uint256[] memory amounts, address[] memory path, address[] memory pairPath, address _to) internal {
        for (uint256 i; i < pairPath.length; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = PancakeLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < pairPath.length - 1 ? pairPath[i + 1] : _to;
            IUniswapV2Pair(pairPath[i]).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }
    function getAmountsOut(uint _amountIn, address[] memory _path, address[] memory _pairPath, uint[] memory _fee) external view returns (uint[] memory) {
        return PancakeLibrary.getAmountsOut(_amountIn, _path, _pairPath, _fee);
    }
    // hawk is a simple minded desk trader that does exactly what he is told, using funds held by this contract
    function hawk(uint _amountIn, address _tokenFrom, address _tokenTo, address _router, uint deadline) external payable ensure(deadline) onlyArbs gasTokenRefund {
        if (msg.value > 0) {
            // Assumes _tokenFrom is WBNB 
            WBNB(_path[0]).deposit{value:msg.value, gas:50000}();
        }
        address factory = IUniswapV2Router01(_router).factory();
        address pairAddress = IUniswapV2Factory(factory).getPair(_tokenFrom, _tokenTo);
        require(pairAddress != address(0), "Pool does not exist");
        safeTransferFrom(_tokenFrom, address(this), pairAddress, _amountIn);
        _swap([_amountIn], [_tokenFrom, _tokenTo], [pairAddress], address(this));
    }
    // budFox does advanced trades using funds held by this contract
    function budFox(uint _amountIn, address[] memory _path, address[] memory _pairPath, uint deadline) external payable ensure(deadline) onlyArbs gasTokenRefund {
        if (msg.value > 0) {
            // Assumes _path[0] is WBNB
            WBNB(_path[0]).deposit{value:msg.value, gas:50000}();
        }
        address factory = IUniswapV2Router01(_router).factory();
        address pairAddress = IUniswapV2Factory(factory).getPair(_tokenFrom, _tokenTo);
        require(pairAddress != address(0), "Pool does not exist");
        safeTransferFrom(_tokenFrom, address(this), pairAddress, _amountIn);
        _swap([_amountIn], _path, _pairPath, address(this));
    }
    // gordon uses funds loaned to him to perform advanced trades
    function gordon(uint _amountIn, address _loanFactory, address[] memory _loanPair, address[] memory _path, address[] memory _pairPath, uint[] memory _swapFees, uint deadline) external payable ensure(deadline) onlyArbs gasTokenRefund {
        if (msg.value > 0) {
            // Assumes _path[0] is WBNB
            WBNB(_path[0]).deposit{value:msg.value, gas:50000}();
        }
        address flashToken0 = _loanPair[0];
        address flashToken1 = _loanPair[1];
        address flashFactory = _loanFactory;
        
        address pairAddress = IUniswapV2Factory(flashFactory).getPair(flashToken0, flashToken1);
        require(pairAddress != address(0), "Pool does not exist");

        address token0 = IUniswapV2Pair(pairAddress).token0();
        address token1 = IUniswapV2Pair(pairAddress).token1();

        uint amount0Out = flashToken0 == token0 ? _amountIn : 0;
        uint amount1Out = flashToken0 == token1 ? _amountIn : 0;

        bytes memory data = abi.encode(_amountIn,_path,_pairPath,flashFactory,_swapFees);

        IUniswapV2Pair(pairAddress).swap(
            amount0Out,
            amount1Out,
            address(this),
            data
        );
    }
    function pancakeCall(address _sender, uint _amount0, uint _amount1, bytes calldata _data) external {
        require(msg.sender == pair, "Sender not pair");
        require(_sender == address(this), "Not sender");
        (uint amountIn, address[] memory path, address[] memory pairPath, address flashFactory, uint[] memory swapFees) = abi.decode(_data, (uint, address[], address[], address, uint[]));

        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(flashFactory).getPair(token0, token1);
        
        emit Gordon(path[0], amountIn, _amount0, _amount1);

        uint256[] memory amounts = PancakeLibrary.getAmountsOut(amountIn,path,pairPath,fee);
        safeTransferFrom(path[0], address(this), pairPath[0], amounts[0]);
        _swap(amounts, path, pairPath, to);

        uint amountReceived = amounts[amounts.length - 1];

        // Pay back flashloan
        uint fee = ((amountIn * 3)/ 997) +1;
        uint amountToRepay = amountIn+fee;

        require(amountReceived>amountIn,"Not profitable");
        require(amountReceived>amountToRepay,"Could not afford loan fees");
        IERC20(path[0]).transfer(msg.sender, amountToRepay);
    }
    function withdraw(uint _amount, address _token, bool isBNB) public onlyOwner {
        if (isBNB){
            _amount > 0 ? payable(msg.sender).send(_amount) : payable(msg.sender).send(address(this).balance);
        } else{
            _amount > 0 ? IERC20(_token).transfer(msg.sender, _amount) : IERC20(_token).transfer(msg.sender, IERC20(_token).balanceOf(address(this)));
        }
    }
    function addArbWallets(address[] memory _newArbs) public onlyOwner {
        for (uint i=0;i<_newArbs.length;i++) {
            arbWallets[_newArbs[i]] = true;
        }
    }
    function removeArbWallets(address[] memory _oldArbs) public onlyOwner {
        for (uint i=0;i<_oldArbs.length;i++) {
            delete arbWallets[_oldPandas[i]];
        }
    }
}
