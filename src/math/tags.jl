# Tagged subexpressions: authoring syntax, source scanner and rewriter (internal).
#
# Authors mark subexpressions with a Typst function that Lantern defines in the generated
# preamble:
#
#     f(x) = #tag("sum", $sum_(n=1)^N a_n$) + x        code call with a math body
#     f(x) = #tag(<sum>)[$sum_(n=1)^N a_n$] + x        label name, trailing content block
#     f(x) = tag("sum", sum_(n=1)^N a_n) + x           math call (no commas in the body)
#
# Tags nest. Typst cannot report which tag encloses which (the colour channel only carries the
# innermost one), so Lantern scans the source itself: it finds every tag call,
# records its name and enclosing call, and inserts a first argument `lantern-id: "#rrggbb"`
# (the occurrence's 24-bit colour) or `lantern-id: "off"` (for the compile with user colours).
# The scanner understands as much Typst syntax as needed to skip strings, comments, raw text,
# escapes and nested math/markup/code correctly; it does not need balanced brackets in math.

"""
    MathTag(name, parent)

One tag occurrence in an expression: its `name` and the index of the enclosing occurrence in
`MathLayout.tags` (`0` at top level). Occurrences are numbered in source order (pre-order).
"""
struct MathTag
    name::Symbol
    parent::Int
end

"""
    TagSyntaxError

A malformed `tag(…)` call (or unbalanced code around one) found by Lantern's source scanner;
shows the source with a caret.
"""
struct TagSyntaxError <: Exception
    msg::String
    source::String
    pos::Int  # character index
end

function Base.showerror(io::IO, e::TagSyntaxError)
    print(io, "TagSyntaxError: ", e.msg)
    cs = collect(e.source)
    p = clamp(e.pos, 1, max(1, length(cs)))
    ls = something(findprev(==('\n'), cs, p - 1), 0) + 1
    le = something(findnext(==('\n'), cs, p), length(cs) + 1) - 1
    line = count(==('\n'), cs[1:(min(p, length(cs))-1)]) + 1
    print(io, "\n  at line ", line, ", column ", p - ls + 1, ":\n    ", String(cs[ls:le]), "\n    ", " "^(p - ls), "^")
end

struct TagScan
    tagged::String
    untagged::String
    tags::Vector{MathTag}
end

const MAX_TAGS = 0xfedcb9  # 0xfedcba is the baseline marker colour

mutable struct Scanner
    cs::Vector{Char}
    src::String
    inserts::Vector{Tuple{Int,Int,Symbol}}  # (insert before char index, occurrence, :code|:math)
    tags::Vector{MathTag}
    stack::Vector{Int}
end

scan_error(sc::Scanner, msg, pos) = throw(TagSyntaxError(msg, sc.src, pos))

at(sc::Scanner, i) = i <= length(sc.cs) ? sc.cs[i] : '\0'

is_code_id_start(c::Char) = isletter(c) || c == '_'
is_code_id_continue(c::Char) = isletter(c) || isdigit(c) || c == '_' || c == '-'

function read_ident(sc::Scanner, i, cont)
    j = i
    while j <= length(sc.cs) && cont(sc.cs[j])
        j += 1
    end
    return String(sc.cs[i:(j-1)]), j
end

# A string literal starting at `i` (the opening quote): returns (content, index after it).
function read_string(sc::Scanner, i)
    j = i + 1
    buf = IOBuffer()
    while j <= length(sc.cs)
        c = sc.cs[j]
        if c == '\\' && j < length(sc.cs)
            print(buf, sc.cs[j+1])
            j += 2
        elseif c == '"'
            return String(take!(buf)), j + 1
        else
            print(buf, c)
            j += 1
        end
    end
    scan_error(sc, "unterminated string", i)
end

skip_string(sc::Scanner, i) = read_string(sc, i)[2]

# Comments: `//` to end of line, `/* … */` (nesting). Returns `nothing` if there is none at `i`.
function skip_comment(sc::Scanner, i)
    at(sc, i) == '/' || return nothing
    c = at(sc, i + 1)
    if c == '/'
        j = something(findnext(==('\n'), sc.cs, i), length(sc.cs) + 1)
        return j
    elseif c == '*'
        depth = 1
        j = i + 2
        while j <= length(sc.cs)
            if sc.cs[j] == '/' && at(sc, j + 1) == '*'
                depth += 1
                j += 2
            elseif sc.cs[j] == '*' && at(sc, j + 1) == '/'
                depth -= 1
                j += 2
                depth == 0 && return j
            else
                j += 1
            end
        end
        scan_error(sc, "unterminated block comment", i)
    end
    return nothing
