# Plot themes and the default colour map. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl plots/plotthemes.jl

using Test
using Lantern
using Lantern: Makie, AxisBinding, LayerBinding, SlideView, DESIGN_PX_PER_UNIT, CairoMakieBackend, View, with
using Lantern.Colors: RGB, RGBA, red, green, blue
using CairoMakie

ptaxis(v::View) = only(filter(pb -> pb isa AxisBinding, v.content.plots))
ptlayer(v::View) = only(filter(pb -> pb isa LayerBinding, v.content.plots))
ptrender(v) = Lantern.capture(CairoMakieBackend(), v)
rgbclose(a, b; tol=1 / 255 + 1e-6) = all(abs(f(a) - f(b)) <= tol for f in (red, green, blue))

# The Tango colour map as ParaView defines it (control points at −1, −2/3, …, 1).
const TANGO_RGB = [(0.12549, 0.290196, 0.529412), (0.203922, 0.396078, 0.643137), (0.447059, 0.623529, 0.811765),
                   (0.45098, 0.823529, 0.086275), (0.929412, 0.831373, 0.0), (0.960784, 0.47451, 0.0),
                   (0.643137, 0.0, 0.0)]
function tango(x)
    j = clamp(floor(Int, 6x) + 1, 1, 6)
    t = 6x - (j - 1)
    return RGB((TANGO_RGB[j] .+ t .* (TANGO_RGB[j+1] .- TANGO_RGB[j]))...)
end

@testset "the colour map: 19 bands of Tango" begin
    cm = Lantern.colormap()
    @test cm isa Makie.PlotUtils.CategoricalColorGradient
    @test length(cm.colors) == 19 && cm.values ≈ range(0, 1; length=20)   # 19 equal bands
    # Sampled at x = 0, 1/18, …, 1 (endpoints included), linear in RGB.
    for i in 1:19
        @test RGB(cm.colors[i]) ≈ tango((i - 1) / 18) atol = 1e-12
    end
    # The control points are steps 1, 4, 7, …, 19 (x = 0, 1/6, …, 1): exact.
    for (i, c) in zip(1:3:19, TANGO_RGB)
        @test RGB(cm.colors[i]) == RGB(c...)
    end
    @test RGB(cm[0.5]) == RGB(TANGO_RGB[4]...)                # the middle band: green
    # Continuous and other step counts.
    cc = Lantern.colormap(; steps=nothing)
    @test cc isa Makie.PlotUtils.ContinuousColorGradient
    @test RGB(cc[0.5]) ≈ RGB(TANGO_RGB[4]...) && RGB(cc[0.1]) ≈ tango(0.1)
    @test length(Lantern.colormap(; steps=11).colors) == 11
    @test_throws ArgumentError Lantern.colormap(; steps=1)
    # NaN colour: grey, for the map with any steps; nothing for other maps.
    grey = RGBA{Float32}(0.533333, 0.541176, 0.521569, 1)
    @test Lantern.colormap_nan_color(cm) == Lantern.colormap_nan_color(cc) == grey
    @test Lantern.colormap_nan_color(Lantern.colormap(; steps=11)) == grey
    @test Lantern.colormap_nan_color(:viridis) === nothing
    @test Lantern.colormap_nan_color(Makie.cgrad(:viridis)) === nothing
end

