# The default math backend and automatic batching of `typst"…"` literals.
#
# Scene code needs a layout as soon as it places an equation (its glyph slots and the clips of
# transforms depend on the geometry). Laying out each expression on its own costs one Typst
# run each; a batch of many costs little more than one. To batch without making authors list their
# expressions, the `typst"…"` string macro registers its source when it is *expanded*. Julia
# expands a whole top-level expression (e.g. a `slide!(deck) do … end` block, or a function
# that builds the deck) before running it, so all literals in it are registered before the
# first one is laid out. The first layout request through the default backend then lays out
# every registered source in one Typst run. This is an optimisation only: results are the
# same with or without it.

const DEFAULT_BACKEND = Ref{Union{Nothing,AbstractMathBackend}}(nothing)
const PENDING = MathSource[]
const PENDING_LOCK = ReentrantLock()

function __init__()
    # Nothing created during precompilation survives into a session.
    DEFAULT_BACKEND[] = nothing
    empty!(PENDING)
    return nothing
end

"""
    default_backend() -> AbstractMathBackend

The math backend used by scene objects when none is given: a [`TypstBackend`](@ref) with
default options, created on first use. Replace it with [`set_default_backend!`](@ref).
"""
default_backend() = lock(PENDING_LOCK) do
    b = DEFAULT_BACKEND[]
    b === nothing || return b
    b = TypstBackend()
    DEFAULT_BACKEND[] = b
    return b
end

"""
    set_default_backend!(b::AbstractMathBackend) -> b

Use `b` (e.g. `TypstBackend(preamble = "#show math.equation: set text(font: …)")`) for all
equations created afterwards without an explicit `backend`.
"""
set_default_backend!(b::AbstractMathBackend) = lock(() -> (DEFAULT_BACKEND[] = b), PENDING_LOCK)

# Called by the `typst"…"` macro at expansion time.
function register_source!(s::MathSource)
    lock(PENDING_LOCK) do
        length(PENDING) < 10_000 && push!(PENDING, s)
    end
    return s
end

"""
    layout_source(b::AbstractMathBackend, src; fonts = MathFonts()) -> MathLayout

The layout of one expression in the [`MathFonts`](@ref) `fonts`. Through the
[`default_backend`](@ref), the expressions registered by `typst"…"` literals since the last
call are laid out in the same Typst run, in the same fonts (see the top of
`src/math/default.jl`). If that batch fails, `src` is laid out on its own, so an error always
names the expression that was asked for.
"""
function layout_source(b::AbstractMathBackend, src; fonts::MathFonts=MathFonts())
    s = MathSource(src)
    b === DEFAULT_BACKEND[] || return layout_math(b, s; fonts)
    batch = lock(PENDING_LOCK) do
        out = unique!([PENDING; s])
        empty!(PENDING)
        out
    end
    length(batch) == 1 && return layout_math(b, s; fonts)
    layouts = try
        layout_math(b, batch; fonts)
    catch e
        # Any failure (Typst, a malformed tag call, …) may come from another source.
        e isa InterruptException && rethrow()
        return layout_math(b, s; fonts)
    end
    return layouts[findfirst(==(s), batch)]
end

"""
    prefetch_math(sources; backend = default_backend(), fonts = <default theme>) -> Nothing

Lay out `sources` (strings or `MathSource`s) in one Typst run and cache the results, so that
the equations placed later with them are free. Useful for expressions built at run time
(`MathSource("x^\$i")`), which the `typst"…"` macro cannot register. Layouts are cached per
fonts: pass the theme of the slides that show the equations (`fonts = deck.theme`; the default
is the default theme) or a [`MathFonts`](@ref).
"""
function prefetch_math(sources; backend::AbstractMathBackend=default_backend(), fonts=DEFAULT_MATH_FONTS[]())
    layout_math(backend, MathSource[MathSource(s) for s in sources]; fonts=math_fonts(fonts))
    return nothing
end
