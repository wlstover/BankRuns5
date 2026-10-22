################################################################################
#              Replacement Bank Run Model                                      #
#               (networked)                                                    #
#               June 2022                                                      #
#               John S. Schuler                                                #
#                                                                              #
################################################################################
# we need an agent
mutable struct Agent
    idx::Int64
    deposit::Float64
    banked::Bool
    individualism::Float64   # λ ∈ [0,1]: weight on neighbor signal; 0=individualist (own MC), 1=collectivist (social signal)
end

# and a simAgent. They are not
# subTypes of a common agent since they never share a space.

mutable struct simAgent
    idx::Int64
    deposit::Float64
    banked::Bool
    individualism::Float64
end

mutable struct Bank
    vault::Float64
    bankingList::Array{Agent}
    withdrawHistory::Array{Agent}
    # Face units of the long (illiquid) asset (2026-10-21, BANKRUN_BALANCE =
    # firesale). 0 in the vault bank, where withdraw() never sells.
    illiquid::Float64
end
# The 3-field form every caller used before 2026-10-21 (and the old code
# test_public_signal.jl replays): a vault bank, nothing to sell.
Bank(vault, bankingList, withdrawHistory) = Bank(vault, bankingList, withdrawHistory, 0.0)

mutable struct simBank
    vault::Float64
    bankingList::Array{simAgent}
    withdrawHistory::Array{simAgent}
    illiquid::Float64
end
simBank(vault, bankingList, withdrawHistory) = simBank(vault, bankingList, withdrawHistory, 0.0)

mutable struct Model
    key::String
    agtList::Array{Agent}
    reserveRatio::Float64
    theBank::Bank
    depositInsurance::Float64
    seed1::Int64
    seed2::Int64
    depositDistribution::Distribution
    network::Graph
    probThresh::Float64
    exogProb::Distribution
end

mutable struct simModel
    agtList::Array{simAgent}
    theBank::simBank
    depositInsurance::Float64
    depositDistribution::Distribution
end