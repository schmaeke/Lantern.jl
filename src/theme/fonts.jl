# Fonts: a small resolver from family and style names to font faces
# (files, collections and named instances of variable fonts), and the font roles of themes
# with their bundled fallbacks.
#
# Makie's own name lookup (`Makie.to_font("Roboto Condensed")`) is a fuzzy score over the
# family and style names of the first face of every file; it picks other families ("DIN
# Condensed"), other weights ("Iosevka" → Thin) and never sees named instances of variable
# fonts. Lantern matches exactly instead and hands Makie the face (`Makie.to_font(::Font)`).

const FTA = Makie.FreeTypeAbstraction
const FT = Makie.FreeType

"""
    Lantern.Font

One font face: `family` and `style` as the font names them (FreeType's names: the
typographic family and subfamily), the font file `path` and the FreeType face `index` (the
face in a collection, plus `2^16 k` for the `k`-th named instance of a variable font), and
whether the font is `variable`. A `Font` is a plain value; [`Lantern.findfont`](@ref) finds
one, and Makie accepts it wherever it takes a font (`text!(…; font = f)`). Fonts built into
the math engine (Typst's New Computer Modern Math) have an empty `path`.
"""
struct Font
    family::String
    style::String
    path::String
    index::Int
    variable::Bool
end

function Base.show(io::IO, f::Font)
    print(io, "Lantern.Font(", repr(f.family * " " * f.style))
    isempty(f.path) ? print(io, ", built into Typst") : print(io, ", ", repr(f.path))
    f.index == 0 || print(io, ", index ", f.index)
    print(io, ")")
end

const FONT_EXTENSIONS = (".ttf", ".otf", ".ttc", ".otc")
# Style words that mean "the upright, normal weight" (dropped when other words are present).
const REGULAR_WORDS = ("regular", "normal", "roman")

# Names compare case-insensitively, ignoring spaces and punctuation: "STIX Two Text" ==
# "STIXTwoText", "Bold Italic" == "BoldItalic".
normname(s::AbstractString) = lowercase(filter(c -> isletter(c) || isdigit(c), s))
name_words(s::AbstractString) = split(lowercase(s), r"[\s_\-]+"; keepempty=false)
function style_key(words)
    w = filter(t -> !(t in REGULAR_WORDS), words)
    return isempty(w) ? "regular" : join(w)
end
# Query keys for a family and style words: some families call their regular face "Book"
# (DejaVu); that is tried after "Regular" (other families have both, "Book" being lighter).
function query_keys(family, words)
    k = style_key(words)
    return k == "regular" ? [(family, k), (family, "book")] : [(family, k)]
end

# A face of the index and the (family, style) keys it answers to: its own names, and every
# split of its style words into family and style, so that a variable font's named instance
# "Roboto" / "Condensed Bold" is also "Roboto Condensed" / "Bold" (and a static font with the
# typographic names "Roboto" / "Condensed Bold" likewise).
struct FaceRecord
    font::Font
    keys::Vector{Tuple{String,String}}
    rank::Int    # 0 static, 1 named instance, 2 default instance of a variable font
end

function face_keys(family, style)
    sw = name_words(style)
    f = normname(family)
    return unique!([(f * join(sw[1:k]), style_key(sw[(k+1):end])) for k in 0:length(sw)])
end

# --- reading faces ----------------------------------------------------------------------------

open_face(path::AbstractString, index::Integer) =
    try
        return FTA.newface(String(path), index)
    catch
        return nothing
    end
close_face(ptr) = @lock FTA.LIBRARY_LOCK FT.FT_Done_Face(ptr)

cstr(p) = p == C_NULL ? "" : unsafe_string(p)

# All faces of a font file: every face of a collection and every named instance of a
# variable font (face index `(k << 16) | i` for instance `k` of face `i`). Each face is opened
# once; it tells the number of faces (face 0), whether it is variable and its instances.
function scan_file(path::AbstractString)
    out = FaceRecord[]
    nfaces, i = 1, 0
    while i < nfaces
        n, variable, ninstances = scan_face!(out, path, i, 0, false)
        i == 0 && (nfaces = n)
        for k in 1:ninstances
            scan_face!(out, path, (k << 16) | i, k, variable)
        end
        i += 1
    end
    return out
