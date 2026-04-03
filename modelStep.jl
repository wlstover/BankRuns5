# first, read a row from the parameter file

# then set up the model


# then run the model
rMod=modelRun(mod)
println(rMod)
println(mod.theBank.vault)


# indicate it is finished with a symbol
:complete