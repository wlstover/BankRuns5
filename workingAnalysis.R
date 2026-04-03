library(tidyverse)
library(data.table)
library(ggplot2)
library(readr)

library(tidyverse)
library(data.table)


# list all files

setwd("~/ResearchCode/BankRunDataPartial")

# first read in control file
read.csv("bankRunParametersInit.csv") -> control
names(control) <- c("seed1","iteration","graphParams1","graphParams2","reserveRatio","depositInsuranceQuantile","seed2","key")
#control[c(1:4000,4002:8001),] -> control
control$graphParams2 <- as.numeric(control$graphParams2)
control$graphParams1 <- as.numeric(control$graphParams1)
read.csv("bankRunGeometric.csv") -> geom
names(geom) <- c("p","s0","s1")
read.csv("bankRunlogNormal.csv") -> logNorm
names(logNorm) <- c("mu","sigma")

as.numeric(geom$p)-> geom$p
as.numeric(geom$s0)-> geom$s0
as.numeric(geom$s1)-> geom$s1

as.numeric(logNorm$mu)-> logNorm$mu
as.numeric(logNorm$sigma)-> logNorm$sigma

bind_cols(control,geom,logNorm) -> control

list.files()[grepl("Endogenous",list.files())] -> endoList
list.files()[grepl("Exogenous",list.files())] -> exoList
list.files()[grepl("Results",list.files())] -> resultList
list.files()[grepl("agents",list.files())] -> agentsList