end

# Record the face `index` of `path` (if it opens and has a family name); returns the face's
# number of faces in the file, whether it is variable and its number of named instances.
function scan_face!(out, path, index, instance, variable)
    ptr = open_face(path, index)
    ptr === nothing && return 0, false, 0
    rec = unsafe_load(ptr)
    family, style = cstr(rec.family_name), cstr(rec.style_name)
    instance == 0 && (variable = (rec.face_flags & FT.FT_FACE_FLAG_MULTIPLE_MASTERS) != 0)
    info = Int(rec.num_faces), variable, Int(rec.style_flags >> 16)
    close_face(ptr)
    rank = !variable ? 0 : instance > 0 ? 1 : 2
    isempty(family) ||
        push!(out, FaceRecord(Font(family, style, String(path), index, variable), face_keys(family, style), rank))
    return info
end

# --- the index --------------------------------------------------------------------------------
# Built lazily and kept in memory for the session: font files per directory (one recursive
# listing), faces per file (scanned when a lookup needs the file), answers per query.

const FONT_LOCK = ReentrantLock()
const DIR_FILES = Dict{String,Vector{String}}()
const FILE_FACES = Dict{String,Vector{FaceRecord}}()
const FONT_QUERIES = Dict{Any,Union{Nothing,Font}}()
const NATIVE_FONTS = Dict{Tuple{String,Int},Any}()
const WARNED_FONTS = Set{String}()

function clear_font_caches!()
    lock(() -> foreach(empty!, (DIR_FILES, FILE_FACES, FONT_QUERIES, NATIVE_FONTS)), FONT_LOCK)
    return nothing
end

"""
    Lantern.font_dirs() -> Vector{String}

The directories [`Lantern.findfont`](@ref) searches (recursively), in order: the platform's
font directories (macOS: `~/Library/Fonts`, `/Library/Fonts`, `/System/Library/Fonts`; Linux:
`\$XDG_DATA_HOME/fonts`, `~/.fonts`, `/usr/share/fonts`, `/usr/local/share/fonts`; Windows:
`%LOCALAPPDATA%\\Microsoft\\Windows\\Fonts`, `%WINDIR%\\Fonts`), then Makie's bundled fonts.
"""
function font_dirs()
    home = homedir()
    dirs = if Sys.isapple()
        [joinpath(home, "Library", "Fonts"), "/Library/Fonts", "/System/Library/Fonts"]
    elseif Sys.iswindows()
        d = String[]
        haskey(ENV, "LOCALAPPDATA") && push!(d, joinpath(ENV["LOCALAPPDATA"], "Microsoft", "Windows", "Fonts"))
        push!(d, joinpath(get(ENV, "WINDIR", "C:\\Windows"), "Fonts"))
        d
    else
        xdg = get(ENV, "XDG_DATA_HOME", joinpath(home, ".local", "share"))
        [joinpath(xdg, "fonts"), joinpath(home, ".fonts"), "/usr/share/fonts", "/usr/local/share/fonts"]
    end
    push!(dirs, Makie.assetpath("fonts"))
    return dirs
end

is_font_file(f) = lowercase(splitext(f)[2]) in FONT_EXTENSIONS

dir_files(dir::AbstractString) = get!(DIR_FILES, dir) do
    files = String[]
    if isfile(dir)
        push!(files, dir)
    elseif isdir(dir)
        for (root, _, fs) in walkdir(dir; onerror=_ -> nothing)
            for f in sort!(fs)
                is_font_file(f) && push!(files, joinpath(root, f))
            end
        end
    end
    files
end

file_faces(path) = get!(() -> scan_file(path), FILE_FACES, path)

function search_files(dirs)
    seen = Set{String}()
    out = String[]
    for d in dirs, f in dir_files(d)
        f in seen || (push!(seen, f); push!(out, f))
    end
    return out
