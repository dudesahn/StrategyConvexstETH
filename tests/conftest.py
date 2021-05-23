import pytest
from brownie import config, Wei, Contract

# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass

# Define relevant tokens and contracts in this section

@pytest.fixture
def token():
    # this should be the address of the ERC-20 used by the strategy/vault. In this case, Curve's sETH pool token
    token_address = "0xA3D87FffcE63B53E0d54fAa1cc983B7eB0b74A9c"
    yield Contract(token_address)

@pytest.fixture
def crv():
    yield Contract("0xD533a949740bb3306d119CC777fa900bA034cd52")

@pytest.fixture
def cvx():
    yield Contract("0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B")

@pytest.fixture
def cvxsETHDeposit():
    yield Contract("0xAF1d4C576bF55f6aE493AEebAcC3a227675e5B98")

@pytest.fixture
def dai():
    yield Contract("0x6B175474E89094C44Da98b954EedeAC495271d0F")

@pytest.fixture
def rewardsContract(): # this is the sETH pool rewards contract
    yield Contract("0x192469CadE297D6B21F418cFA8c366b63FFC9f9b")

@pytest.fixture
def voter():
    # this is yearn's veCRV voter, where we send all CRV to vote-lock
    yield Contract("0xF147b8125d2ef93FB6965Db97D6746952a133934")

# Define any accounts in this section
@pytest.fixture
def gov(accounts):
    # yearn multis... I mean YFI governance. I swear!
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)

@pytest.fixture
def dudesahn(accounts):
    yield accounts.at("0x8Ef63b525fceF7f8662D98F77f5C9A86ae7dFE09", force=True)
    
@pytest.fixture
def strategist_ms(accounts):
    # like governance, but better
    yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)

@pytest.fixture
def new_address(accounts):
    # new account for voter and proxy tests
    yield accounts.at("0xb5DC07e23308ec663E743B1196F5a5569E4E0555", force=True)

@pytest.fixture
def keeper(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]

@pytest.fixture
def strategist_ms(accounts):
    # like governance, but better
    yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)

@pytest.fixture
def whale(accounts):
    # Totally in it for the tech (largest EOA holder of sETH pool token, ~300 ETH worth)
    whale = accounts.at('0x1FbF5955b35728E650b56eF48eE9f3BD020164c8', force=True)
    yield whale

@pytest.fixture
def convexWhale(accounts):
    # Totally in it for the tech (largest EOA holder of CVX, ~70k worth)
    convexWhale = accounts.at('0xC55c7d2816C3a1BCD452493aA99EF11213b0cD3a', force=True)
    yield convexWhale

# this is the live strategy for sETH
@pytest.fixture
def curveVoterProxyStrategy():
    yield Contract("0xdD498eB680B0CE6Cac17F7dab0C35Beb6E481a6d")

@pytest.fixture
def strategy(strategist, keeper, vault, StrategyConvexsETH, gov, curveVoterProxyStrategy, guardian):
	# parameters for this are: strategy, vault, max deposit, minTimePerInvest, slippage protection (10000 = 100% slippage allowed), 
    strategy = guardian.deploy(StrategyConvexsETH, vault)
    # set myself as the curveProxy strategist as well
    curveVoterProxyStrategy.setStrategist('0x8Ef63b525fceF7f8662D98F77f5C9A86ae7dFE09', {"from": gov})
    strategy.setKeeper(keeper, {"from": gov})
    # lower the debtRatio of genlender to make room for our new strategy
    vault.updateStrategyDebtRatio(curveVoterProxyStrategy, 9950, {"from": gov})
    # set management fee to zero so we don't need to worry about this messing up pps
    vault.setManagementFee(0, {"from": gov})
    curveVoterProxyStrategy.harvest({"from": gov})
    vault.addStrategy(strategy, 25, 0, 2 ** 256 -1, 1000, {"from": gov})
    strategy.setStrategist('0x8Ef63b525fceF7f8662D98F77f5C9A86ae7dFE09', {"from": gov})
    strategy.harvest({"from": gov})
    yield strategy

@pytest.fixture
def vault(pm):
    Vault = pm(config["dependencies"][0]).Vault
    vault = Vault.at('0x986b4AFF588a109c09B50A03f42E4110E29D353F')
    yield vault