end

# Math mode, until the end of input (`:eof`), a closing `$` (`:dollar`) or the `)` that closes
# a math call (`:paren`). Returns the index after the terminator.
function scan_math(sc::Scanner, i, term::Symbol)
    depth = 0
    cs = sc.cs
    n = length(cs)
    start = i
    while i <= n
        c = cs[i]
        if c == '\\'
            i += 2
        elseif c == '"'
            i = skip_string(sc, i)
        elseif c == '/' && (j = skip_comment(sc, i)) !== nothing
            i = j
        elseif c == '$'
            term == :dollar && return i + 1
            term == :paren && scan_error(sc, "unexpected `\$` inside the arguments of a math call", i)
            i += 1
        elseif c == '#'
            i = scan_hash(sc, i + 1)
        elseif term == :paren && c == '('
            depth += 1
            i += 1
        elseif term == :paren && c == ')'
            depth == 0 && return i + 1
            depth -= 1
            i += 1
        elseif isletter(c) && (i == 1 || !(isletter(cs[i-1]) || isdigit(cs[i-1]) || cs[i-1] == '.'))
            word, j = read_ident(sc, i, c -> isletter(c) || isdigit(c))
            if word == "tag" && at(sc, j) == '('
                i = scan_tag(sc, j + 1, :math)
            else
                i = j
            end
        else
            i += 1
        end
    end
    term == :eof ||
        scan_error(sc, term == :dollar ? "unterminated `\$…\$`" : "unterminated math call `tag(…`", start - 1)
    return i
end

const CODE_KEYWORDS = Set(["let", "set", "show", "import", "include", "if", "for", "while", "return", "context",
                           "break", "continue"])

# Embedded code after `#`. Returns the index after the expression.
function scan_hash(sc::Scanner, i)
    c = at(sc, i)
    if is_code_id_start(c)
        word, j = read_ident(sc, i, is_code_id_continue)
        word == "tag" && at(sc, j) == '(' && return scan_tag(sc, j + 1, :code)
        word in CODE_KEYWORDS && return scan_code(sc, j, '\0'; statement=true)
        return scan_postfix(sc, j)
    elseif c == '('
        return scan_postfix(sc, scan_code(sc, i + 1, ')'))
    elseif c == '{'
        return scan_code(sc, i + 1, '}')
    elseif c == '['
        return scan_markup(sc, i + 1)
    elseif c == '"'
        return skip_string(sc, i)
    end
    return i
end

# Calls, trailing content blocks and field accesses after an embedded identifier.
scan_postfix(sc::Scanner, j) =
    while true
        c = at(sc, j)
        if c == '('
            j = scan_code(sc, j + 1, ')')
        elseif c == '['
            j = scan_markup(sc, j + 1)
        elseif c == '.' && is_code_id_start(at(sc, j + 1))
            _, j = read_ident(sc, j + 1, is_code_id_continue)
        else
            return j
        end
    end

# Code mode until `closer` (balanced). With `statement = true` (after a keyword), stop before a
# newline, `;`, `$` or an unbalanced closing bracket instead.
function scan_code(sc::Scanner, i, closer::Char; statement::Bool=false)
    cs = sc.cs
    n = length(cs)
    start = i
    while i <= n
        c = cs[i]
        if statement && c in ('\n', ';', '$', ']', ')', '}')
            return i
        elseif c == closer
            return i + 1
        elseif c in (')', ']', '}')
            scan_error(sc, "unbalanced `$c`", i)
        elseif c == '"'
            i = skip_string(sc, i)
        elseif c == '/' && (j = skip_comment(sc, i)) !== nothing
            i = j
        elseif c == '$'
            i = scan_math(sc, i + 1, :dollar)
        elseif c == '['
            i = scan_markup(sc, i + 1)
        elseif c == '('
            i = scan_code(sc, i + 1, ')')
        elseif c == '{'
            i = scan_code(sc, i + 1, '}')
        elseif is_code_id_start(c) && (i == 1 || !(is_code_id_continue(cs[i-1]) || cs[i-1] == '.'))
            word, j = read_ident(sc, i, is_code_id_continue)
            i = word == "tag" && at(sc, j) == '(' ? scan_tag(sc, j + 1, :code) : j
        else
            i += 1
        end
    end
    statement && return i
    scan_error(sc, "unterminated code, expected `$closer`", start - 1)
end

