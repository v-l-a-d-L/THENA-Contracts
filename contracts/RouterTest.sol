// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Math {
    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'Math: Sub-underflow');
    }
}

interface IPair {
    function metadata() external view returns (uint dec0, uint dec1, uint r0, uint r1, bool st, address t0, address t1);
    function claimFees() external returns (uint, uint);
    function tokens() external view returns (address, address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function transferFrom(address src, address dst, uint amount) external returns (bool);
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function burn(address to) external returns (uint amount0, uint amount1);
    function mint(address to) external returns (uint liquidity);
    function getReserves() external view returns (uint _reserve0, uint _reserve1, uint _blockTimestampLast);
    function getAmountOut(uint, address) external view returns (uint);
    function name() external view returns(string memory);
    function symbol() external view returns(string memory);
    function totalSupply() external view returns (uint);
    function decimals() external view returns (uint8);
    function claimable0(address _user) external view returns (uint);
    function claimable1(address _user) external view returns (uint);
    function isStable() external view returns(bool);
}

interface IPairFactory {
    function allPairsLength() external view returns (uint);
    function isPair(address pair) external view returns (bool);
    function allPairs(uint index) external view returns (address);
    function pairCodeHash() external pure returns (bytes32);
    function getPair(address tokenA, address token, bool stable) external view returns (address);
    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair);
    function getFee(bool _stable) external view returns(uint256);
    function MAX_REFERRAL_FEE() external view returns(uint256);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

interface IRouter {
    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);
}

interface erc20 {
    function totalSupply() external view returns (uint256);
    function transfer(address recipient, uint amount) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function balanceOf(address) external view returns (uint);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
}

contract RouterSolo {

    using Math for uint;

    struct route {
        address from;
        address to;
        bool stable;
    }

    address public immutable factory;
    IWETH public immutable wETH;
    uint internal constant MINIMUM_LIQUIDITY = 10**3;
    bytes32 immutable pairCodeHash;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'BaseV1Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _wETH) {
        factory = _factory;
        pairCodeHash = IPairFactory(_factory).pairCodeHash();
        wETH = IWETH(_wETH);
    }

     function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'BaseV1Router: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'BaseV1Router: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB, bool stable) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex'ff',
            factory,
            keccak256(abi.encodePacked(token0, token1, stable)),
            pairCodeHash // init code hash
        )))));
    }

    function _calculateSwapAmount(
        uint amount, 
        uint reserve,
        uint fee
    ) internal pure returns(uint amountSwap, uint amountKeep){
        uint _a = fee;
        uint _b = reserve*(1+fee);
        uint _c = amount*reserve;
        amountSwap = (Math.sqrt(_b**2 + 4*_a*_c) - _b)/2*_a;
        amountKeep = amount - amountSwap;
    }

    function addLiquitidyBySingleToken(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountA,
        uint deadline
    ) external ensure(deadline) returns(uint liquidity){
        address _pair = IPairFactory(factory).getPair(tokenA, tokenB, stable);
        require(_pair != address(0), 'PAIR_NOT_EXISTS');
        uint _reserveA;
        uint _reserveB;
        if(tokenA > tokenB){
            (_reserveB,_reserveA,) = IPair(_pair).getReserves();
        }
        else{
            (_reserveA,_reserveB,) = IPair(_pair).getReserves();
        }
        require(_reserveA > 0 && _reserveB > 0, 'ZERO_LIQUIDITY');
        uint fee = IPairFactory(factory).getFee(stable);
        (uint amountSwap, uint amountKeep) = _calculateSwapAmount(amountA, _reserveA, fee);
        uint amountGet = _reserveB - _reserveB * _reserveA / (_reserveA / amountSwap);
        require(amountGet > 0 && amountSwap > 0 && amountKeep > 0, 'INVALID_AMOUNT');
        liquidity = _addLiquitidyBySingleToken(_pair, tokenA, tokenB,amountSwap, amountKeep, amountGet);
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
        _safeTransferFrom(tokenA, msg.sender, _pair, amountSwap + amountKeep);
        IPair(_pair).swap(token0, token1, _pair, new bytes(0));
        liquidity = IPair(_pair).mint(msg.sender);
    }
    
    function addLiquitidyBySingleETH(
        address tokenB,
        bool stable,
        uint amountETH,
        uint deadline
    ) payable external ensure(deadline) returns(uint liquidity){
        address _pair = IPairFactory(factory).getPair(address(wETH), tokenB, stable);
        require(_pair != address(0), 'PAIR_NOT_EXISTS');
        uint _reserveETH;
        uint _reserveB;
        if(address(wETH) > tokenB){
            (_reserveB,_reserveETH,) = IPair(_pair).getReserves();
        }
        else{
            (_reserveETH,_reserveB,) = IPair(_pair).getReserves();
        }
        require(_reserveETH > 0 && _reserveB > 0, 'ZERO_LIQUIDITY');
        uint fee = IPairFactory(factory).getFee(stable);
        (uint amountSwap, uint amountKeep) = _calculateSwapAmount(amountETH, _reserveETH, fee);
        uint amountGet = _reserveB - _reserveB * _reserveETH / (_reserveETH / amountSwap);
        require(amountGet > 0 && amountSwap > 0 && amountKeep > 0, 'INVALID_AMOUNT');
        liquidity = _addLiquitidyBySingleETH(_pair, tokenB, amountSwap, amountKeep, amountGet);
    } 

    function _addLiquitidyBySingleETH(
        address _pair, 
        address tokenB, 
        uint amountSwap, 
        uint amountKeep, 
        uint amountGet
    ) internal returns(uint liquidity){
        (uint token0, uint token1) = address(wETH) > tokenB ? (amountGet, uint(0)) : (uint(0), amountGet);
        wETH.deposit{value: amountKeep + amountSwap}();
        assert(wETH.transfer(_pair, amountKeep + amountSwap));
        if (msg.value > amountKeep + amountSwap) _safeTransferETH(msg.sender, msg.value - (amountKeep + amountSwap));
        IPair(_pair).swap(token0, token1, _pair, new bytes(0));
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
        require(amountA >= amountAMin, 'BaseV1Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'BaseV1Router: INSUFFICIENT_B_AMOUNT');
    }

    function removeLiquidityETH(
        address token,
        bool stable,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            address(wETH),
            stable,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        _safeTransfer(token, to, amountToken);
        wETH.withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    function _safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