end

# The best face answering to one of `keys` (tried in order) among `files`: static fonts
# before named instances before default instances of variable fonts, then in search order.
function best_face(files, keys)
    for key in keys
        best = nothing
        for (order, f) in enumerate(files), r in file_faces(f)
            key in r.keys || continue
            score = (r.rank, order, r.font.index)
            (best === nothing || score < best[1]) && (best = (score, r.font))
        end
        best === nothing || return best[2]
    end
    return nothing
end

# Look up `keys` (candidate (family, style) keys, best first): first in every file of the
# user's `paths`, then in the system's font files whose names contain `token` (the first word
# of the family: "STIXTwoText-Regular.otf" for "STIX Two Text"), then, if that finds nothing,
# in every other file.
function lookup_font(keys, token::AbstractString, paths)
    lock(FONT_LOCK) do
        get!(FONT_QUERIES, (keys, paths)) do
            user = search_files(map(p -> abspath(expanduser(p)), paths))
            font = best_face(user, keys)
            font === nothing || return font
            files = setdiff(search_files(font_dirs()), user)
            likely = filter(f -> occursin(token, normname(basename(f))), files)
            font = best_face(likely, keys)
            font === nothing || return font
            return best_face(setdiff(files, likely), keys)
        end
    end
end

"""
    Lantern.findfont(family, style; paths = String[]) -> Union{Font,Nothing}
    Lantern.findfont(name; paths = String[]) -> Union{Font,Nothing}
    Lantern.findfont(file, index = 0) -> Font

Find an installed font face by its family and style names, e.g. `findfont("Roboto
Condensed", "Bold")`, or by its full name `"Roboto Condensed Bold"` (split into family and
style at the last possible word). Names match exactly, ignoring case, spaces and
punctuation; "Regular" may be left out of a style ("Italic" = "Regular Italic"), and a
regular face named "Book" is found as "Regular" if there is no "Regular". Variable
fonts contribute their named instances: the instance "Condensed Bold" of the family "Roboto"
is also "Roboto Condensed" / "Bold". Static fonts are preferred to variable ones of the same
name. Returns `nothing` if no face matches.

Searched are `paths` (directories, searched recursively, or font files), then
[`Lantern.font_dirs`](@ref) (the platform's font directories and Makie's bundled fonts). The
index is built lazily, scanning first the files whose names contain the family's first word,
and kept for the session. With a font file (`.ttf`, `.otf`, `.ttc`, `.otc`) instead of a
name, the face `index` of that file is returned.
"""
function findfont(family::AbstractString, style::AbstractString; paths=String[])
    isempty(strip(family)) && return nothing
    words = name_words(family)
    return lookup_font(query_keys(normname(family), name_words(style)), normname(first(words)),
                       String[String(p) for p in paths])
end

function findfont(name::AbstractString; paths=String[])
    file = expanduser(name)
    is_font_file(file) && isfile(file) && return findfont(file, 0)
    words = name_words(name)
    isempty(words) && return nothing
    # Longest family first: "Iosevka Term" is the family "Iosevka Term", not "Iosevka" /
    # "Term"; a name without style words is the regular face.
    keys = reduce(vcat, [query_keys(normname(join(words[1:k])), words[(k+1):end]) for k in length(words):-1:1])
    return lookup_font(keys, normname(first(words)), String[String(p) for p in paths])
end

function findfont(file::AbstractString, index::Integer)
    path = abspath(expanduser(file))
    isfile(path) || throw(ArgumentError("findfont: no font file $(repr(file))"))
    lock(FONT_LOCK) do
        r = findfirst(r -> r.font.index == index, file_faces(path))
        r === nothing && throw(ArgumentError("findfont: $(repr(file)) has no face $index " *
                                             "(faces: $(join((r.font.index for r in file_faces(path)), ", ")))"))
        return file_faces(path)[r].font
    end
end

