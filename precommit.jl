#!/usr/bin/env julia

# Format every Julia file of the repository (or, with `--check`, verify that it is formatted) and
# check that no line of a text file (Julia, Markdown, TOML, YAML) is longer than the formatter's
# margin, which the formatter does not enforce on comments, docstrings and strings. Files are
# those git knows or would add (tracked and untracked, without ignored ones).
#
#     julia --project=format precommit.jl                  # format in place, check line lengths
#     julia --project=format precommit.jl --check          # verify only (non-zero exit on failure)
#     julia --project=format precommit.jl [--check] PATH…  # only these files or directories
#
# JuliaFormatter lives in the `format/` environment (`julia --project=format -e 'using Pkg;
# Pkg.instantiate()'` once). Formatting follows `.JuliaFormatter.toml`.

using JuliaFormatter
using TOML

const ROOT = @__DIR__
const MARGIN = TOML.parsefile(joinpath(ROOT, ".JuliaFormatter.toml"))["margin"]
const TEXT_EXTENSIONS = (".jl", ".md", ".toml", ".yml", ".yaml")
is_text(f) = any(e -> endswith(f, e), TEXT_EXTENSIONS) && !startswith(basename(f), "Manifest")

function repository_files(only)
    names = readlines(Cmd(`git ls-files --cached --others --exclude-standard`; dir=ROOT))
    files = filter(isfile, [joinpath(ROOT, n) for n in names])
    isempty(only) && return files
    return filter(f -> any(p -> f == p || startswith(f, rstrip(p, '/') * "/"), only), files)
end

# Whether `path` is formatted. The copy is formatted inside the repository, so that JuliaFormatter
# finds `.JuliaFormatter.toml`, and keeps the `.jl` extension, without which it does nothing.
function formatted(path)
    dir = mktempdir(ROOT)
    try
        copy = joinpath(dir, basename(path))
        cp(path, copy)
        format(copy; overwrite=true, verbose=false)
        return read(copy, String) == read(path, String)
    finally
        rm(dir; recursive=true, force=true)
    end
end

long_lines(files) = [(f, n, length(l)) for f in files for (n, l) in enumerate(eachline(f)) if length(l) > MARGIN]

function main(args)
    check = "--check" in args
    only = [abspath(a) for a in args if a != "--check"]
    files = repository_files(only)
    julia = filter(endswith(".jl"), files)
    bad = String[]
    for f in julia
        if check
            formatted(f) || push!(bad, f)
        else
            format(f; overwrite=true, verbose=false)
        end
    end
    long = long_lines(filter(is_text, files))
    if !isempty(bad)
        println(stderr, "Not formatted (run `julia --project=format precommit.jl`):")
        foreach(f -> println(stderr, "  ", relpath(f, ROOT)), bad)
    end
    if !isempty(long)
        println(stderr, "Lines longer than $MARGIN characters (the formatter does not wrap comments and strings):")
        foreach(((f, n, w),) -> println(stderr, "  ", relpath(f, ROOT), ":", n, " (", w, ")"), long)
    end
    isempty(bad) && isempty(long) || return 1
    println(check ? "Formatting and line lengths are fine ($(length(julia)) Julia files)." :
            "Formatted $(length(julia)) Julia files; line lengths are fine.")
    return 0
end

exit(main(ARGS))
