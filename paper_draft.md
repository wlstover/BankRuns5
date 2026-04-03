# A Bank Run Model for the Twentieth Century

**John S. Schuler**
Department of Computational and Data Sciences, George Mason University

---

## Abstract

Diamond and Dybvig (1983) is a now-classic model of bank runs and is often cited as a primary justification for government deposit insurance. A central limitation of the Diamond-Dybvig framework is that while it identifies two equilibria — one stable, one a run — it is silent on the mechanism by which a system transitions between them. This paper reconsiders the classic model and highlights a structural artifact that drives much of its behavior: agents in Diamond-Dybvig are not saving but rather *buying an option*, and the "run" equilibrium is driven by the insurance payout structure rather than by any realistic social dynamic. A replacement model is offered. The replacement is an agent-based model (ABM) in which heterogeneous agents are embedded in a Watts-Strogatz small-world network, hold log-normally distributed deposits, and make withdrawal decisions via Monte Carlo inference about the bank's solvency. The model is run across a broad parameter sweep varying reserve ratios, deposit insurance levels, deposit heterogeneity, and network structure. [**Placeholder: brief summary of key findings.**]

---

## 1. Introduction

### 1.1 Bank Run Recap

A bank run is a coordination failure in which depositors, fearing that a bank cannot honor its obligations, simultaneously attempt to withdraw their funds. Because banks operate on a fractional reserve basis — holding only a fraction of total deposits as liquid reserves — a sufficiently large or rapid surge in withdrawals will exhaust those reserves, confirming depositors' fears. The phenomenon is thus self-fulfilling: the belief that a bank will fail can cause it to fail, regardless of the bank's underlying solvency.

Fractional reserve banking is not merely a regulatory artifact; it is the structural consequence of the core economic function of banks. Depositors wish to lend short (maintain liquidity) while borrowers wish to borrow long (invest in illiquid projects). A bank reconciles these preferences by pooling depositor funds and managing the associated liquidity risk. This arrangement is productive but inherently fragile: if all depositors simultaneously demand their funds, no fractional reserve bank can comply. As John Kenneth Galbraith observed, "so long as depositors believe they can get their money, they don't want it" (Galbraith, 1975). The fragility is therefore fundamentally psychological and social — it lives in the space of beliefs about the beliefs of others.

### 1.2 Using Agent-Based Models

The traditional toolkit of economic modeling — representative agents, equilibrium analysis, closed-form utility maximization — fits uncomfortably with the social and psychological nature of bank runs. The core question in a bank run is not "what is the equilibrium?" but rather "how does a system that was *in* the good equilibrium suddenly move to the bad one?" Answering this question requires a model of the *process*, not just the end states.

Agent-based models (ABMs) are well-suited to this purpose. An ABM explicitly models each agent as an individual decision-maker with its own state, interacting with other agents according to defined local rules. The macroscopic behavior of the system — in this case, whether a run occurs — emerges from these interactions. ABMs do not require analytic tractability; they are simulated rather than solved. This makes them particularly well-suited to problems involving heterogeneous agents, network structure, and path-dependent dynamics, all of which are central features of real bank runs.

The 2023 collapse of Silicon Valley Bank is an illustrative example. The run was driven in large part through social networks, particularly among the bank's depositor base of closely connected venture capital firms and technology startups. Information about SVB's unrealized losses propagated rapidly through these networks, triggering a coordinated withdrawal dynamic that a representative-agent equilibrium model cannot capture.

### 1.3 The Core Banking Setup and What a "Run" Is

For the purposes of this model, the bank is a simplified single-institution with no assets other than deposits and no liabilities beyond what it owes depositors. The bank holds a *vault* — a quantity of liquid reserves equal to a specified fraction (the *reserve ratio*) of total deposits at initialization. Agents deposit funds at model initialization; the bank never makes loans and earns no return. This is a deliberately minimal setup designed to isolate the run mechanism from complications such as loan defaults, interest rates, and capital adequacy requirements. The purpose is to study the *conditions under which a run occurs*, not to produce a calibrated forecast of any specific bank's failure probability.