# `//` after `http:` or `https:` (Typst's markup recognises such links).
function is_url(sc::Scanner, i)
    at(sc, i + 1) == '/' || return false
    pre(w) = i > length(w) && String(sc.cs[(i-length(w)):(i-1)]) == w
    return pre("http:") || pre("https:")
end

# Markup until the `]` closing a content block, or (`eof = true`, the top level of a text
# source) until the end of input.
function scan_markup(sc::Scanner, i; eof::Bool=false)
    cs = sc.cs
    n = length(cs)
    depth = 0
    start = i
    while i <= n
        c = cs[i]
        if c == '\\'
            i += 2
        elseif c == '/' && is_url(sc, i)
            i += 2  # `https://…` is a link in markup, not a comment
        elseif c == '/' && (j = skip_comment(sc, i)) !== nothing
            i = j
        elseif c == '`'
            k = 0
            while at(sc, i + k) == '`'
                k += 1
            end
            if k == 2
                i += 2  # empty raw text
            else
                j = i + k
                while j <= n
                    if cs[j] == '`'
                        m = 0
                        while at(sc, j + m) == '`'
                            m += 1
                        end
                        m >= k && break
                        j += m
                    else
                        j += 1
                    end
                end
                j > n && scan_error(sc, "unterminated raw text", i)
                i = j + k
            end
        elseif c == '$'
            i = scan_math(sc, i + 1, :dollar)
        elseif c == '#'
            i = scan_hash(sc, i + 1)
        elseif c == '['
            depth += 1
            i += 1
        elseif c == ']'
            depth == 0 && !eof && return i + 1
            depth -= 1
            i += 1
        else
            i += 1
        end
    end
    eof && return i
    scan_error(sc, "unterminated content block `[…`", start - 1)
end

# A tag call; `i` is the index after its `(`.
function scan_tag(sc::Scanner, i, mode::Symbol)
    k = length(sc.tags) + 1
    k <= MAX_TAGS || scan_error(sc, "too many tags", i)
    parent = isempty(sc.stack) ? 0 : sc.stack[end]
    push!(sc.inserts, (i, k, mode))
    j = i
    while j <= length(sc.cs) && isspace(sc.cs[j])
        j += 1
    end
    c = at(sc, j)
    name = if c == '"'
        s, j = read_string(sc, j)
        s
    elseif c == '#' && at(sc, j + 1) == '"' && mode == :math
        s, j = read_string(sc, j + 1)
        s
    elseif c == '<' && mode == :code
        e = findnext(==('>'), sc.cs, j)
        e === nothing && scan_error(sc, "unterminated label", j)
        s = String(sc.cs[(j+1):(e-1)])
        j = e + 1
        s
    else
        scan_error(sc,
                   "the first argument of `tag` must be its name as a string literal, " *
                   "e.g. `#tag(\"sum\", \$…\$)`, `#tag(<sum>)[…]` or `tag(\"sum\", …)`", j)
    end
    isempty(strip(name)) && scan_error(sc, "empty tag name", j)
    push!(sc.tags, MathTag(Symbol(name), parent))
    push!(sc.stack, k)
    if mode == :code
        j = scan_code(sc, j, ')')
        while at(sc, j) == '['
            j = scan_markup(sc, j + 1)
        end
    else
        j = scan_math(sc, j, :paren)
    end
    pop!(sc.stack)
    return j
end

tag_color(k::Integer) = "#" * string(k; base=16, pad=6)

"""
    scan_tags(src; mode = :math) -> TagScan

Find the tag calls of a math source (`mode = :markup`: a text source, see
`src/math/text.jl`) and return the two rewritten sources (tagged, untagged) and the tag
occurrences. Throws [`TagSyntaxError`](@ref). Internal.
"""
function scan_tags(src::AbstractString; mode::Symbol=:math)
    src = String(src)
    sc = Scanner(collect(src), src, Tuple{Int,Int,Symbol}[], MathTag[], Int[])
    mode === :markup ? scan_markup(sc, 1; eof=true) : scan_math(sc, 1, :eof)
    tagged = IOBuffer()
    untagged = IOBuffer()
    prev = 1
    for (pos, k, mode) in sort(sc.inserts)
        chunk = String(sc.cs[prev:(pos-1)])
        q = mode == :math ? "#" : ""
        print(tagged, chunk, "lantern-id: ", q, '"', tag_color(k), "\", ")
        print(untagged, chunk, "lantern-id: ", q, "\"off\", ")
        prev = pos
    end
    rest = String(sc.cs[prev:end])
    print(tagged, rest)
    print(untagged, rest)
    return TagScan(String(take!(tagged)), String(take!(untagged)), sc.tags)
end
