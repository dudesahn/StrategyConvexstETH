import brownie
from brownie import Contract

def test_emergency_exit(accounts, token, vault, strategy, strategist, amount, whale, curve_proxy, gauge):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": whale})
    vault.deposit(amount, {"from": whale})
    strategy.setOptimal(0)
    strategy.harvest({"from": strategist})
    assert curve_proxy.balanceOf(gauge) == amount

    # set emergency and exit, then confirm that the 
    strategy.setEmergencyExit()
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() == 0