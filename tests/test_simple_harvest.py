import brownie
from brownie import Contract


def test_operation(token, vault, strategy, strategist, amount, whale, gauge, strategyProxy, chain, voter):
    # Deposit to the vault, whale approves 10% of his stack and deposits it
    token.approve(vault, amount, {"from": whale})
    vault.deposit(amount, {"from": whale})
    assert token.balanceOf(vault) == amount

    # set optimal to decide which token to deposit into Curve pool for each harvest (DAI first)
    strategy.setOptimal(0)

    # harvest, store asset amount
    strategy.harvest({"from": strategist})
    old_assets_dai = vault.totalAssets()
    assert strategyProxy.balanceOf(gauge) == amount
    assert old_assets_dai == amount
    assert old_assets_dai == strategyProxy.balanceOf(gauge)

    # simulate a month of earnings
    chain.sleep(2592000)
    chain.mine(1)

    # harvest after a month, store new asset amount
    strategy.harvest({"from": strategist})
    new_assets_dai = vault.totalAssets()
    assert new_assets_dai > old_assets_dai
    
    # Display estimated APR based on the past month
    print("\nEstimated DAI APR: ", "{:.2%}".format(((new_assets_dai-old_assets_dai)*12)/(old_assets_dai)))


    # tend()
    strategy.tend()

    # withdrawal
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) != 0