A *bank run* in this model is defined as the event in which the bank's vault falls to zero or below — that is, the bank cannot honor all outstanding deposit obligations. This is equivalent to a *liquidity event*: the bank is not necessarily insolvent in any fundamental sense, but it cannot meet current demand.

### 1.4 Literature Review

[**Placeholder: literature review section. Key references to address include Diamond & Dybvig (1983), White (1999), Postlewaite & Vives (1987), Shell & Diamond, Ennis & Keister (2010), Kinateder & Kiss (2014), Green & Lin (2000), Andolfatto et al. (2007), Peck & Shell (2003, 2019), Nosal & Wallace (2009), Smith & Peck (2014), and ABM references including Hamill & Gilbert (2009, 2016), Elias (2025), Santos & Nakane (2021), Deng et al. (2010).**]

### 1.5 Theoretical Predictions

Several directional predictions can be stated before examining the simulation results. Each is motivated by the structure of the model.

**Reserve ratio.** A higher reserve ratio means the bank holds more liquid assets relative to total deposits. All else equal, this should reduce the probability of a run, since more withdrawals can be honored before the vault is exhausted.

**Deposit insurance.** Deposit insurance caps the loss an agent can suffer upon bank failure. By reducing the downside risk of a bank failure from the agent's perspective, it reduces the incentive to withdraw preemptively, and therefore should lower the probability of a run. However, the relationship may be nonlinear: at very low insurance levels, agents have essentially no protection and strong incentives to run; at higher levels, the incentive to run diminishes.

**Deposit heterogeneity.** When deposits are highly heterogeneous (high sigma in the log-normal distribution), large depositors have much more to lose than small depositors. Large depositors have a stronger incentive to monitor the bank and to withdraw early if they perceive risk. This asymmetry may increase run probability, particularly because the bank's vault is determined by aggregate deposits, but the first few large depositors to withdraw can deplete it substantially.

**Network structure.** The Watts-Strogatz network parameterizes both the average degree (k, the number of neighbors each agent has) and the rewiring probability (p, which controls how much the network departs from a regular ring lattice toward a random graph). Higher k means agents observe more neighbors' behavior, potentially amplifying the social contagion of withdrawal. Higher p creates more short paths through the network (the "small world" property), which may accelerate information spread. [**Placeholder: directional predictions for these parameters pending results.**]

### 1.6 Preview of Results

[**Placeholder: two to three sentences previewing the key empirical findings from the simulation.**]

---

## 2. The Diamond-Dybvig Model and Its Limitations

### 2.1 The Classic Model

The Diamond-Dybvig model (Diamond & Dybvig, 1983) contains three time periods (t = 1, 2, 3) and n agents each with a deposit. The bank has access to a productive investment technology that matures at t = 3. There are two types of agents: *type 1* agents must consume at t = 2 and cannot wait, while *type 2* agents can wait until t = 3. Agents do not know at t = 1 which type they are; they learn at t = 2. The bank therefore offers a deposit contract paying a fixed insurance amount r₁ > 1 to agents withdrawing at t = 2 and a residual payoff to agents waiting until t = 3. Payments are made on a first-come, first-served basis.

Diamond and Dybvig show that this setup admits two Nash equilibria. In the good equilibrium, only type 1 agents withdraw at t = 2, and type 2 agents wait for the higher t = 3 payoff. In the bad equilibrium, all agents withdraw at t = 2 because each anticipates that every other agent is doing so — in which case, there is nothing left at t = 3, so it is rational to withdraw. The bad equilibrium is the bank run.

### 2.2 A Stochastic Process Interpretation

The Diamond-Dybvig model can be reformulated as a stochastic process. Let there be n identical agents, each depositing d units, and let exogenous early withdrawals be governed by W_exog ~ Binomial(n, p). After exogenous withdrawals, all remaining agents reconsider whether to withdraw. An agent's decision depends on a comparison of:

$$E[u(W_{\text{endog}})] \geq E[u(R)]$$

where W_endog is the agent's return upon endogenous withdrawal (uncertain due to unknown queue position) and R is the residual claim at t = 3. Because agents are identical, this calculation is identical for all, so the equilibrium is all-or-nothing: either all remaining agents withdraw or none do.

