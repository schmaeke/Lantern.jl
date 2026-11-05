# The authoring DSL: `@beat s begin … end` runs the block in place and plays every
# statement whose value is a clip, one after the other. Inside, clips are plain values combined
# with `seq`, `par`, `stagger`, `delay` and `waitfor`.

"""
    @beat slide [auto = false] [notes = ""] [loop = false] begin … end -> Beat

Append a beat to `slide`. The block runs once, in place (it is not a function: variables
assigned in it remain visible after it). Every *statement* whose value is a [`Clip`](@ref) is
collected, and the collected clips play one after the other:

```julia
@beat s begin
    fadein(title, 0.5)                                    # first …
    par(move(c, 0.8; to = (-3, 0)),                       # … then these together,
        recolor(c, 0.8; color = :red),
        delay(0.3, fadein(label, 0.5)))                   # this one 0.3 s into the move
    stagger(0.1, fadein.(dots, 0.3))                      # … then a staggered reveal
end
```

Rules:
- Statements are the lines of the block, including the bodies of `for`, `while`, `if` and
  `let`/`begin` blocks written directly inside it; a loop body is collected on every
  iteration. Clips built inside function calls, comprehensions or closures are values like
  any other and only count through the statement that contains them.
- Assignments (`x = fadein(c)`), declarations and definitions are never collected, so clips
  can be named and combined later.
- Statements with other values (`nothing`, numbers, …) are ignored. A statement whose value is
  a collection of clips (e.g. `fadein.(dots)`) is an error: say how to combine them with
  `seq`, `par` or `stagger`.
- `return` is not allowed inside the block, and `@beat` blocks cannot be nested.

Every collected tween and assignment that has no source location gets the line of its statement, so
overlap warnings point at it. `auto = true` starts the beat without a click once the previous
one has finished; `notes` are the speaker notes of the beat; `loop = true` (or `:pingpong`)
keeps repeating the beat's animation while the beat is held (see [`beat!`](@ref) and
[`ambient!`](@ref)). [`beat!(slide, clip)`](@ref beat!) is the macro-free form.
"""
macro beat(args...)
    length(args) >= 2 ||
        throw(ArgumentError("@beat: usage is `@beat slide [auto = …] [notes = …] [loop = …] begin … end`"))
    slide, opts, body = args[1], args[2:(end-1)], args[end]
    Meta.isexpr(body, :block) || throw(ArgumentError("@beat: the last argument must be a `begin … end` block"))
    kws = map(opts) do o
        (Meta.isexpr(o, :(=), 2) && o.args[1] in (:auto, :notes, :loop)) ||
            throw(ArgumentError("@beat: unknown option `$o`; the options are `auto = …`, " *
                                "`notes = …` and `loop = …`"))
        Expr(:kw, o.args[1], esc(o.args[2]))
    end
    check_beat_body(body)
    acc = gensym(:beat)
    s = gensym(:slide)
    # `tryfinally` (unlike `try`) opens no scope, so variables assigned in the block stay visible;
    # the slide accepts beats again even if the block throws.
    return Expr(:block, :($s = $(esc(slide))), :($acc = $(open_beat!)($s)),
                Expr(:tryfinally, collect_block(body, acc, __source__), :($s.building = false)),
                :($(close_beat!)($s, $acc; $(kws...))))
end

# Reject `return` and nested `@beat` (outside nested function definitions) at expansion time.
function check_beat_body(ex)
    ex isa Expr || return nothing
    ex.head === :return && throw(ArgumentError("@beat: `return` is not allowed inside the " *
                                               "block (it would leave the slide's code without adding the beat)"))
    ex.head === :macrocall &&
        ex.args[1] === Symbol("@beat") &&
        throw(ArgumentError("@beat: beat blocks cannot be nested"))
    ex.head in (:function, :->) && return nothing
    foreach(check_beat_body, ex.args)
    return nothing
end

const NOT_COLLECTED = (:local, :global, :const, :function, :macro, :struct, :abstract, :primitive, :import, :using,
                       :export, :public, :module)

# Declarations, definitions and assignments: `=` and the updating forms (`+=`, `.=`, …) are the
# expression heads that end in `=` (comparisons such as `==` are calls).
is_assignment(ex) = ex isa Expr && (ex.head in NOT_COLLECTED || endswith(string(ex.head), "="))

# Transform the statements of a block; `lnn` is the location of the current statement.
function collect_block(block::Expr, acc, lnn::LineNumberNode)
    out = Expr(:block)
    for st in block.args
        if st isa LineNumberNode
            lnn = st
            push!(out.args, st)
        else
            push!(out.args, collect_statement(st, acc, lnn))
        end
    end
    return out
end

block(ex) = Meta.isexpr(ex, :block) ? ex : Expr(:block, ex)

function collect_statement(st, acc, lnn::LineNumberNode)
    if !(st isa Expr)
        return :($(collect_clip!)($acc, $(esc(st)), $(QuoteNode(lnn))))
    elseif is_assignment(st)
        return esc(st)
    elseif st.head in (:for, :while)
        return Expr(st.head, esc(st.args[1]), collect_block(block(st.args[2]), acc, lnn))
    elseif st.head === :let
        return Expr(:let, esc(st.args[1]), collect_block(block(st.args[2]), acc, lnn))
    elseif st.head === :block
        return collect_block(st, acc, lnn)
    elseif st.head in (:if, :elseif)
        branches = Any[esc(st.args[1]), collect_block(block(st.args[2]), acc, lnn)]
        if length(st.args) == 3
            e = st.args[3]
            push!(branches,
                  Meta.isexpr(e, :elseif) ? collect_statement(e, acc, lnn) : collect_block(block(e), acc, lnn))
        end
        return Expr(st.head, branches...)
    else
        return :($(collect_clip!)($acc, $(esc(st)), $(QuoteNode(lnn))))
    end
end

# Collected clips of an open `@beat` block.
struct BeatCollector
    clips::Vector{Clip}
end

function open_beat!(s::Slide)
    s.building && throw(ArgumentError("@beat: a beat block of this slide is still open; beat blocks cannot be nested"))
    s.building = true
    return BeatCollector(Clip[])
end

function close_beat!(s::Slide, acc::BeatCollector; auto::Bool=false, notes::AbstractString="", loop=false)
    clip = length(acc.clips) == 1 ? only(acc.clips) : seq(acc.clips)
    return beat!(s, clip; auto, notes, loop)
end

collect_clip!(acc::BeatCollector, c::Clip, lnn::LineNumberNode) = (push!(acc.clips, with_src(c, lnn)); nothing)

function collect_clip!(::BeatCollector, x, lnn::LineNumberNode)
    if (x isa Union{AbstractArray,Tuple} && !isempty(x) && all(c -> c isa Clip, x)) || x isa Base.Generator
        throw(ArgumentError("@beat: the statement at $(lnn.file):$(lnn.line) gives a " *
                            "collection of clips; play them with seq(…) (one after the other), par(…) " *
                            "(together) or stagger(lag, …)"))
    end
    return nothing
end