"""
    Lantern.native(font::Font) -> Makie.NativeFont

The FreeType face of `font` for Makie (cached per file and face index, so equal fonts give
the same object). `Makie.to_font(font)` calls it.
"""
function native(f::Font)
    isempty(f.path) &&
        throw(ArgumentError("$f is built into Typst (math only); text " * "outside equations needs a font file"))
    lock(FONT_LOCK) do
        get!(NATIVE_FONTS, (f.path, f.index)) do
            # Index 0 through Makie's own cache (shared with plots that name the file). Faces
            # are memory-mapped: GLMakie copies them for its glyph renderer.
            f.index == 0 && return Makie.to_font(f.path)
            face, data = FTA.newface_mmapped(f.path, f.index)
            ft = FTA.FTFont(face, true, data)
            register_atlas_copy!(ft, f)
            ft
        end
    end
end

Makie.to_font(f::Font) = native(f)

# GLMakie and WGLMakie render glyphs into their atlas from a copy of the face that Makie makes
# from the mapped file with face index 0 (`Makie.copy_font`), i.e. the first face of a
# collection or the default instance of a variable font: Iosevka would render Thin, Roboto
# Condensed Bold as Roboto Regular. Makie looks the copy up in `ATLAS_FONT_CACHE` first, so
# Lantern puts a copy with the right face index there.
function register_atlas_copy!(ft, f::Font)
    isdefined(Makie, :ATLAS_FONT_CACHE) || return nothing
    face, data = FTA.newface_mmapped(f.path, f.index)
    Makie.ATLAS_FONT_CACHE[ft] = FTA.FTFont(face, true, data)
    return nothing
end

# Does the face have an OpenType MATH table (needed for a math font)?
function has_math_table(f::Font)
    isempty(f.path) && return true
    ptr = open_face(f.path, f.index)
    ptr === nothing && return false
    len = Ref{Culong}(0)
    tag = (UInt32('M') << 24) | (UInt32('A') << 16) | (UInt32('T') << 8) | UInt32('H')
    err = ccall((:FT_Load_Sfnt_Table, FT.libfreetype), Cint, (Ptr{Cvoid}, Culong, Clong, Ptr{UInt8}, Ref{Culong}), ptr,
                tag, 0, C_NULL, len)
    close_face(ptr)
    return err == 0 && len[] > 0
end

# --- font themes ------------------------------------------------------------------------------

"""
    FontTheme

The fonts of a [`Lantern.Theme`](@ref), one [`Lantern.Font`](@ref) per role:
- `title`: slide titles, the title slide's title and author, section names (bold);
- `chrome`: subtitles, footers, slide numbers, the title slide's venue and date, the
  presenter view;
- `text`, `bold`, `italic`, `bold_italic`: content text: labels, axes, legends, colour bars,
  widgets, text in `makie!` layers (Makie's `:regular`, `:bold`, `:italic`, `:bold_italic`);
- `code`: [`code!`](@ref) and `font = :mono`;
- `math`: equations (an OpenType math font, set by Typst);
- `math_text`: text inside equations (`"…"`, `upright`, operators such as `sin`), or
  `nothing` for the math font's own letters.

Make one with [`fonttheme`](@ref): `fonttheme(:preferred)`, `fonttheme(:failsafe)` or
`fonttheme(; text = "Fira Sans", …)`. A font theme is a plain value; compose it with a
[`ColorTheme`](@ref) in a `Theme`, `Deck(; fonttheme)` or `slide!(deck; fonttheme)`.
"""
struct FontTheme
    title::Font
    chrome::Font
    text::Font
    bold::Font
    italic::Font
    bold_italic::Font
    code::Font
    math::Font
    math_text::Union{Nothing,Font}
end

function Base.show(io::IO, f::FontTheme)
    name(x) = x === nothing ? "nothing" : x.family * " " * x.style
    print(io, "FontTheme(title = ", repr(name(f.title)), ", text = ", repr(name(f.text)), ", math = ",
          repr(name(f.math)), ", code = ", repr(name(f.code)), ", …)")
end

const FONT_ROLES = fieldnames(FontTheme)
const ROLE_STYLE = (title="Bold", chrome="Regular", text="Regular", bold="Bold", italic="Italic",
                    bold_italic="Bold Italic", code="Regular", math="Regular", math_text="Regular")

