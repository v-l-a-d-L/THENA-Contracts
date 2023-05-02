// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "contracts/libraries/Math.sol";
import "contracts/interfaces/IPair.sol";
import "contracts/interfaces/IPairFactory.sol";
import "contracts/interfaces/IRouter.sol";

interface ISPairFactory is IPairFactory{
    function getFee(bool _stable) external view returns(uint256);
}

interface erc20 {
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
}

contract RouterSolo {

    using Math for uint;

    address public immutable factory;
    bytes32 immutable pairCodeHash;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'BaseV1Router: EXPIRED');
        _;
    }

    constructor(address _factory) {
        factory = _factory;
        pairCodeHash = ISPairFactory(_factory).pairCodeHash();
    }
    
    function pairFor(
        address tokenA, 
        address tokenB, 
        bool stable
    ) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex'ff',
            factory,
            keccak256(abi.encodePacked(token0, token1, stable)),
            pairCodeHash // init code hash
        )))));
    }

     function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'ZERO_ADDRESS');
    }

    function _directionToZero(uint x, uint amountA, address _pair, address tokenA) internal  view returns(bool direction){
        uint reserveA;
        uint reserveB;
        if(tokenA == IPair(_pair).token0()){
            (reserveA,reserveB,) = IPair(_pair).getReserves();
        }
        else{
            (reserveB,reserveA,) = IPair(_pair).getReserves();
        }
        if(IPair(_pair).getAmountOut(x,tokenA)*(reserveA+amountA)> reserveB*x){
            direction = true;
        }
        else{
            direction = false;
        }
    }
    function calculateSwapStable(
        uint amountA, 
        address tokenA,
        address tokenB
    ) public view returns(uint amountSwap, uint amountKeep, uint amountGet){
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, true);
        uint alpha = amountA/2;
        uint x = amountA/2;
        bool direction = true;
        while(alpha > 0){
            bool _d = _directionToZero(x,amountA, _pair, tokenA);
            if(direction != _d) {
                alpha/=2; direction = _d;
            }
            uint _x = direction == false? x - alpha: x + alpha;
            if(_x == x){
                break;
            }
            if(_x > 0 && _x < amountA){
                x = _x;
            }
            else{
                alpha/=2;
            }
        }
        amountSwap = amountA - x;
        amountKeep = x;
        amountGet = IPair(_pair).getAmountOut(amountSwap,tokenA);
    }

    function calculateSwapValidated(
        uint amountA, 
        address tokenA,
        address tokenB
    ) public view returns(uint amountSwap, uint amountKeep, uint amountGet){
        address _pair = ISPairFactory(factory).getPair(tokenA, tokenB, false);
        uint reserveA;
        uint reserveB;
        if(tokenA > tokenB){
            (reserveB,reserveA,) = IPair(_pair).getReserves();
        }
        else{
            (reserveA,reserveB,) = IPair(_pair).getReserves();
        }
        uint fee = (1e4-ISPairFactory(factory).getFee(false));
        uint _a = fee*fee;
        uint _b = reserveA*(1e4+fee);
        uint _c = reserveA*amountA;
        amountSwap = (Math.sqrt((_b * _b) + (4* _a * _c)) - _b) * 1e4 / (2* _a);
        amountKeep = amountA - amountSwap;
        amountGet = reserveB*amountSwap * fee / (fee  * amountSwap + reserveA * 1e4);
    }

    function addLiquitidyBySingleToken(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountA,
        uint deadline
    ) external ensure(deadline) returns(uint liquidity){
        require(ISPairFactory(factory).getPair(tokenA, tokenB, stable) != address(0), 'PAIR_NOT_EXISTS');
        {
        (uint reserveB, uint reserveA,) = IPair(ISPairFactory(factory).getPair(tokenA, tokenB, stable)).getReserves();
        require(reserveA > 0 && reserveB > 0, 'ZERO_LIQUIDITY');
        }
        (uint amountSwap, 
        uint amountKeep, 
        uint amountGet) = stable == true ? calculateSwapValidated(amountA, tokenA, tokenB) : calculateSwapValidated(amountA, tokenA, tokenB);
        require(amountGet > 0 && amountSwap > 0 && amountKeep > 0, 'INVALID_AMOUNT');
        liquidity = _addLiquitidyBySingleToken(
            ISPairFactory(factory).getPair(tokenA, tokenB, stable), 
            tokenA, 
            tokenB,
            amountSwap, 
            amountKeep, 
            amountGet);
    } 

    function _addLiquitidyBySingleToken(
        address _pair,
        address tokenA, 
        address tokenB, 
        uint amountSwap, 
        uint amountKeep, 
        uint amountGet
    ) internal returns(uint liquidity){
        (uint token0, uint token1) = tokenA > tokenB ? (amountGet, uint(0)) : (uint(0), amountGet);
        _safeTransferFrom(tokenA, msg.sender, _pair, amountSwap);
        IPair(_pair).swap(token0, token1, _pair, new bytes(0));
        _safeTransferFrom(tokenA, msg.sender, _pair, amountKeep);
        liquidity = IPair(_pair).mint(msg.sender);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = pairFor(tokenA, tokenB, stable);
        require(IPair(pair).transferFrom(msg.sender, pair, liquidity)); // send liquidity to pair
        (uint amount0, uint amount1) = IPair(pair).burn(to);
        (address token0,) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'INSUFFICIENT_B_AMOUNT');
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