@testset "plottheme: built-ins, keywords, validation" begin
    grey = Lantern.colormap_nan_color(Lantern.colormap())
    pd, pm = plottheme(:default), plottheme(:minimal)
    @test pd isa PlotTheme && pd.name == "default"
    @test pd.attributes.colormap == Lantern.colormap() && pd.attributes.nan_color == grey
    @test pm.attributes.colormap == Lantern.colormap()
    @test pm.attributes.Axis.xgridvisible === false && pm.attributes.Axis.ygridvisible === false
    @test pm.attributes.Lines.linewidth < 4
    @test plottheme(:default) == pd && hash(plottheme(:minimal)) == hash(pm)
    @test pd != pm
    @test_throws ArgumentError plottheme(:fancy)
    # Keywords merge over `base`, section by section.
    p = plottheme(; base=:minimal, Lines=(; linewidth=3), Axis=(; xgridvisible=true))
    @test p.attributes.Lines.linewidth == 3
    @test p.attributes.Axis.xgridvisible === true && p.attributes.Axis.ygridvisible === false
    @test p.attributes.Axis.spinewidth == pm.attributes.Axis.spinewidth
    @test plottheme(; base=p).attributes == p.attributes
    # A colour map brings its NaN colour: Makie's default for Makie's maps.
    v = plottheme(; colormap=:viridis)
    @test v.attributes.colormap === :viridis && v.attributes.nan_color == RGBA{Float32}(0, 0, 0, 0)
    @test plottheme(; colormap=:viridis, nan_color=:red).attributes.nan_color === :red
    a = plottheme(; colormap=Lantern.colormap(; steps=7))         # Lantern's map: its NaN colour
    @test a.attributes.nan_color == grey
    h = plottheme(; Heatmap=(; colormap=:viridis))
    @test h.attributes.Heatmap.nan_color == RGBA{Float32}(0, 0, 0, 0)
    @test h.attributes.nan_color == grey                   # the theme's own map keeps its NaN colour
    # A Makie theme converts.
    mt = plottheme(Makie.Theme(; Axis=(; xgridvisible=false), Lines=(; linewidth=2)))
    @test mt.attributes.Axis.xgridvisible === false && mt.attributes.Lines.linewidth == 2
    # Validation: unknown keys and attributes, sections that are not NamedTuples.
    msg(f) =
        try
            f()
            ""
        catch e
            sprint(showerror, e)
        end
    @test occursin("did you mean `Lines`?", msg(() -> plottheme(; lines=(; linewidth=2))))
    @test occursin("`xgridvisible`", msg(() -> plottheme(; Axis=(; xgridvisble=false))))
    @test occursin("NamedTuple", msg(() -> plottheme(; Axis=3)))
    @test occursin("unknown key `foo`", msg(() -> plottheme(; foo=1)))
    @test occursin("`linewidth`", msg(() -> plottheme(; Lines=(; linwidth=2))))
    @test_throws ArgumentError Lantern.Theme(; plots=(; Lines=(; linewidth=2)))
    @test_throws ArgumentError Deck(; plottheme="minimal")
    # Composition: Theme, with, Deck, slide!.
    th = Lantern.Theme(; plots=:minimal)
    @test th.plots == pm && with(th; plots=:default).plots == pd
    @test Lantern.Theme().plots == pd
    d = Deck(; colortheme=colortheme(:light), plottheme=:minimal)
    @test d.theme.plots == pm && d.theme.colors == colortheme(:light)
    s1 = slide!(d)
    s2 = slide!(d; plottheme=:default)
    s3 = slide!(d; colortheme=colortheme(:dark))
    @test s1.theme.plots == pm && s2.theme.plots == pd && s3.theme.plots == pm
    @test s2.theme.colors == colortheme(:light)
    @test occursin("\"minimal\" plots", repr(d.theme))
end

@testset "makie_theme: plot theme merged over Lantern's defaults" begin
    base = Lantern.Theme()
    th = Lantern.Theme(; plots=plottheme(; Lines=(; linewidth=2.5), Axis=(; xgridvisible=false, xgridcolor=:red)))
    m0, m = Lantern.makie_theme(base), Lantern.makie_theme(th)
    @test m[:Lines][:linewidth][] == 2.5                     # the plot theme wins
    @test m[:Axis][:xgridvisible][] === false && m[:Axis][:xgridcolor][] === :red
    # … attribute by attribute: colours and fonts still from the colour and font themes.
    @test m[:Axis][:ygridcolor][] == m0[:Axis][:ygridcolor][]
    @test m[:Axis][:xticklabelcolor][] == th.text
    @test m[:Axis][:xticklabelsize][] == m0[:Axis][:xticklabelsize][]
    @test m[:fonts][:regular][] == m0[:fonts][:regular][]
    @test m[:palette][:color][] == th.cycle
    @test m[:Scatter][:markersize][] == m0[:Scatter][:markersize][]
    # Colour map and NaN colour of every plot type with one.
    @test m0[:colormap][] == Lantern.colormap()
    for P in (:Heatmap, :Surface, :Mesh, :Scatter, :Contourf, :Image, :Lines)
        @test m0[P][:nan_color][] == Lantern.colormap_nan_color(Lantern.colormap())
    end
    # A top-level size replaces Lantern's per-plot-type default of that name.
    mt = Lantern.makie_theme(Lantern.Theme(; plots=plottheme(; linewidth=1.5, markersize=7)))
    @test mt[:linewidth][] == 1.5 && !haskey(mt[:Lines], :linewidth)
    @test !haskey(mt[:Scatter], :markersize) && haskey(mt[:Scatter], :strokecolor)
    # The plot theme's colour map without `nan_color`: Makie's default NaN colour.
    mv = Lantern.makie_theme(Lantern.Theme(; plots=plottheme(; colormap=:viridis)))
    @test mv[:Heatmap][:nan_color][] == RGBA{Float32}(0, 0, 0, 0)