# The preferred font theme (each font falls back to the fail-safe font of its role when it is
# not installed).
const PREFERRED_FONTS = (title="Roboto Condensed", text="STIX Two Text", math="STIX Two Math", code="Iosevka")

# Typst's bundled math font (no file: the math backend's default).
const TYPST_MATH_FONT = Font("New Computer Modern Math", "Regular", "", 0, false)

const failsafe_fonts = OncePerProcess{FontTheme}() do
    dir = Makie.assetpath("fonts")
    file(name) = findfont(joinpath(dir, name), 0)
    heros(s) = file("TeXGyreHerosMakie-$s.otf")
    return FontTheme(heros("Bold"), heros("Regular"), heros("Regular"), heros("Bold"), heros("Italic"),
                     heros("BoldItalic"), file("DejaVuSansMono.ttf"), TYPST_MATH_FONT, nothing)
end

failsafe_role(role::Symbol) = getfield(failsafe_fonts(), role)

"""
    fonttheme(name::Symbol) -> FontTheme
    fonttheme(; base = :failsafe, paths = String[], roles...) -> FontTheme

The font themes that ship with Lantern:
- `:failsafe` (the default): only fonts that ship with Makie and Typst, identical on every
  machine: TeX Gyre Heros Makie (titles, chrome, text), DejaVu Sans Mono (code), New Computer
  Modern Math (equations, with its own text letters).
- `:preferred`: Roboto Condensed (titles bold, chrome regular), STIX Two Text
  (text, also inside equations), STIX Two Math (equations), Iosevka (code). Each font that is
  not installed is replaced by the fail-safe font of its role, with one warning per font and
  session.

With keywords, a font theme from `base` (a name or a `FontTheme`) with some roles replaced
(roles: see [`FontTheme`](@ref)). A value is a family name (the role gives the style: `title`
bold, `italic` italic, …; `chrome = "Roboto Condensed Light"` works too, as the family
"Roboto Condensed Light"), a `(family, style)` tuple, a font file, a [`Lantern.Font`](@ref)
or `:failsafe` (that role's fail-safe font);
`math_text` may be `nothing`. A given `title` family also sets `chrome` (regular), a given
`text` family also `bold`, `italic`, `bold_italic` and `math_text`, unless those are given
too (of a `(family, style)` tuple, only the family carries over). `paths` (font directories
or files) are searched before the system's fonts. Fonts that are not found fall back as for
`:preferred`.

```julia
fonttheme(; title = "Fira Sans Condensed", text = "Fira Sans", math = "Fira Math",
          code = "Fira Code")
```
"""
function fonttheme(name::Symbol)
    name === :failsafe && return failsafe_fonts()
    name === :preferred && return fonttheme(; base=failsafe_fonts(), PREFERRED_FONTS...)
    throw(ArgumentError("fonttheme: the font themes are :preferred and :failsafe, got :$name"))
end

function fonttheme(; base=:failsafe, paths=String[], roles...)
    for k in keys(roles)
        k in FONT_ROLES || throw(ArgumentError("fonttheme: unknown role `$k`; the roles " *
                                               "are $(join(FONT_ROLES, ", ")) (and the keywords `base`, `paths`)"))
    end
    b = to_fonttheme(base)
    # Roles derived from a given family: the chrome from the title, text styles from the text
    # (from a `(family, style)` tuple only the family: its style is that of the given role).
    derived = (chrome=:title, bold=:text, italic=:text, bold_italic=:text, math_text=:text)
    family_of(s) = s isa Tuple ? first(s) : s
    spec(role) = haskey(roles, role) ? roles[role] :
                 haskey(derived, role) && haskey(roles, derived[role]) ? family_of(roles[derived[role]]) :
                 getfield(b, role)
    ps = String[String(p) for p in paths]
    missing_ = Dict{String,Vector{Symbol}}()
    fonts = map(FONT_ROLES) do role
        s = spec(role)
        f = resolve_role(role, s, ps)
        if f === :missing
            push!(get!(missing_, spec_name(s), Symbol[]), role)
            role === :math_text ? nothing : failsafe_role(role)
        else
            f
        end
    end
    warn_missing_fonts(missing_)
    return FontTheme(fonts...)
