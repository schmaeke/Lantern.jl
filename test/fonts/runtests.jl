# Fonts: the resolver, font themes (preferred, fail-safe, custom, fallbacks), fonts in Makie
# and in Typst math, fonts in PDFs. Machine-independent tests use fonts that ship with Makie
# and MathTeXEngine (a Makie dependency); tests of the maintainer's fonts run only where they
# are installed.
#
#     julia --project=test test/runtests.jl fonts/runtests.jl

using Test
using Lantern
using Lantern: Makie, MathLayouts, Font, findfont, with
using Lantern.MathLayouts: MathFonts, math_fonts, layout_math
using CairoMakie

const ASSETS = Makie.assetpath("fonts")
const MTE = joinpath(pkgdir(Makie.MathTeXEngine), "assets", "fonts")
const LUCIOLE_MATH = joinpath(MTE, "Luciole-Math", "Luciole-Math.otf")
const LUCIOLE = joinpath(MTE, "Luciole-Math", "Luciole-Regular.ttf")
const FAILSAFE = fonttheme(:failsafe)

@testset "resolver: bundled fonts by family and style" begin
    f = findfont("TeX Gyre Heros Makie", "Bold")
    @test f isa Font && basename(f.path) == "TeXGyreHerosMakie-Bold.otf" && !f.variable
    @test (f.family, f.style) == ("TeX Gyre Heros Makie", "Bold")
    # case, spaces and punctuation do not matter; "Regular" may be left out
    @test findfont("tex gyre heros makie", "BoldItalic") == findfont("TeX Gyre Heros Makie", "Bold Italic")
    @test basename(findfont("TeXGyreHerosMakie", "Regular Italic").path) == "TeXGyreHerosMakie-Italic.otf"
    @test findfont("TeX Gyre Heros Makie", "Italic") == findfont("TeX Gyre Heros Makie Italic")
    @test findfont("TeX Gyre Heros Makie") == FAILSAFE.text          # full name, no style
    # DejaVu calls its regular face "Book": found as "Regular"
    @test basename(findfont("DejaVu Sans Mono").path) == "DejaVuSansMono.ttf"
    # exact, not fuzzy: no other family or weight
    @test findfont("TeX Gyre Heros Makie", "Thin") === nothing
    @test findfont("TeX Gyre", "Regular") === nothing
    @test findfont("No Such Font Family Qx", "Regular") === nothing
    @test findfont("") === nothing
end

@testset "resolver: files, indices, search paths, cache" begin
    path = joinpath(ASSETS, "DejaVuSansMono.ttf")
    f = findfont(path)
    @test f.family == "DejaVu Sans Mono" && f.index == 0 && f.path == path
    @test findfont(path, 0) == f
    @test_throws ArgumentError findfont(path, 3)
    @test_throws ArgumentError findfont(joinpath(ASSETS, "nope.ttf"), 0)
    # user paths are searched first (a copy under another file name)
    mktempdir() do dir
        cp(path, joinpath(dir, "zz.ttf"))
        g = findfont("DejaVu Sans Mono", "Regular"; paths=[dir])
        @test g.path == joinpath(dir, "zz.ttf") && g.family == f.family
        @test findfont("DejaVu Sans Mono").path == path                # without: unchanged
    end
    # cached: the same face for the same query
    @test findfont("TeX Gyre Heros Makie", "Bold") === findfont("TeX Gyre Heros Makie", "Bold")
    # one native face per font (Makie's `to_font` takes `Font`s)
    @test Lantern.native(f) === Lantern.native(findfont(path)) === Makie.to_font(f)
    @test Makie.to_font(f) isa Makie.FreeTypeAbstraction.FTFont
    # the keys of a variable font's named instance: "Roboto" / "Condensed Bold" is also
    # "Roboto Condensed" / "Bold"
    @test ("robotocondensed", "bold") in Lantern.face_keys("Roboto", "Condensed Bold")
    @test ("robotocondensed", "regular") in Lantern.face_keys("Roboto", "Condensed Regular")
    @test ("roboto", "condensedbold") in Lantern.face_keys("Roboto", "Condensed Bold")
    @test !(("roboto", "bold") in Lantern.face_keys("Roboto", "Condensed Bold"))
    @test Lantern.has_math_table(findfont(LUCIOLE_MATH)) && !Lantern.has_math_table(f)
    @test !Lantern.has_math_table(FAILSAFE.text) && Lantern.has_math_table(FAILSAFE.math)
