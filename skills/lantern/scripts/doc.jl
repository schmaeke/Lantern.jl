# Print the docstrings of Lantern's API as installed in the active project, and where its manual is.
#
#     julia --project=ENV doc.jl morph slider! Lantern.px Timelines.cubic_bezier
#     julia --project=ENV doc.jl                                                   # the names and the manual's path

using Lantern, REPL

if isempty(ARGS)
    println("manual and examples: ", pkgdir(Lantern), "/docs/src/manual/ and ", pkgdir(Lantern), "/examples/")
    exported, public_only = (filter(f, filter(!=(:Lantern), names(Lantern))) for f in
                                                                                 (n -> Base.isexported(Lantern, n),
                                                                                  n -> !Base.isexported(Lantern, n)))
    println("exported: ", join(sort!(string.(exported)), " "))
    println("public, not exported (Lantern.name): ", join(sort!(string.(public_only)), " "))
end

for arg in ARGS
    println("─── ", arg)
    path = Symbol.(split(replace(arg, r"^Lantern\." => ""), '.'))
    try
        local m = Lantern
        for n in path[1:(end-1)]
            m = getglobal(m, n)
        end
        isdefined(m, path[end]) || (println("  not defined in Lantern"); continue)
        show(stdout, MIME"text/plain"(), Base.Docs.doc(Base.Docs.Binding(m, path[end])))
    catch err
        println("  ", sprint(showerror, err))
    end
    println()
end