end

to_fonttheme(f::FontTheme) = f
to_fonttheme(s::Symbol) = fonttheme(s)
function to_fonttheme(x)
    throw(ArgumentError("expected a FontTheme or the name of one (:failsafe, :preferred), got $(repr(x))"))
end

spec_name(s::AbstractString) = String(s)
spec_name(s::Tuple) = join(s, " ")
spec_name(s) = string(s)

# A role's font, `nothing` (math_text only) or `:missing`.
function resolve_role(role::Symbol, s, paths)
    s === nothing && role === :math_text && return nothing
    s === :failsafe && return failsafe_role(role)
    f = if s isa Font
        s
    elseif s isa Tuple{AbstractString,AbstractString}
        findfont(s[1], s[2]; paths)
    elseif s isa AbstractString
        file = expanduser(s)
        if is_font_file(file) && isfile(file)
            findfont(file, 0)
        else
            # (no full-name fallback: "DejaVu Sans" for `bold` must not give the regular face)
            findfont(s, ROLE_STYLE[role]; paths)
        end
    else
        throw(ArgumentError("fonttheme: the `$role` font must be a family name, a (family, " *
                            "style) tuple, a font file, a Lantern.Font or :failsafe, got $(repr(s))"))
    end
    f === nothing && return :missing
    if role === :math && !has_math_table(f)
        warn_once("math:" * f.path,
                  "Lantern: $(f.family) $(f.style) has no OpenType MATH " *
                  "table and cannot set equations; using New Computer Modern Math (fail-safe)")
        return failsafe_role(:math)
    end
    return f
end

function warn_once(key::AbstractString, msg::AbstractString)
    first = lock(FONT_LOCK) do
        key in WARNED_FONTS ? false : (push!(WARNED_FONTS, key); true)
    end
    first && @warn msg
    return nothing
end

function warn_missing_fonts(missing_::Dict{String,Vector{Symbol}})
    for (name, roles) in sort!(collect(missing_); by=first)
        fallback = join(unique(map(r -> r === :math_text ? "the math font's own letters in equations" :
                                        failsafe_role(r).family, roles)), ", ")
        warn_once(name,
                  "Lantern: font \"$name\" not found (font roles " *
                  "$(join(roles, ", "))); using $fallback instead. Install it, choose other fonts " *
                  "with `fonttheme(; title = …, text = …, math = …, code = …)`, or use " *
                  "`fonttheme(:failsafe)`.")
    end
    return nothing
end

"""
    theme_font(theme, font) -> Font

The font of a builder's `font` keyword: the font roles `:regular` (= `:text`), `:bold`,
`:italic`, `:bold_italic`, `:mono` (= `:code`), `:title` and `:chrome` of the theme (`nothing`:
the fail-safe font theme); a family or full name or a font file (see
[`Lantern.findfont`](@ref); one not found falls back to the theme's text font with a warning);
or a [`Lantern.Font`](@ref).
"""
function theme_font(th, f::Symbol)
    fs = th === nothing ? failsafe_fonts() : th.fonts
    f === :regular && return fs.text
    f === :mono && return fs.code
    f in (:bold, :italic, :bold_italic, :title, :chrome, :text, :code) && return getfield(fs, f)
    throw(ArgumentError("font: the theme fonts are :regular (or :text), :bold, :italic, :bold_italic, :mono (or " *
                        ":code), :title and :chrome, got :$f (or give a font name, a file or a Lantern.Font)"))
end
theme_font(::Any, f::Font) = f
function theme_font(th, name::AbstractString)
    f = findfont(name)
    f === nothing || return f
    fallback = th === nothing ? failsafe_role(:text) : th.fonts.text
    warn_once("name:" * name, "Lantern: font \"$name\" not found; using $(fallback.family) $(fallback.style)")
    return fallback
end