end

@testset "the maintainer's fonts (where installed)" begin
    rc = findfont("Roboto Condensed", "Bold")
    if rc === nothing
        @info "Roboto Condensed not installed; skipping the preferred-font tests"
    else
        @test occursin("Roboto", rc.family) &&
              occursin("Condensed", rc.family * " " * rc.style) &&
              occursin("Bold", rc.style)
        @test !occursin("Semi", rc.style) && !occursin("Extra", rc.style)
        # condensed: narrower than the regular-width bold
        rb = findfont("Roboto", "Bold")
        rb === nothing || @test Lantern.text_box("Finite elements", rc, (:left, :baseline)).widths[1] <
                                Lantern.text_box("Finite elements", rb, (:left, :baseline)).widths[1]
        @test findfont("Roboto Condensed Bold") == rc
        # GLMakie's glyph renderer gets a copy of the face with the same face index (Makie's
        # own copy would take face 0: the default instance, Roboto Regular)
        ft = Lantern.native(rc)
        @test ft.mmapped !== nothing
        copy_ = Makie.ATLAS_FONT_CACHE[ft]
        @test copy_ !== ft && copy_.face_index == rc.index && copy_.style_name == rc.style
    end
    io = findfont("Iosevka", "Regular")
    if io !== nothing
        @test io.family == "Iosevka" && io.style == "Regular"            # not Thin
        @test findfont("Iosevka") == io
        @test findfont("Iosevka Term").family == "Iosevka Term"
    end
    st = findfont("STIX Two Text", "Regular")
    if st !== nothing
        @test st.family == "STIX Two Text" && st.style == "Regular"      # not Medium
        # static files are preferred to a variable font of the same family
        statics = filter(f -> occursin(r"STIXTwoText-Regular\.otf$", f),
                         reduce(vcat, Lantern.dir_files.(Lantern.font_dirs())))
        isempty(statics) || @test !st.variable
    end
    if all(!isnothing, (rc, io, st, findfont("STIX Two Math")))
        ft = fonttheme(:preferred)
        @test ft.title == rc && ft.chrome.style == "Condensed Regular"
        @test ft.text == st && ft.code == io
        @test ft.math.family == "STIX Two Math" && ft.math_text == st
        @test findfont("STIX Two Text", "Italic") == ft.italic
    end
end

@testset "font themes" begin
    @test Lantern.Theme().fonts == FAILSAFE == fonttheme() == Deck().theme.fonts
    @test FAILSAFE.text.family == "TeX Gyre Heros Makie" && FAILSAFE.title.style == "Bold"
    @test FAILSAFE.code.family == "DejaVu Sans Mono"
    @test FAILSAFE.math == Lantern.TYPST_MATH_FONT && FAILSAFE.math_text === nothing
    @test isempty(FAILSAFE.math.path)
    @test_throws ArgumentError fonttheme(:fancy)
    @test_throws ArgumentError fonttheme(; heading="x")
    @test_throws ArgumentError fonttheme(; base=:failsafe, title=42)
    # roles from families: the role gives the style; chrome from the title, styles from the text
    ft = fonttheme(; base=:failsafe, title="TeX Gyre Heros Makie", text=LUCIOLE,
                   code=("TeX Gyre Heros Makie", "Italic"), math=LUCIOLE_MATH)
    @test ft.title == FAILSAFE.title && ft.chrome == FAILSAFE.chrome
    @test ft.text.path == LUCIOLE && ft.math_text == ft.text && ft.code == FAILSAFE.italic
    @test ft.math.path == LUCIOLE_MATH
    # of a (family, style) tuple only the family carries over to the derived roles (review)
    ft2 = fonttheme(; base=:failsafe, text=("TeX Gyre Heros Makie", "Italic"),
                    title=("TeX Gyre Heros Makie", "Regular"))
    @test ft2.text == FAILSAFE.italic && ft2.bold == FAILSAFE.bold && ft2.italic == FAILSAFE.italic
    @test ft2.bold_italic == FAILSAFE.bold_italic && ft2.math_text == FAILSAFE.text
    @test ft2.title == FAILSAFE.text && ft2.chrome == FAILSAFE.chrome
    @test fonttheme(; base=ft, code=:failsafe).code == FAILSAFE.code
    @test fonttheme(; base=ft, math_text=nothing).math_text === nothing
    @test fonttheme(; base=ft) == ft                       # values: equal by value
    @test hash(fonttheme(; base=ft)) == hash(ft)
    # Theme composition: colours and fonts independently
    th = Lantern.Theme(; colors=colortheme(:light), fonts=ft)
    @test th.fonts == ft && th.colors == colortheme(:light) && th.background == colortheme(:light).background
    d = Deck(; colortheme=colortheme(:dark), fonttheme=ft)
    @test d.theme.colors == colortheme(:dark) && d.theme.fonts == ft
    s = slide!(d; colortheme=colortheme(:light))
    @test s.theme.colors == colortheme(:light) && s.theme.fonts == ft
    s2 = slide!(d; fonttheme=:failsafe)
    @test s2.theme.colors == colortheme(:dark) && s2.theme.fonts == FAILSAFE
    @test with(th; fonts=:failsafe).fonts == FAILSAFE
    @test_throws ArgumentError Lantern.Theme(; colors=:tango)
    # builders use the roles
    @test label!(s, "x"; font=:title).font == ft.title
    @test label!(s, "x"; font=:chrome).font == ft.chrome
    @test code!(s, "x").font == ft.code