Under this formulation, the bank failure probability is a function solely of the exogenous parameters:

$$P(\mathcal{F}) = \psi(p, \iota, \pi)$$

where p is the exogenous withdrawal probability, ι is the deposit insurance payout rate, and π is the investment return. Simulation results from this version confirm that failure probability increases with p and ι, and decreases with π.

### 2.3 The Structural Artifact

These results reveal a central problem with the Diamond-Dybvig framework. When agents evaluate whether to withdraw, they are not simply deciding whether to access savings: they are *comparing the option value of early withdrawal* (the guaranteed insurance payout r₁) against the residual claim. The run equilibrium in Diamond-Dybvig is driven almost entirely by this payout structure — specifically, by the possibility that the insurance payout exceeds the residual. Remove this feature (as in real-world deposit banking, where no such insurance payout exists on the liability side of the bank's balance sheet), and the model's run mechanism collapses. Real banks do not promise depositors a premium upon early withdrawal. The Diamond-Dybvig "run" is therefore an artifact of the contract assumed, not a general property of fractional reserve banking.

---

## 3. The Replacement Model

### 3.1 Motivation and Design Philosophy

A replacement model must abandon the representative-agent, equilibrium-seeking approach and instead model the marginal decision of each individual agent. The key observation is that in real fractional reserve banking, an agent's cost of unnecessary early withdrawal is merely the foregone interest on the deposit for the period in question — typically small relative to the deposit itself. By contrast, the cost of *failing to withdraw* when the bank is about to fail is potentially the entire deposit balance. The asymmetry is stark: small cost to withdraw unnecessarily, potentially catastrophic cost to not withdraw when one should.

This asymmetry suggests a simple decision rule: an agent withdraws if the probability of receiving its full deposit by withdrawing *now* exceeds the probability of receiving its full deposit by *staying*. This requires no utility function, no insurance payout structure, and no equilibrium concept. It requires only that agents have some information about the state of the system and can reason probabilistically about outcomes.

### 3.2 Banking Mechanics and Relevant Formulas

The model bank is initialized with a vault equal to a fixed fraction of total deposits:

$$\text{Vault}_0 = r \cdot \sum_{i=1}^{N} d_i$$

where r is the reserve ratio and $d_i$ is the deposit of agent i. The vault is the bank's only liquid resource.

When agent i withdraws, the bank pays:

$$\text{Payment}_i = \begin{cases} d_i & \text{if } \text{Vault} \geq d_i \\ \max\left(0,\ \text{Vault},\ \min(d_i,\ \bar{d}_{\text{ins}})\right) & \text{if } \text{Vault} < d_i \end{cases}$$

where $\bar{d}_{\text{ins}}$ is the deposit insurance cap. After the payment, the vault is reduced by $d_i$ regardless of whether the full amount was paid. The bank has *failed* when Vault ≤ 0.

The deposit insurance cap is set as the $q$-th quantile of the deposit distribution:

$$\bar{d}_{\text{ins}} = F^{-1}_{\text{LogNormal}}(q)$$

where q is the *depositInsuranceQuantile* parameter. This parameterization means that insurance covers depositors in approximately the bottom q-th fraction of the deposit size distribution in full, while larger depositors face partial or no coverage above this threshold.

### 3.3 Model Overview

The model contains the following components:

**Agents.** There are N = 1,000 agents. Each agent i has a deposit $d_i$ drawn at initialization from a log-normal distribution:

$$d_i \sim \text{LogNormal}(\mu, \sigma)$$

with μ = 1.0 fixed and σ varying across experiments. Each agent is in one of two states: *banked* (deposit held at the bank) or *withdrawn* (has exited the bank). Agents begin in the banked state.

**Bank.** The bank holds a single liquid reserve (vault). There is no investment technology, no interest, and no loans. The vault is initialized at $r \cdot \sum_i d_i$ and decreases monotonically as withdrawals occur. The bank also maintains a *banking list* (agents currently depositing) and a *withdrawal history* (agents that have withdrawn).

**Network.** Agents are connected in a Watts-Strogatz small-world network with parameters k (mean degree, i.e., each agent is connected to k nearest neighbors before rewiring) and p (rewiring probability). The network determines each agent's information set: agent i observes the withdrawal decisions of its immediate network neighbors only.

**Exogenous withdrawal distribution.** The number of exogenous withdrawals at the start of each model run is drawn from a truncated Geometric distribution:

$$W_{\text{exog}} \sim \text{Geometric}(p_g)\big|_{[0,\, 1000]}$$

with $p_g = 0.1$ fixed. The truncated Geometric is approximately memoryless and right-skewed, meaning most runs have few exogenous withdrawals but the occasional run has a large exogenous shock.

### 3.4 Model Event Timeline

Each model run proceeds in two phases.

#### Phase 1: Exogenous Withdrawals

1. A realization $w_{\text{exog}}$ is drawn from the truncated Geometric distribution.
2. $w_{\text{exog}}$ agents are selected uniformly at random (without replacement) from the full agent population and forced to withdraw.
3. Each selected agent receives its payment per the payment formula above. The vault is decremented accordingly.
4. If the vault reaches zero or below after Phase 1, the model terminates immediately and records a bank failure.

The exogenous shock represents withdrawal demand arising from outside the model's social dynamics: liquidity needs, idiosyncratic shocks, or the initial "runners" who set the process in motion.

#### Phase 2: Endogenous Withdrawals (Iterated)

Phase 2 iterates over all agents still banked, in a randomly shuffled order, until either the bank fails or no agent changes state in a full pass (a stable equilibrium is reached).

For each agent i still banked, the following steps occur:

**Step 1: Observe network neighbors.**
Agent i identifies its network neighbors and counts how many have already withdrawn:

$$n_{\text{withdrawn}} = \#\{j \in \mathcal{N}(i) : \text{banked}_j = \text{false}\}$$
$$\hat{\pi}_{\text{withdrawn}} = \frac{n_{\text{withdrawn}}}{|\mathcal{N}(i)|}$$

**Step 2: Infer population-level withdrawals.**
The agent scales its observed neighbor withdrawal rate to estimate total withdrawals in the full population:

$$\hat{W}_{\text{total}} = \text{round}\left(\hat{\pi}_{\text{withdrawn}} \times N\right)$$

This is a naive but tractable inference step: the agent treats its local neighborhood as a representative sample of the population.

**Step 3: Sample possible future withdrawal totals.**
Using the observed withdrawal count as a lower bound, the agent samples D = 1,000 possible total withdrawal counts from a truncated Geometric distribution:

$$\tilde{W}^{(k)} \sim \text{Geometric}(p_g)\big|_{[\hat{W}_{\text{total}},\, N-1]}, \quad k = 1, \ldots, D$$

This represents the agent's uncertainty about how many *additional* withdrawals might occur.

**Step 4: Monte Carlo comparison — "withdraw now" vs. "stay."**

For each trial k = 1, ..., D, the agent runs two counterfactual simulations on a cloned copy of the current model state:

- **Withdraw now scenario** (*initWithdrawResults*): Agent i withdraws immediately from the current state of the cloned model. The payment received is recorded. This is compared against $d_i$ to determine whether the agent received its full deposit.

- **Stay and withdraw later scenario** (*subModResults*): In a separate clone, the agent first forces all already-withdrawn neighbors to withdraw (reflecting observed information), then removes $\tilde{W}^{(k)} - n_{\text{withdrawn}}$ additional random agents (reflecting anticipated future withdrawals), and *then* agent i withdraws. The payment received is again compared against $d_i$.

This yields two empirical probabilities:

$$\hat{P}_{\text{WD}} = \frac{1}{D} \sum_{k=1}^{D} \mathbf{1}\left[\text{payment}_{\text{now}}^{(k)} = d_i\right]$$

$$\hat{P}_{\text{stay}} = \frac{1}{D} \sum_{k=1}^{D} \mathbf{1}\left[\text{payment}_{\text{later}}^{(k)} = d_i\right]$$

**Step 5: Decision.**
Agent i withdraws if:

$$\hat{P}_{\text{WD}} > \hat{P}_{\text{stay}}$$

That is, the agent withdraws if it is more likely to receive its full deposit by withdrawing *now* than by waiting. If the agent withdraws, the halt flag is reset (Phase 2 continues for another pass); if no agent withdraws in a full pass, Phase 2 terminates with no bank failure.

#### Termination

The run terminates under one of two conditions:
1. **Bank failure**: the vault reaches zero or below at any point in either phase. Result recorded: failure (= 1).
2. **Stability**: a full pass through all banked agents in Phase 2 completes with no agent withdrawing. Result recorded: no failure (= 0).

---

## 4. Simulation Design

### 4.1 Parameter Space

The model is run across a full factorial sweep of the following parameters:

| Parameter | Values |
|---|---|
| Reserve ratio (r) | 0.2, 0.4 |
| Deposit insurance quantile (q) | 0.1, 0.2, 0.3, 0.4 |
| LogNormal σ (deposit heterogeneity) | 2.0, 3.0 |
| Watts-Strogatz k (mean degree) | 6, 10, 50 |
| Watts-Strogatz p (rewiring probability) | 0.05, 0.15 |

The LogNormal mean parameter μ is fixed at 1.0. The exogenous withdrawal probability $p_g$ is fixed at 0.1. The agent count N is fixed at 1,000. The Monte Carlo depth D is fixed at 1,000 trials per agent per decision.

This yields 2 × 4 × 2 × 3 × 2 = 96 distinct parameter combinations. Each combination is run with 5 distinct random seeds for model initialization (controlling agent deposit draws and network construction), and each seed is replicated 10 times (controlling the stochastic sequence of withdrawals and agent ordering within a run). This gives 50 runs per parameter combination and 4,800 total runs.

### 4.2 Distributed Execution

Runs are distributed across 16 parallel workers. Each worker operates on its own output files to avoid write contention. A master process maintains the parameter grid and assigns rows to workers atomically via a locked pull mechanism. Results are written to per-worker CSV files and merged during analysis.

### 4.3 Experiment Structure

The parameter sweep is analyzed as a set of structured experiments, each isolating the effect of one or two parameters while holding others at reference values or examining the full cross.

---

## 5. Simulation Results

### 5.1 Output Variables

Each run produces the following outputs, written to CSV files in the data directory:

**`bankRunResults{core}.csv`** — primary outcome file. One row per run.

| Column | Description |
|---|---|
| `key` | Unique run identifier (timestamp + seeds) |
| `result` | Binary: 1 = bank failure (vault exhausted), 0 = stable |

**`bankRunExogenous{core}.csv`** — one row per exogenous withdrawal event.

| Column | Description |
|---|---|
| `key` | Run identifier |
| `agent` | Agent index |
| `exogenous` | Always `true` in this file |
| `deposit` | Agent's deposit amount |
| `tick` | Always 0 (Phase 1) |
| `vault` | Vault level after this withdrawal |

**`bankRunEndogenous{core}.csv`** — one row per agent decision in Phase 2 (including agents that decide *not* to withdraw).

| Column | Description |
|---|---|
| `key` | Run identifier |
| `agent` | Agent index |
| `withdraw` | Boolean: did the agent withdraw? |
| `deposit` | Agent's deposit amount |
| `tick` | Phase 2 iteration number |
| `vault` | Vault level at time of decision |
| `wdProb` | $\hat{P}_{\text{WD}}$: estimated P(full deposit \| withdraw now) |
| `stayProb` | $\hat{P}_{\text{stay}}$: estimated P(full deposit \| stay) |

**`agents{core}.csv`** — one row per agent per run.

| Column | Description |
|---|---|
| `key` | Run identifier |
| `idx` | Agent index |
| `deposit` | Agent deposit amount |

**`bankRunParametersInit.csv`** — one row per run, parameter values.

| Column | Description |
|---|---|
| `seed1` | Initialization seed (controls deposits and network) |
| `iteration` | Within-seed replication index |
| `graphParams1` | Watts-Strogatz k |
| `graphParams2` | Watts-Strogatz p |
| `reserveRatio` | Reserve ratio r |
| `depositInsuranceQuantile` | Insurance quantile q |
| `seed2` | Run-level stochastic seed |
| `key` | Run identifier |

### 5.2 Experiment 1: Effect of Reserve Ratio

[**Placeholder: analysis of bank failure rate as a function of reserve ratio (0.2 vs. 0.4), pooled across other parameters or broken out by parameter combination. Expected finding: higher reserve ratio reduces run probability.**]

### 5.3 Experiment 2: Effect of Deposit Insurance

[**Placeholder: analysis of bank failure rate as a function of deposit insurance quantile (0.1, 0.2, 0.3, 0.4). Expected finding: higher insurance coverage reduces run probability, with potentially nonlinear effects. May also examine the distribution of wdProb and stayProb values across insurance levels.**]

### 5.4 Experiment 3: Effect of Deposit Heterogeneity

[**Placeholder: analysis of bank failure rate as a function of LogNormal σ (2.0 vs. 3.0). Higher σ implies greater variance in deposit sizes. Expected finding: [to be determined]. May also examine whether large depositors disproportionately drive runs.**]

### 5.5 Experiment 4: Effect of Network Structure

[**Placeholder: analysis of bank failure rate as a function of Watts-Strogatz k (6, 10, 50) and p (0.05, 0.15). Higher k means more neighbors observed; higher p means more random long-range connections. Expected findings: [to be determined]. The interaction between k and p is of particular interest.**]

### 5.6 Joint Effects and Interactions

[**Placeholder: summary of interaction effects across parameters. Which parameter combinations produce the highest/lowest run rates? Is there evidence of threshold effects — parameter ranges where run probability jumps discontinuously?**]

---

## 6. Conclusion

[**Placeholder: summary of contributions, key findings, policy implications (especially regarding reserve ratios and deposit insurance design), and directions for future work (e.g., dynamic deposits, loan portfolios, multi-bank networks, calibration to historical data).**]

---

## Appendix A: Model Pseudocode

```
Initialize:
  Draw deposits d_i ~ LogNormal(μ, σ) for i = 1..N
  Construct Watts-Strogatz network G(N, k, p)
  Set vault = r * sum(d)
  Set banked_i = true for all i

Phase 1 (Exogenous):
  Draw w_exog ~ Geometric(p_g) truncated to [0, N]
  Select w_exog agents uniformly at random without replacement
  For each selected agent i:
    Pay agent: min(d_i, max(vault, deposit_insurance_cap))
    Decrement vault by d_i
    Set banked_i = false
  If vault <= 0: record failure, terminate

Phase 2 (Endogenous), repeat until stable or failure:
  Shuffle banking agents randomly
  Set changed = false
  For each banked agent i:
    Compute n_withdrawn = count of withdrawn neighbors
    Estimate pi_hat = n_withdrawn / |N(i)|
    Estimate W_hat = round(pi_hat * N)
    For k = 1..D:
      Draw W_tilde ~ Geometric(p_g) truncated to [W_hat, N-1]
      Clone current model state twice (S1, S2)
      -- "Withdraw now" in S1:
        Payment_now[k] = withdraw(S1, i)
      -- "Stay and withdraw later" in S2:
        Force withdraw all withdrawn neighbors in S2
        Withdraw (W_tilde - n_withdrawn) additional random banked agents
        Payment_later[k] = withdraw(S2, i)
    P_WD  = mean(Payment_now  == d_i)
    P_stay = mean(Payment_later == d_i)
    If P_WD > P_stay:
      Withdraw agent i from real model
      Set changed = true
      If vault <= 0: record failure, terminate
  If not changed: record no failure, terminate
```

## Appendix B: Data Dictionary

Full column definitions for all output CSV files are given in Section 5.1. The unique run `key` is constructed as:

```
key = string(timestamp) * "-" * string(seed1) * "-" * string(seed2)
```

This key appears in all output files and serves as the join key for analysis.

---

*[Document prepared as structural draft for "A Bank Run Model for the Twentieth Century." Placeholder sections marked for expansion. Model code: Julia 1.x; analysis code: R.]*
