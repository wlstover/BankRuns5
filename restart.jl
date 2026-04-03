# first, check if there are any jld2 files in the data directory
# there may be several and need a list of them

jld2_files = []
for file in readdir(dataDir)
    if endswith(file, ".jld2")
        push!(jld2_files, joinpath(dataDir, file))
    end
end

# now read these files which contain dataframes and stack them
# call the stack jointFrame

jointFrame = DataFrame()
for file in jld2_files
    df = load_object(file)
    jointFrame = vcat(jointFrame, df)
end     


# now, load all completed models at paths which contain the string "bankRunResults"
completed_files = readdir(dataDir, join=true)
completed_files = filter(file -> occursin("bankRunResults", file), completed_files)
completed_models = DataFrame()
for file in completed_files
    df = CSV.read(file, DataFrame; header=false)
    completed_models = vcat(completed_models, df)
end 

# now name the first column :key and drop the second column
rename!(completed_models, :Column1 => :key)
select!(completed_models, Not(:Column2))

# Identify runs that haven't completed and trim outputs to those keys.
missing_keys = setdiff(jointFrame.key, completed_models.key)    

# now, read in the files containing the string "bankRunEndogenous" and remove any rows from missing_keys
# then write the CSV file back to the data directory
if !isempty(missing_keys)
    endogenous_files = readdir(dataDir, join=true)
    endogenous_files = filter(file -> occursin("bankRunEndogenous", file), endogenous_files)
    for file in endogenous_files
        df = CSV.read(file, DataFrame; header=false)
        # now filter the rows in df to only those in missing_keys
        df = innerjoin(df, DataFrame(key=missing_keys), on=:key)
        # now write the filtered data frame back to the file
        CSV.write(file, df, writeheader=false)
    end
end     

# now do the same for files containing the string "bankRunExogenous"
if !isempty(missing_keys)
    exogenous_files = readdir(dataDir, join=true)
    exogenous_files = filter(file -> occursin("bankRunExogenous", file), exogenous_files)
    for file in exogenous_files
        df = CSV.read(file, DataFrame; header=false)
        # now filter the rows in df to only those in missing_keys
        df = innerjoin(df, DataFrame(key=missing_keys), on=:key)
        # now write the filtered data frame back to the file
        CSV.write(file, df, writeheader=false)
    end
end 

# and for files containing "agents"
if !isempty(missing_keys)
    agent_files = readdir(dataDir, join=true)
    agent_files = filter(file -> occursin("agents", file), agent_files)
    for file in agent_files
        df = CSV.read(file, DataFrame; header=false)
        # now filter the rows in df to only those in missing_keys
        df = innerjoin(df, DataFrame(key=missing_keys), on=:key)
        # now write the filtered data frame back to the file
        CSV.write(file, df, writeheader=false)
    end
end 

# now, for the completed models, we want to set jointFrame.completed to true
for key in completed_models.key
    jointFrame[jointFrame.key .== key, :completed] .= true
end

println("Completed models updated in jointFrame.")
println(sum(jointFrame.completed), " models completed out of ", size(jointFrame, 1), " total.")