endoDatList <- list()
exoDatList <- list()
resultDatList <- list()
agentsDatList <- list()
for (el in endoList){
  read_csv(el,col_names=FALSE) -> endoDatList[[length(endoDatList)+1]]
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

resultDat$result <- resultDat$result == "true"

# now clean up the data
sort(endogenousDat$key)
table(nchar(endogenousDat$key))
endogenousDat[nchar(endogenousDat$key) < 33,]
endogenousDat[nchar(endogenousDat$key) >= 33,] -> endogenousDat

# now, let's take a look at where there were failures
merge(control,resultDat,by="key") -> resultControl

resultControl %>% group_by(graphParams1,graphParams2) %>% 
  summarise(failureProb = mean(result),cnt=n(),totFail=sum(result)) -> resultSmry1

ggplot(data=resultSmry1) + geom_point(aes(x=graphParams1,y=graphParams2,color=failureProb))

resultControl %>% group_by(reserveRatio) %>% 
  summarise(failureProb = mean(result),cnt=sum(result),total=n()) -> resultSmry2

resultControl %>% group_by(reserveRatio,depositInsuranceQuantile,graphParams1,graphParams2) %>% 
  summarise(failureProb = mean(result),cnt=sum(result),total=n()) -> resultSmry3



resultControl %>% group_by(reserveRatio,depositInsuranceQuantile) %>% 
  summarise(failureProb = mean(result)) -> resultSmry4

agentsDat %>% group_by(key) %>% 
  summarise(maxDeposit = max(deposit)) -> agentSmry


# let's get counts of endogenous and exogenous withdrawals

endogenousDat %>% filter(withdraw) %>% group_by(key) %>% 
  summarise(endogenousWithdrawals = n()) -> endoSmry

exogenousDat %>% group_by(key) %>% 
  summarise(exogenousWithdrawals = n()) -> exoSmry

merge(exoSmry,endoSmry,by="key") -> withdrawalSmry


unique(withdrawalSmry$endogenousWithdrawals+withdrawalSmry$exogenousWithdrawals )

merge(withdrawalSmry,resultDat,by="key") -> withdrawalSmry

ggplot(data=withdrawalSmry) + geom_point(aes(x=exogenousWithdrawals,y=endogenousWithdrawals,color=result)) +
  scale_x_log10() + scale_y_log10() + 
  xlab("Exogenous Withdrawals") + ylab("Endogenous Withdrawals") +
  ggtitle("Exogenous vs. Endogenous Withdrawals")


# now, get the total amount withdrawn both exogenously and endogenously as a % of the vault

# step 1, get initial vault
exogenousDat %>% group_by(key) %>% 
  summarise(initialVault = max(vault)) -> vaultSmry
# keep only the first row per key
exogenousDat %>% group_by(key) %>% 
  summarise(initialVault = first(deposit)) -> vaultSmry2
merge(vaultSmry,vaultSmry2,by="key") -> vaultSmry
vaultSmry$initialVault <- vaultSmry$initialVault.x + vaultSmry$initialVault.y

vaultSmry %>% select(key,initialVault) -> vaultSmry

endogenousDat %>% filter(withdraw) %>% group_by(key) %>% 
  summarise(endogenousWithdrawals = sum(deposit),endoWithdawCount=n()) -> endoSmry

resultControl %>% select(key) -> allRuns

merge(allRuns,endoSmry,by="key",all.x=TRUE) -> endoSmry
endoSmry$endogenousWithdrawals <- coalesce(endoSmry$endogenousWithdrawals,0)
endoSmry$endoWithdawCount <- coalesce(endoSmry$endoWithdawCount,0)


exogenousDat %>% group_by(key) %>% 
  summarise(exogenousWithdrawals = sum(deposit),exoWithdawCount=n()) -> exoSmry

merge(allRuns,exoSmry,by="key",all.x=TRUE) -> exoSmry
exoSmry$exogenousWithdrawals <- coalesce(exoSmry$exogenousWithdrawals,0)
exoSmry$exoWithdawCount <- coalesce(exoSmry$exoWithdawCount,0)

merge(vaultSmry,endoSmry,by="key") -> vault1
merge(vault1,exoSmry,by="key") -> vault2

vault2$exogPct <- 100*vault2$exogenousWithdrawals/vault2$initialVault
vault2$endoPct <- 100*vault2$endogenousWithdrawals/vault2$initialVault
merge(vault2,resultDat,by="key") -> vault2

control %>% select(key,depositInsuranceQuantile,reserveRatio) -> controlSmry
merge(vault2,controlSmry,by="key") -> vault2
ggplot(data=vault2) + geom_point(aes(x=exogPct,y=endoPct,shape=result,color=as.factor(reserveRatio))) +
  #scale_x_log10() + scale_y_log10() +
  # insert vertical line at x=1
  geom_vline(xintercept=100, linetype="dashed", color = "red") +
  # and horizontal line at y=1
  geom_hline(yintercept=100, linetype="dashed", color = "red") +
  xlab("Exogenous Withdrawals as % of Vault") + ylab("Endogenous Withdrawals as % of Vault") +
  ggtitle("Exogenous vs. Endogenous Withdrawals as % of Vault") + labs(color="Reserve Requirement",shape="Failure") +
  geom_segment(aes(x = 0, y = 100, xend = 100, yend = 0),
               color = "blue", linewidth = .1)


ggplot(data=vault2) + geom_point(aes(x=exoWithdawCount,y=endoWithdawCount,color=result)) +
  #scale_x_log10() + scale_y_log10() +
  # insert vertical line at x=1
  #geom_vline(xintercept=100, linetype="dashed", color = "red") +
  # and horizontal line at y=1
  #geom_hline(yintercept=100, linetype="dashed", color = "red") +
  xlab("Exogenous Withdrawals") + ylab("Endogenous Withdrawals") +
  ggtitle("Exogenous vs. Endogenous Withdrawals") + labs(color="Failure") 



# now, let's look at for each run, the % of agents withdrawing against the amount of money
vault2$withdrawalCount <- vault2$exoWithdawCount + vault2$endoWithdawCount
vault2$withdrawalPct <- vault2$exogPct + vault2$endoPct

ggplot(data=vault2) + geom_point(aes(x=withdrawalCount,y=withdrawalPct,color=result)) 

# now we need a function that, given a key, gives us the model history

modHistory <- function(currKey){
  # get the agents for this key
  agentsDat %>% transform(bool=(key==currKey)) %>%  filter(bool) %>% select(-bool) -> agentsKey
  # get the endogenous data for this key
  endogenousDat %>% transform(bool=(key==currKey)) %>%  filter(bool) %>% select(-bool) -> endoKey
  # get the exogenous data for this key
  exogenousDat %>% transform(bool=(key==currKey)) %>%  filter(bool) %>% select(-bool) -> exoKey
  # get the result for this key
  resultDat %>% transform(bool=(key==currKey)) %>%  filter(bool) %>% select(-bool) -> resultKey
  
  # now get the initial vault
  exoKey %>% group_by(key) %>% 
    summarise(initialDeposit = first(deposit),initialVault=first(vault)) %>%
    transform(totVault=initialDeposit+initialVault) -> vaultKey
  
  # now get total exogenous withdrawals
  if (nrow(exoKey) > 0){
    exoKey %>% group_by(key) %>% 
      summarise(exogenousWithdrawals = sum(deposit),exoWithdawCount=n()) -> exoSmryKey
  } else {
    exoSmryKey <- data.frame(key=currKey,exogenousWithdrawals=0,exoWithdawCount=0)
  }
  # now get total endogenous withdrawals by tick
  if (nrow(endoKey) > 0){
    endoKey %>% filter(withdraw) %>% group_by(key,tick) %>% 
      summarise(endogenousWithdrawals = sum(deposit),endoWithdawCount=n()) -> endoSmryKey
    if (nrow(endoSmryKey) > 0){
      endoSmryKey <- data.frame(key=currKey,tick=1,endogenousWithdrawals=0,endoWithdawCount=0)
    }
  } else {
    endoSmryKey <- data.frame(key=currKey,tick=1,endogenousWithdrawals=0,endoWithdawCount=0)
  }
  
  
}