end

@testset "fallbacks: one warning per missing font and session" begin
    msg = r"\"No Such Family Q1\" not found \(font roles title, chrome\).*TeX Gyre Heros Makie"
    ft = @test_logs (:warn, msg) fonttheme(; base=:failsafe, title="No Such Family Q1")
    @test ft.title == FAILSAFE.title && ft.chrome == FAILSAFE.chrome
    @test_logs fonttheme(; base=:failsafe, title="No Such Family Q1")      # no warning
    # a missing text family: text roles fall back, text in equations to the math font's own
    ft = @test_logs (:warn, r"No Such Family Q2.*math_text") fonttheme(; base=:failsafe, text="No Such Family Q2")
    @test ft.text == FAILSAFE.text && ft.italic == FAILSAFE.italic && ft.math_text === nothing
    # a family without the role's style is missing too (no silent regular face)
    ft = @test_logs (:warn, r"Luciole") match_mode = :any fonttheme(; base=:failsafe, title="Luciole")
    @test ft.title == FAILSAFE.title
    # a math font needs a MATH table
    ft = @test_logs (:warn, r"no OpenType MATH table") fonttheme(; base=:failsafe,
                                                                 math=joinpath(ASSETS, "DejaVuSansMono.ttf"))
    @test ft.math == FAILSAFE.math
    # unknown names in builders fall back to the theme's text font
    s = Slide(; theme=Lantern.Theme())
    t = @test_logs (:warn, r"No Such Family Q3") label!(s, "x"; font="No Such Family Q3")
    @test t.font == FAILSAFE.text
end

@testset "fonts in Makie: chrome, text, axes, widgets" begin
    th = Lantern.Theme(; fonts=fonttheme(; base=:failsafe, text=LUCIOLE, code=joinpath(ASSETS, "DejaVuSansMono.ttf")))
    mt = Lantern.makie_theme(th)
    @test mt[:fonts][:regular][] === Lantern.native(th.fonts.text)
    @test mt[:fonts][:bold][] === Lantern.native(th.fonts.bold)
    @test mt[:fonts][:italic][] === Lantern.native(th.fonts.italic)
    d = Deck(; theme=th, title="T")
    slide!(d; title="Title", subtitle="Sub") do s
        label!(s, "content")
        axis!(s; rect=(-4, -2, 6, 3), xlabel="x") do ax
            lines!(ax, 1:3, 1:3)
        end
        slider!(s, 1:3; label="n")
    end
    v = materialize(d, 1; size=(320, 180))
    font_of(p) = Makie.to_value(p.font)
    allplots(sc) = vcat(sc.plots, reduce(vcat, allplots.(sc.children); init=Any[]))
    texts = filter(p -> p isa Makie.Text, allplots(Lantern.root_scene(v)))
    fonts = Set(font_of(p) for p in texts)
    @test Lantern.native(th.fonts.title) in fonts       # slide title
    @test Lantern.native(th.fonts.chrome) in fonts      # subtitle, footer
    @test Lantern.native(th.fonts.text) in fonts        # label, ticks, axis label
    @test Lantern.native(th.fonts.bold) in fonts        # slider label