end

# A slide with a heatmap of the values 0, 1/(n-1), …, 1, one cell per band of the default colour
# map, NaN in a second row, a colour bar, and a line plot.
const NB = length(Lantern.colormap().colors)
function band_deck(; kw...)
    d = Deck(; kw...)
    slide!(d; title="bands") do s
        z = reshape(vcat(collect(range(0, 1; length=NB)), fill(NaN, NB)), NB, 2)
        axis!(s; rect=(-7, -3, 14, 6), limits=(0.5, NB + 0.5, 0.5, 2.5), colorbar=(label="u",)) do ax
            heatmap!(ax, 1:NB, 1:2, z; colorrange=(0, 1))
        end
    end
    return d
end

@testset "default colour map on a heatmap in an axis (pixels)" begin
    grey = Lantern.colormap_nan_color(Lantern.colormap())
    v = materialize(band_deck(), 1; size=(960, 540))
    ab = ptaxis(v)
    hm = ab.layers[1].plots[1].plot
    @test hm.colormap[] == Lantern.colormap()
    @test Makie.to_color(hm.nan_color[]) == grey
    img = ptrender(v)
    vp = ab.block.scene.viewport[]
    (x0, y0), (w, h) = minimum(vp), widths(vp)
    H = size(img, 1)
    px_at(fx, fy) = img[H - round(Int, y0 + fy * h), round(Int, x0 + fx * w) + 1]
    cm = Lantern.colormap()
    for k in 1:NB          # cell k shows step k (value (k-1)/(NB-1) is in band k)
        @test rgbclose(px_at((k - 0.5) / NB, 0.25), cm.colors[k])
    end
    @test all(rgbclose(px_at((k - 0.5) / NB, 0.75), grey) for k in 1:NB)
    # The colour bar shows the bands.
    bb = ab.colorbar.layoutobservables.computedbbox[]
    (bx, by), (bw, bh) = minimum(bb), widths(bb)
    bar_at(fy) = img[H - round(Int, by + fy * bh), round(Int, bx + bw / 2) + 1]
    @test all(rgbclose(bar_at((k - 0.5) / NB), cm.colors[k]; tol=2 / 255) for k in 1:NB)
    # A plot call with its own colour map: that map's NaN colour (transparent for Makie's).
    d = Deck()
    slide!(d) do s
        axis!(s) do ax
            heatmap!(ax, [1.0 NaN; 2 3]; colormap=:viridis)
            heatmap!(ax, [1.0 NaN; 2 3]; colormap=:viridis, nan_color=:red)
            heatmap!(ax, [1.0 NaN; 2 3]; colormap=Lantern.colormap(; steps=7))
        end
        makie!(s) do sc
            heatmap!(sc, [1.0 NaN; 2 3]; colormap=:inferno)
        end
    end
    v2 = materialize(d, 1; size=(320, 180))
    ps = [m.plot for m in ptaxis(v2).layers[1].plots]
    @test Makie.to_color(ps[1].nan_color[]) == RGBA{Float32}(0, 0, 0, 0)
    @test Makie.to_color(ps[2].nan_color[]) == Makie.to_color(:red)
    @test Makie.to_color(ps[3].nan_color[]) == grey
    @test Makie.to_color(ptlayer(v2).plots[1].plot.nan_color[]) == RGBA{Float32}(0, 0, 0, 0)
    # A plot theme's colour map is used instead.
    v3 = materialize(band_deck(; plottheme=plottheme(; colormap=:viridis)), 1; size=(320, 180))
    hm3 = ptaxis(v3).layers[1].plots[1].plot
    @test hm3.colormap[] === :viridis
    @test Makie.to_color(hm3.nan_color[]) == RGBA{Float32}(0, 0, 0, 0)
