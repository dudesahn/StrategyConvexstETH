// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/curve.sol";
import "./interfaces/yearn.sol";
import {IUniswapV2Router02} from "./interfaces/uniswap.sol";
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";

contract StrategyCurveIBVoterProxy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant gauge =
        address(0xF5194c3325202F456c95c1Cf0cA36f8475C1949F); // Curve Iron Bank Gauge contract, v2 is tokenized, held by Yearn's voter
    ICurveStrategyProxy public proxy =
        ICurveStrategyProxy(
            address(0x9a165622a744C20E3B2CB443AeD98110a33a231b)
        ); // Yearn's Updated v3 StrategyProxy

    uint256 public optimal = 0;

    ICurveFi public constant curve =
        ICurveFi(address(0x2dded6Da1BF5DBdF597C45fcFaa3194e53EcfeAF)); // Curve Iron Bank Pool
    address public voter = address(0xF147b8125d2ef93FB6965Db97D6746952a133934); // Yearn's veCRV voter
    address public crvRouter =
        address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F); // default to sushiswap, more CRV liquidity there
    address[] public crvPath;

    uint256 public crvMinimum = 12500000000000000000000; // minimum amount of CRV needed for tend or harvest to trigger, default is 12,500 CRV
    uint256 public tendProfitFactor = 250; // reevaluate this if CRV or gas price changes drastically, currently 100-300 gwei and $2.50/CRV
    uint256 public harvestProfitFactor = 230; // reevaluate this if CRV or gas price changes drastically, currently 100-300 gwei and $2.50/CRV

    // this controls the number of tends before we harvest
    uint256 public tendCounter = 0;
    uint256 public tendsPerHarvest = 3;
    uint256 private harvestNow = 0; // 0 for false, 1 for true if we are mid-harvest

    ICrvV3 public constant crv =
        ICrvV3(address(0xD533a949740bb3306d119CC777fa900bA034cd52));
    IERC20 public constant weth =
        IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 public constant dai =
        IERC20(address(0x6B175474E89094C44Da98b954EedeAC495271d0F));
    IERC20 public constant usdc =
        IERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
    IERC20 public constant usdt =
        IERC20(address(0xdAC17F958D2ee523a2206206994597C13D831ec7));

    uint256 public keepCRV = 1000;
    uint256 public constant FEE_DENOMINATOR = 10000;

    uint256 public checkLiqGauge = 0; // 1 is for TRUE value and 0 for FALSE to keep in sync with binary convention
    uint256 public constant CHECK_LIQ_GAUGE_TRUE = 1;
    uint256 public constant CHECK_LIQ_GAUGE_FALSE = 0;

    uint256 public constant USE_SUSHI = 1;
    address public constant sushiswapRouter =
        address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    address public constant uniswapRouter =
        address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        minReportDelay = 172800; // 2 days
        maxReportDelay = 604800; // 7 days
        debtThreshold = 400 * 1e18; // we shouldn't ever have debt, but set a bit of a buffer

        // want = crvIB, Curve's Iron Bank pool (ycDai+ycUsdc+ycUsdt)
        want.safeApprove(address(proxy), uint256(-1));

        // add approvals for crv on sushiswap and uniswap due to weird crv approval issues for setCrvRouter
        // add approvals on all tokens
        crv.approve(uniswapRouter, uint256(-1));
        crv.approve(sushiswapRouter, uint256(-1));
        dai.safeApprove(address(curve), uint256(-1));
        usdc.safeApprove(address(curve), uint256(-1));
        usdt.safeApprove(address(curve), uint256(-1));

        crvPath = new address[](3);
        crvPath[0] = address(crv);
        crvPath[1] = address(weth);
        crvPath[2] = address(dai);
    }

    //////// JUST USE THESE FUNCTIONS IN TESTING, REMOVE BEFORE DEPLOYING /////////////////////////////////
    // look at the average price when swapping min CRV
    function crvPrice() external view returns (uint256) {
        address[] memory harvestPath = new address[](3);
        harvestPath[0] = address(crv);
        harvestPath[1] = address(weth);
        harvestPath[2] = address(dai);

        uint256[] memory _crvDollarsOut =
            IUniswapV2Router02(crvRouter).getAmountsOut(
                crvMinimum,
                harvestPath
            );
        uint256 crvDollarsOut =
            _crvDollarsOut[_crvDollarsOut.length - 1] / (10**18);
        return crvDollarsOut;
    }

    //////////////////////////////////////////////////

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyCurveIBVoterProxy";
    }

    // total assets held by strategy
    function estimatedTotalAssets() public view override returns (uint256) {
        return proxy.balanceOf(gauge).add(want.balanceOf(address(this)));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        // if we have anything in the gauge, then harvest CRV from the gauge
        uint256 gaugeTokens = proxy.balanceOf(gauge);
        if (gaugeTokens > 0) {
            proxy.harvest(gauge);
            uint256 crvBalance = crv.balanceOf(address(this));
            uint256 _keepCRV = crvBalance.mul(keepCRV).div(FEE_DENOMINATOR);
            IERC20(address(crv)).safeTransfer(voter, _keepCRV);
            uint256 crvRemainder = crvBalance.sub(_keepCRV);

            _sell(crvRemainder);

            if (optimal == 0) {
                uint256 daiBalance = dai.balanceOf(address(this));
                curve.add_liquidity([daiBalance, 0, 0], 0, true);
            } else if (optimal == 1) {
                uint256 usdcBalance = usdc.balanceOf(address(this));
                curve.add_liquidity([0, usdcBalance, 0], 0, true);
            } else {
                uint256 usdtBalance = usdt.balanceOf(address(this));
                curve.add_liquidity([0, 0, usdtBalance], 0, true);
            }
        }
        // this is a harvest, so set our switch equal to 1 so this
        // performs as a harvest the whole way through
        harvestNow = 1;
        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = want.balanceOf(address(this));
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt.sub(assets);
            _profit = 0;
        }

        // debtOustanding will only be > 0 in the event of revoking or lowering debtRatio of a strategy
        if (_debtOutstanding > 0) {
            uint256 stakedBal = proxy.balanceOf(gauge);
            proxy.withdraw(
                gauge,
                address(want),
                Math.min(stakedBal, _debtOutstanding)
            );

            _debtPayment = Math.min(
                _debtOutstanding,
                want.balanceOf(address(this))
            );
        }

        return (_profit, _loss, _debtPayment);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // used in case there is balance of gauge tokens in the strategy
        // this should be withdrawn and added to proxy
        if (checkLiqGauge == CHECK_LIQ_GAUGE_TRUE) {
            uint256 liqGaugeBal = IGauge(gauge).balanceOf(address(this));

            if (liqGaugeBal > 0) {
                IGauge(gauge).withdraw(liqGaugeBal);
            }
            // send all of our Iron Bank pool tokens to the proxy and deposit to the gauge
            uint256 _toInvest = want.balanceOf(address(this));
            want.safeTransfer(address(proxy), _toInvest);
            proxy.deposit(gauge, address(want));
            // since we've deposited to gauge, reset our counters
            tendCounter = 0;
            harvestNow = 0;
        } else {
            if (harvestNow == 1) {
                // if this is part of a harvest call
                uint256 _toInvest = want.balanceOf(address(this));
                want.safeTransfer(address(proxy), _toInvest);
                proxy.deposit(gauge, address(want));
                // since we've completed our harvest call, reset our tend counter and our harvest now
                tendCounter = 0;
                harvestNow = 0;
            } else {
                // This is our tend call. Check the gauge for CRV, then harvest gauge CRV and sell for preferred asset, but don't deposit.
                proxy.harvest(gauge);
                uint256 crvBalance = crv.balanceOf(address(this));
                uint256 _keepCRV = crvBalance.mul(keepCRV).div(FEE_DENOMINATOR);
                IERC20(address(crv)).safeTransfer(voter, _keepCRV);
                uint256 crvRemainder = crvBalance.sub(_keepCRV);

                _sell(crvRemainder);
                // increase our tend counter by 1 so we can know when we should harvest again
                uint256 previousTendCounter = tendCounter;
                tendCounter = previousTendCounter.add(1);
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBal = want.balanceOf(address(this));
        if (_amountNeeded > wantBal) {
            uint256 stakedBal = proxy.balanceOf(gauge);
            proxy.withdraw(
                gauge,
                address(want),
                Math.min(stakedBal, _amountNeeded - wantBal)
            );
            uint256 withdrawnBal = want.balanceOf(address(this));
            _liquidatedAmount = Math.min(_amountNeeded, withdrawnBal);

            // if _amountNeeded != withdrawnBal, then we have an error
            if (_amountNeeded != withdrawnBal) {
                uint256 assets = estimatedTotalAssets();
                uint256 debt = vault.strategies(address(this)).totalDebt;
                _loss = debt.sub(assets);
            }
        }

        return (_liquidatedAmount, _loss);
    }

    // Sells our harvested CRV into the selected output (DAI, USDC, or USDT).
    function _sell(uint256 _amount) internal {
        IUniswapV2Router02(crvRouter).swapExactTokensForTokens(
            _amount,
            uint256(0),
            crvPath,
            address(this),
            now
        );
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 gaugeTokens = proxy.balanceOf(gauge);
        if (gaugeTokens > 0) {
            proxy.withdraw(gauge, address(want), gaugeTokens);
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](5);
        protected[0] = gauge;
        protected[1] = address(crv);
        protected[2] = address(dai);
        protected[3] = address(usdt);
        protected[4] = address(usdc);

        return protected;
    }

    // keeper functions

    // set what will trigger our keepers to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        StrategyParams memory params = vault.strategies(address(this));

        // Should not trigger if Strategy is not activated
        if (params.activation == 0) return false;

        // Should not trigger if we haven't waited long enough since previous harvest
        if (block.timestamp.sub(params.lastReport) < minReportDelay)
            return false;

        // Should trigger if hasn't been called in a while
        if (block.timestamp.sub(params.lastReport) >= maxReportDelay)
            return true;

        // If some amount is owed, pay it back
        // NOTE: Since debt is based on deposits, it makes sense to guard against large
        //       changes to the value from triggering a harvest directly through user
        //       behavior. This should ensure reasonable resistance to manipulation
        //       from user-initiated withdrawals as the outstanding debt fluctuates.
        uint256 outstanding = vault.debtOutstanding();
        if (outstanding > debtThreshold) return true;

        // Check for profits and losses
        uint256 total = estimatedTotalAssets();
        // Trigger if we have a loss to report
        if (total.add(debtThreshold) < params.totalDebt) return true;

        // no need to spend the gas to harvest every time; tend is much cheaper
        if (tendCounter < tendsPerHarvest) {
            return false;
        }

        // check how much claimable CRV we have; this can only be done off-chain
        uint256 claimableTokens =
            IGauge(gauge).claimable_tokens(address(proxy));

        // do stuff here when we have enough CRV
        if (claimableTokens > crvMinimum) {
            // determine how rich we get if we sell all of the CRV in our gauge
            address[] memory harvestPath = new address[](3);
            harvestPath[0] = address(crv);
            harvestPath[1] = address(weth);
            harvestPath[2] = address(dai);

            uint256[] memory _crvDollarsOut =
                IUniswapV2Router02(crvRouter).getAmountsOut(
                    claimableTokens,
                    harvestPath
                );
            uint256 crvDollarsOut = _crvDollarsOut[_crvDollarsOut.length - 1];

            // calculate how much the call costs in dollars (converted from ETH)
            uint256 callCost = ethToDollaBill(callCostinEth);

            // if our profit is greater than the cost of the tend * our chosen multiple, then tend it!!
            return harvestProfitFactor.mul(callCost) < crvDollarsOut;
        }
    }

    // set what will trigger keepers to call tend, which will harvest and sell CRV for optimal asset but not deposit or report profits
    function tendTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // we need to call a harvest every once in a while
        if (tendCounter >= tendsPerHarvest) {
            return false;
        }

        // check how much claimable CRV we have; this can only be done off-chain
        uint256 claimableTokens =
            IGauge(gauge).claimable_tokens(address(proxy));

        // do stuff here when we have enough CRV
        if (claimableTokens > crvMinimum) {
            // determine how rich we get if we sell all of the CRV in our gauge
            address[] memory tendPath = new address[](3);
            tendPath[0] = address(crv);
            tendPath[1] = address(weth);
            tendPath[2] = address(dai);

            uint256[] memory _crvDollarsOut =
                IUniswapV2Router02(crvRouter).getAmountsOut(
                    claimableTokens,
                    tendPath
                );
            uint256 crvDollarsOut = _crvDollarsOut[_crvDollarsOut.length - 1];

            // calculate how much the call costs in dollars (converted from ETH)
            uint256 callCost = ethToDollaBill(callCostinEth);

            // if our profit is greater than the cost of the tend * our chosen multiple, then tend it!!
            return tendProfitFactor.mul(callCost) < crvDollarsOut;
        }
    }

    // convert our keeper's eth cost into dai
    function ethToDollaBill(uint256 _ethAmount)
        internal
        view
        returns (uint256)
    {
        address[] memory ethPath = new address[](2);
        ethPath[0] = address(weth);
        ethPath[1] = address(dai);

        uint256[] memory callCostInDai =
            IUniswapV2Router02(crvRouter).getAmountsOut(_ethAmount, ethPath);

        return callCostInDai[callCostInDai.length - 1];
    }

    // use these functions to set parameters for our triggers
    function setTendProfitFactor(uint256 _tendProfitFactor)
        external
        onlyAuthorized
    {
        tendProfitFactor = _tendProfitFactor;
    }

    function setHarvestProfitFactor(uint256 _harvestProfitFactor)
        external
        onlyAuthorized
    {
        harvestProfitFactor = _harvestProfitFactor;
    }

    function setCrvMin(uint256 _crvMinimum) external onlyAuthorized {
        crvMinimum = _crvMinimum;
    }

    // setter functions
    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Use to update Yearn's StrategyProxy contract as needed in case of upgrades.
    function setProxy(address _proxy) external onlyGovernance {
        proxy = ICurveStrategyProxy(_proxy);
    }

    // 1 is for TRUE value and 0 for FALSE to keep in sync with binary convention
    // checkLiqGauge TRUE = 1;
    // checkLiqGauge FALSE = 0;
    function updateCheckLiqGauge(uint256 _checkLiqGauge)
        external
        onlyAuthorized
    {
        require(_checkLiqGauge <= CHECK_LIQ_GAUGE_TRUE, "incorrect value");
        checkLiqGauge = _checkLiqGauge;
    }

    // Set the amount of CRV to be locked in Yearn's veCRV voter from each harvest. Default is 10%.
    function setKeepCRV(uint256 _keepCRV) external onlyGovernance {
        keepCRV = _keepCRV;
    }

    // 1 is for TRUE value and 0 for FALSE to keep in sync with binary convention
    // Use SushiSwap for CRV Router = 1;
    // Use Uniswap for CRV Router = 0 (or anything else);
    function setCrvRouter(uint256 _isSushiswap) external onlyAuthorized {
        if (_isSushiswap == USE_SUSHI) {
            crvRouter = sushiswapRouter;
        } else {
            crvRouter = uniswapRouter;
        }
    }

    // Set Yearn's veCRV voter address, useful in case of contract upgrade
    function setVoter(address _voter) external onlyGovernance {
        voter = _voter;
    }

    // Set optimal token to sell harvested CRV into for depositing back to Iron Bank Curve pool.
    // Default is DAI, but can be set to USDC or USDT as needed by strategist or governance.
    function setOptimal(uint256 _optimal) external onlyAuthorized {
        crvPath = new address[](3);
        crvPath[0] = address(crv);
        crvPath[1] = address(weth);

        if (_optimal == 0) {
            crvPath[2] = address(dai);
            optimal = 0;
        } else if (_optimal == 1) {
            crvPath[2] = address(usdc);
            optimal = 1;
        } else if (_optimal == 2) {
            crvPath[2] = address(usdt);
            optimal = 2;
        } else {
            require(false, "incorrect token");
        }
    }
}
