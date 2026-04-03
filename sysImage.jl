using PackageCompiler

create_sysimage(
    [
:Distributions,
:Random,
:CSV,
:DataFrames,
:Graphs,
:StatsBase,
:JLD2,
:Dates],
    sysimage_path = "sysimage.so")