end

@testset "plot themes: per-slide override, rescaling of user sizes" begin
    pt = plottheme(; base=:minimal, Lines=(; linewidth=3), Scatter=(; markersize=10), Text=(; fontsize=30),
                   Axis=(; xticksize=20, ytickwidth=3), Colorbar=(; size=30), Legend=(; framewidth=4))
    d = Deck(; plottheme=pt)
    for theme_override in (nothing, :default)
        slide!(d; plottheme=theme_override) do s
            axis!(s; colorbar=true, legend=true) do ax
                lines!(ax, 1:3; label="a")
                scatter!(ax, 1:3)
                text!(ax, 1, 1; text="t")
                heatmap!(ax, rand(3, 3))
            end
            makie!(s) do sc
                lines!(sc, [Point2f(0, 0), Point2f(1, 1)])
            end
        end
    end
    big = materialize(d, 1; size=(1920, 1080))
    small = materialize(d, 1; size=(960, 540))
    for (v, f) in ((big, 1), (small, 0.5))
        ab = ptaxis(v)
        ps = [m.plot for m in ab.layers[1].plots]
        @test ps[1].linewidth[] ≈ 3f && all(≈(10f), ps[2].markersize[])
        @test ps[3].fontsize[] ≈ 30f
        @test ab.block.xticksize[] ≈ 20f && ab.block.ytickwidth[] ≈ 3f
        @test ab.block.xgridvisible[] === false                  # from :minimal
        @test ab.block.spinewidth[] ≈ 1.5f
        @test ab.colorbar.size[] ≈ 30f && ab.legend.framewidth[] ≈ 4f
        @test ptlayer(v).plots[1].plot.linewidth[] ≈ 3f          # body layers too
    end
    # A resize rescales the plot theme's sizes like Lantern's.
    Lantern.root_scene(small).viewport[] = Lantern.Rect2i(0, 0, 1920, 1080)
    @test ptaxis(small).layers[1].plots[1].plot.linewidth[] ≈ 3
    @test ptaxis(small).block.xticksize[] ≈ 20
    # The second slide overrides the deck's plot theme: Lantern's defaults.
    v2 = materialize(d, 2; size=(1920, 1080))
    ab2 = ptaxis(v2)
    @test ab2.block.xgridvisible[] === true && ab2.block.xticksize[] ≈ 10
    @test ab2.layers[1].plots[1].plot.linewidth[] ≈ 4
end

@testset "plot themes leave Makie's global theme alone" begin
    before = deepcopy(Makie.current_default_theme())
    cm_before = Makie.current_default_theme()[:colormap][]
    v = materialize(band_deck(; plottheme=:minimal), 1; size=(320, 180))
    ptrender(v)
    @test Makie.current_default_theme()[:colormap][] == cm_before
    @test !haskey(Makie.current_default_theme(), :nan_color)
    @test keys(Makie.current_default_theme()) == keys(before)
    # A plain Makie figure still uses Makie's defaults.
    f = Figure()
    ax = Axis(f[1, 1])
    hm = heatmap!(ax, [1.0 NaN; 2 3])
    l = lines!(ax, 1:3)
    @test hm.colormap[] == cm_before
    @test Makie.to_color(hm.nan_color[]) == RGBA{Float32}(0, 0, 0, 0)
    @test ax.xgridvisible[] === true
    @test l.linewidth[] == Makie.current_default_theme()[:linewidth][]
end