end

@testset "equations: the theme's math fonts in Typst" begin
    B = MathLayouts.default_backend()        # the backend of `math!`
    @test math_fonts(FAILSAFE) == MathFonts()             # Typst defaults: unchanged layouts
    @test MathLayouts.font_rules(MathFonts()) == ""
    ft = fonttheme(; base=:failsafe, math=LUCIOLE_MATH, text=LUCIOLE)
    mf = math_fonts(ft)
    @test !isempty(mf.math) && mf.text == ft.text.family
    @test LUCIOLE_MATH in mf.files && LUCIOLE in mf.files
    rules = MathLayouts.font_rules(mf)
    @test occursin("#show math.equation: set text(font: ((name: \"$(mf.text)\"", rules)
    @test occursin("covers: regex(\"\\\\p{Latin}\")), \"$(mf.math)\"))", rules)
    @test MathLayouts.font_rules(MathFonts(; math="A \"B\"")) == "#show math.equation: set text(font: \"A \\\"B\\\"\")"
    # Typst finds the fonts (no "unknown font family" warning) and uses them
    src = "x + \"if\" y"
    lf = @test_logs min_level = Base.CoreLogging.Warn layout_math(B, src; fonts=mf)
    l0 = layout_math(B, src)
    @test length(lf.glyphs) == length(l0.glyphs)
    @test all(i -> lf.glyphs[i].key != l0.glyphs[i].key, eachindex(l0.glyphs))
    # text only: the math letters stay, the text letters change
    mt = math_fonts(fonttheme(; base=:failsafe, math_text=joinpath(ASSETS, "DejaVuSans.ttf")))
    @test isempty(mt.math) && mt.text == "DejaVu Sans"
    lt = layout_math(B, src; fonts=mt)
    @test lt.glyphs[1].key == l0.glyphs[1].key                       # x (math italic)
    @test lt.glyphs[3].key != l0.glyphs[3].key                       # "i" of "if"
    # cached per fonts and source; the font directory holds links to the files only
    @test layout_math(B, src; fonts=mf) === lf
    dir = MathLayouts.font_link_dir(unique(mf.files))
    @test length(readdir(dir)) == length(unique(mf.files))
    # `math!` uses the slide's theme; `morph` keeps the equation's fonts
    deck = Deck(; fonttheme=:failsafe)
    s1 = slide!(deck)
    s2 = slide!(deck; fonttheme=ft)
    e1, e2 = math!(s1, src), math!(s2, src)
    @test e1.fonts == MathFonts() && e2.fonts == mf
    @test e2.state.layout === lf && e1.state.layout === l0
    morph(e2, "y + \"if\" x")
    @test e2.state.layout === layout_math(B, "y + \"if\" x"; fonts=mf)
    @test MathLayouts.math_fonts(s2.theme) == mf
end

@testset "PDF export embeds the theme's fonts" begin
    pdffonts = Sys.which("pdffonts")
    if pdffonts === nothing
        @info "pdffonts not found; skipping the PDF font check"
    else
        mktempdir() do dir
            th = Lantern.Theme(; fonts=fonttheme(; base=:failsafe, text=LUCIOLE))
            d = Deck(; theme=th, title="fonts")
            slide!(d; title="Title") do s
                label!(s, "Luciole text")
                code!(s, "code()"; position=(-3, -2))
            end
            path = joinpath(dir, "fonts.pdf")
            export_pdf(d, path)
            out = read(`$pdffonts $path`, String)
            @test occursin("TeXGyreHerosMakieBold", out)          # title
            @test occursin("Luciole", out)                        # text
            @test occursin("DejaVuSansMono", out)                 # code
            # every font is embedded
            rows = filter(l -> occursin(r"^\S+\s", l), split(out, '\n')[3:end])
            @test all(l -> occursin(r"\byes\s+yes\s+yes", l), rows)
        end
    end
end
