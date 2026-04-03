# this code renders the extra columns in the jld2 dataframe readable by R
using StatsBase
using DataFrames
using JLD2
using Dates
using CSV
using Random
using Distributions
using Graphs

# we need a function that turns an array of tuples into a matrix


dataSource="../BankRunDataBig/"
tst= jldopen(dataSource, "r")
jointFrame=tst["single_stored_object"]

# now we need a CSV that has all the relevant information
# the pareto parameters

# the network parameters

# the Binomial parameters

# the reserve Ratio

# the deposit insurance quantile

# of course, some of these require multiple columns so we use indices

# step 1: deposit distribution

depositFrame=DataFrame(params.(jointFrame.depositDist))
rename!(depositFrame,:1 => :alpha,:2 => :theta)

withdrawFrame=DataFrame(params.(jointFrame.withdrawRV))
rename!(withdrawFrame,:1 => :n,:2 => :p)

finFrame=hcat(depositFrame,withdrawFrame)

# now add information
finFrame.key=jointFrame.key
finFrame.seed1=jointFrame.seed1
finFrame.seed2=jointFrame.seed2
finFrame.reserveRatio=jointFrame.reserveRatio
finFrame.depositInsuranceQuantile=jointFrame.depositInsuranceQuantile
finFrame.centrality=betweenness_centrality.(jointFrame.network)
# now write out to CSV
CSV.write("../bankRunData/supplemental.csv",finFrame,writeheader=true,append=false)

# graph information
#radiusG=radius.(jointFrame.network)
#degreeC=degree_centrality.(jointFrame.network) # degree centrality
#closeCent=closeness_centrality.(jointFrame.network) # closeness centrality
#betweenCent=betweenness_centrality.(jointFrame.network) # betweenness centrality
#eigenCent=eigenvector_centrality.(jointFrame.network) # Eigenvector centrality
#averagePathLength=average_path_length.(jointFrame.network) # mean path length
#clusteringCoeff=clustering_coefficient.(jointFrame.network) # clustering coefficient
#triangles=triangle_count.(jointFrame.network) # triangle count

#key123465722025-07-03T14:44:17.037.jld2
