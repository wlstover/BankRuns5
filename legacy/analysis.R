library(tidyverse)
library(data.table)
# list all files

list.files("../BankRunData/") -> allFi

resultsList <- list()

for (el in allFi[grepl("Results",allFi)]){
  read.csv(paste0("../BankRunData/",el),header=FALSE) -> resultsList[[length(resultsList)+1]]
}
rbindlist(resultsList) -> allResults
names(allResults) <- c("key","result")

allResults$result <- allResults$result=="true"
mean(allResults$result)
