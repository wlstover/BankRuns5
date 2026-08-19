library(tidyverse)
library(data.table)
library(ggExtra)

# list all files

setwd("~/ResearchCode/BankRunDataNew2")

# first read in control file
read.csv("bankRunParametersInit.csv") -> control
names(control) <- c("seed1","iteration","graphParams1","graphParams2","reserveRatio","depositInsuranceQuantile","seed2","key")
#read.csv("supplemental.csv") -> auxil

#merge(control,auxil,by="key") -> control
list.files()[grepl("Endogenous",list.files())] -> endoList
list.files()[grepl("Exogenous",list.files())] -> exoList
list.files()[grepl("Results",list.files())] -> resultList
list.files()[grepl("agents",list.files())] -> agentsList

endoDatList <- list()
exoDatList <- list()
resultDatList <- list()
agentsDatList <- list()
for (el in endoList){
  read.csv(el,header=FALSE) -> endoDatList[[length(endoDatList)+1]]
}

for (el in exoList){
  read.csv(el,header=FALSE) -> exoDatList[[length(exoDatList)+1]]
}

for (el in resultList){
  read.csv(el,header=FALSE) -> resultDatList[[length(resultDatList)+1]]
}

for (el in agentsList){
  read.csv(el,header=FALSE) -> agentsDatList[[length(agentsDatList)+1]]
}


rbindlist(endoDatList) -> endogenousDat
rbindlist(exoDatList) -> exogenousDat
rbindlist(resultDatList) -> resultDat
rbindlist(agentsDatList) -> agentsDat
nrow(resultDat)
# now add names
c("key","agent","exogenous","deposit","tick","vault") -> names(exogenousDat)

c("key","agent","withdraw","deposit","tick","valt","wdProb","stayProb") -> names(endogenousDat)

c("key","result") -> names(resultDat)

c("key","idx","deposit") -> names(agentsDat) 
nrow(resultDat)

# endogenous probabilities against each other, colored by bank outcome
endogenousDat %>%
  left_join(resultDat, by = "key") %>%
  filter(!is.na(result)) -> endogenousDatOutcome

ggplot(endogenousDatOutcome, aes(x = wdProb, y = stayProb, color = result)) +
  geom_point(alpha = 0.4, size = 0.6) +
  scale_color_manual(values = c("true" = "#1b9e77", "false" = "#d95f02")) +
  labs(
    x = "Withdrawal probability",
    y = "Stay probability",
    color = "Bank failure"
  )

# tabular summary: stay probability binned into deciles
quantile(endogenousDatOutcome$stayProb, probs = seq(0, 1, 0.1), na.rm = TRUE) -> stayProbBreaks
quantile(endogenousDatOutcome$wdProb, probs = seq(0, 1, 0.1), na.rm = TRUE) -> wdProbBreaks

endogenousDatOutcome %>%
  mutate(
    stayProbBin = cut(
      stayProb,
      breaks = unique(stayProbBreaks),
      include.lowest = TRUE,
      labels = sprintf("%.2f", head(unique(stayProbBreaks), -1))
    ),
    wdProbBin = cut(
      wdProb,
      breaks = unique(wdProbBreaks),
      include.lowest = TRUE,
      labels = sprintf("%.2f", head(unique(wdProbBreaks), -1))
    )
  ) %>%
  count(stayProbBin, wdProbBin, result, name = "n") %>%
  arrange(stayProbBin, wdProbBin, result) -> stayProbBinCounts

# Let's understand the agent deposit distribution

agentsDat %>% group_by(key) %>% summarise(totDeposit=sum(deposit)) -> totDeposit
totDeposit$origVault <- .25*totDeposit$totDeposit
merge(agentsDat,totDeposit,by="key") -> agentsDeposits

agentsDeposits$vaultPortion <- agentsDeposits$deposit / agentsDeposits$origVault
agentsDeposits$depPortion <- agentsDeposits$deposit / agentsDeposits$totDeposit
round(quantile(agentsDeposits$vaultPortion,c(0,0.01,.05,.25,.5,.75,.95,.99,1)),10)
# plot exogenous vs endogenous withdrawals

exogenousDat %>% group_by(key) %>% summarise(exoCnt=n()) -> exoWD
endogenousDat %>%  transform(withdraw=(withdraw=="true")) %>% group_by(key) %>% summarise(endoCnt=sum(withdraw)) -> endoWD

merge(exoWD,endoWD,by="key",all=TRUE) -> jointDat
jointDat$endoCnt <- coalesce(jointDat$endoCnt,0)

merge(jointDat,resultDat,by="key") -> finDat

merge(control,finDat,by="key") -> finDat

# check 
endogenousDat %>% group_by(key) %>% summarise(vault=min(valt)) %>% 
  transform(fail2=if_else(vault <= 0,TRUE,FALSE)) -> tst

