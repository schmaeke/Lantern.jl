# Build the manual:
#
#     julia --project=docs docs/make.jl
#
# The pages render their figures with CairoMakie while building (no GPU needed); the HTML goes
# to `docs/build/`. Code that opens windows (`present`, `preview`) is shown but not run.

using Documenter
using Lantern
using CairoMakie

CairoMakie.activate!(; type="png", px_per_unit=1)

include(joinpath(@__DIR__, "figures.jl"))      # Main.DocFigures: contact sheets for the pages

# Every docstring example runs with `using Lantern` (doctests in docstrings, if any).
DocMeta.setdocmeta!(Lantern, :DocTestSetup, :(using Lantern); recursive=true)

makedocs(; sitename="Lantern.jl", modules=[Lantern],
         format=Documenter.HTML(; prettyurls=get(ENV, "CI", nothing) == "true", edit_link="main",
                                size_threshold=400 * 1024,        # the API reference is a long page
                                size_threshold_warn=250 * 1024, collapselevel=1),
         pages=["Home" => "index.md",
                "Manual" => ["Concepts" => "manual/concepts.md", "Authoring" => "manual/authoring.md",
                             "Scene objects" => "manual/objects.md", "Equations" => "manual/equations.md",
                             "Text blocks and lists" => "manual/text.md", "Plots" => "manual/plots.md",
                             "Interactivity" => "manual/interactivity.md", "Layouts and themes" => "manual/layouts.md",
                             "Presenting" => "manual/presenting.md", "Export" => "manual/export.md",
                             "Extending Lantern" => "manual/extending.md"], "Architecture" => "architecture.md",
                "Reference" => ["API" => "reference/api.md", "Extension API" => "reference/internals.md"]],
         # Every exported or `public` name with a docstring must appear in the reference.
         checkdocs=:public, doctest=true, linkcheck=false)

# Deployment (not run yet). To publish the manual on GitHub Pages, the maintainer creates a
# deploy key (`using DocumenterTools; DocumenterTools.genkeys(user = "schmaeke", repo = "Lantern.jl")`),
# adds the public key as a deploy key with write access and the private key as the repository
# secret `DOCUMENTER_KEY`, and adds the secret to the docs job in `.github/workflows/CI.yml`.
# Then uncomment:
#
# if get(ENV, "CI", nothing) == "true" && haskey(ENV, "DOCUMENTER_KEY")
#     deploydocs(; repo = "github.com/schmaeke/Lantern.jl.git", devbranch = "main",
#         push_preview = false)
# end