exogenousDat %>% group_by(key) %>% summarise(minVault=min(vault),maxVault=max(vault)) -> exogSmry

#table(finDat$theta,finDat$result)

table(finDat$result)
ggplot(data=finDat) + geom_histogram(aes(x=exoCnt,fill=result),alpha=.2)
ggplot(data=finDat) + geom_point(aes(x=exoCnt,y=endoCnt,color=result),alpha=.1)

finDat %>% group_by(result,exoCnt,endoCnt) %>% summarise(cnt=n()) %>% arrange(exoCnt,endoCnt)

# ok now some summary statistics
# get failure probabilty by reserve ratio
finDat %>%
  group_by(reserveRatio) %>%
  summarise(
    failureProb = mean(result == "true", na.rm = TRUE),
    n = n()
  ) %>%
  arrange(reserveRatio) -> failByReserve

finDat %>%
  group_by(graphParams1, graphParams2) %>%
  summarise(
    failureProb = mean(result == "true", na.rm = TRUE),
    n = n()
  ) %>%
  arrange(graphParams1, graphParams2) -> failByGraphParams

finDat %>%
  group_by(depositInsuranceQuantile) %>%
  summarise(
    failureProb = mean(result == "true", na.rm = TRUE),
    n = n()
  ) %>%
  arrange(depositInsuranceQuantile) -> failByDepositInsQuantile

# withdrawal counts by simulation, keeping keys with zero endogenous/exogenous
endogenousDat %>%
  transform(withdraw = (withdraw == "true")) %>%
  group_by(key) %>%
  summarise(endoCnt = sum(withdraw), .groups = "drop") -> endoCntByKey

exogenousDat %>%
  group_by(key) %>%
  summarise(exoCnt = n(), .groups = "drop") -> exoCntByKey

full_join(exoCntByKey, endoCntByKey, by = "key") %>%
  mutate(
    exoCnt = coalesce(exoCnt, 0L),
    endoCnt = coalesce(endoCnt, 0L)
  ) %>%
  left_join(resultDat, by = "key") %>%
  filter(!is.na(result)) -> withdrawalCounts

ggplot(withdrawalCounts, aes(x = endoCnt, fill = result)) +
  geom_histogram(bins = 30, alpha = 0.75, position = "stack") +
  scale_fill_manual(values = c("true" = "#1b9e77", "false" = "#d95f02")) +
  labs(
    x = "Endogenous withdrawals (count)",
    y = "Simulations",
    fill = "Bank failure"
  )

ggplot(withdrawalCounts, aes(x = exoCnt, fill = result)) +
  geom_histogram(bins = 30, alpha = 0.75, position = "stack") +
  scale_fill_manual(values = c("true" = "#1b9e77", "false" = "#d95f02")) +
  labs(
    x = "Exogenous withdrawals (count)",
    y = "Simulations",
    fill = "Bank failure"
  )

# combined histogram: stack endogenous and exogenous, color by failure
withdrawalCounts %>%
  select(key, result, endoCnt, exoCnt) %>%
  pivot_longer(
    cols = c(endoCnt, exoCnt),
    names_to = "type",
    values_to = "count"
  ) %>%
  mutate(type = recode(type, endoCnt = "endogenous", exoCnt = "exogenous")) -> withdrawalCountsLong

ggplot(
  withdrawalCountsLong,
  aes(x = count, fill = interaction(type, result, sep = "."))
) +
  geom_histogram(bins = 30, position = "stack") +
  scale_fill_manual(
    values = c(
      "endogenous.true" = scales::alpha("#1b9e77", 0.7),
      "exogenous.true" = scales::alpha("#1b9e77", 0.35),
      "endogenous.false" = scales::alpha("#d95f02", 0.7),
      "exogenous.false" = scales::alpha("#d95f02", 0.35)
    )
  ) +
  labs(
    x = "Withdrawals (count)",
    y = "Simulations",
    fill = "Type / failure"
  )

# scatterplot with marginal histograms by failure
withdrawalCounts %>%
  mutate(result = factor(result, levels = c("true", "false"))) %>%
  ggplot(aes(x = exoCnt, y = endoCnt, color = result, fill = result)) +
  geom_point(alpha = 0.6, size = 0.6) +
  scale_color_manual(values = c("true" = "#1b9e77", "false" = "#d95f02")) +
  scale_fill_manual(values = c("true" = "#1b9e77", "false" = "#d95f02")) +
  labs(
    title = "Withdrawals vs. Outcome",
    x = "Exogenous withdrawals (count)",
    y = "Endogenous withdrawals (count)",
    color = "Bank failure",
    fill = "Bank failure"
  ) +
  theme(
    legend.position = "bottom",
    plot.title = element_text(hjust = 0.5)
  ) -> wdScatter

ggExtra::ggMarginal(
  wdScatter,
  type = "histogram",
  groupColour = TRUE,
  groupFill = TRUE,
  alpha = 0.5
)
