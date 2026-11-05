# Lantern's test suite: one testset per topic, one module per file (helpers of different files
# cannot replace each other, and a file runs the same alone as in the suite).
#
#     julia --project=test test/runtests.jl                  # everything
#     julia --project=test test/runtests.jl plots player/reload.jl
#                                                            # the files whose paths start so
#     julia --project=test test/runtests.jl --jobs=3         # in 3 processes (or LANTERN_TEST_JOBS=3)
#
# LANTERN_TEST_GPU=1 adds the GLMakie window tests (GLMakie and an awake display needed;
# LANTERN_TEST_FULLSCREEN=1 also toggles fullscreen); LANTERN_TEST_WGL=0 skips the WGLMakie
# server tests. Images and exports go to a temporary directory, or to LANTERN_TEST_OUTPUT to
# keep them.

using Test

const TEST_OUTPUT = let dir = get(ENV, "LANTERN_TEST_OUTPUT", "")
    isempty(dir) ? mktempdir() : mkpath(abspath(dir))
end

const JOBS = let a = filter(startswith("--jobs="), ARGS)
    parse(Int, isempty(a) ? get(ENV, "LANTERN_TEST_JOBS", "1") : chopprefix(last(a), "--jobs="))
end
filter!(!startswith("--jobs="), ARGS)

const RUN_GPU_TESTS = get(ENV, "LANTERN_TEST_GPU", "0") == "1"
const HAS_GLMAKIE = Base.find_package("GLMakie") !== nothing
const RUN_WGL_TESTS = get(ENV, "LANTERN_TEST_WGL", "1") == "1" && Base.find_package("WGLMakie") !== nothing

# Topics and their files (paths relative to this directory), in the order they run.
#! format: off
const SUITE = [
    "API surface" => ["api/runtests.jl"],
    "Timelines" => ["timeline/runtests.jl"],
    "Paths" => ["geometry/runtests.jl"],
    "Math (Typst)" => ["math/runtests.jl"],
    "DSL and authoring checks" => ["dsl/runtests.jl", "dsl/checks.jl"],
    "Player state" => ["player/runtests.jl"],
    "Player runtime" => ["player/presentation.jl"],
    "Presenter view" => ["player/presenter.jl"],
    "Ambient clips and progress bar" => ["player/ambient.jl"],
    "Reload and watch (authoring loop)" => ["player/reload.jl"],
    "Timeline window" => ["player/timeline.jl"],
    "Binding (CairoMakie)" => ["binding/runtests.jl"],
    "Layouts and themes (CairoMakie)" => ["layout/runtests.jl", "layout/themes.jl"],
    "Shapes and pictures (CairoMakie)" => ["shapes/runtests.jl", "shapes/compound.jl", "shapes/pictures.jl"],
    "Equations (CairoMakie)" => ["mathobjects/runtests.jl", "mathobjects/bbox.jl", "mathobjects/hidden_parts.jl"],
    "Text blocks, lists and labels (CairoMakie)" => ["text/runtests.jl", "text/labels.jl"],
    "Plots (CairoMakie)" => ["plots/runtests.jl", "plots/derived.jl", "plots/rendering.jl", "plots/axis3.jl"],
    "Plot themes (CairoMakie)" => ["plots/plotthemes.jl"],
    "Widgets (CairoMakie)" => ["widgets/runtests.jl", "widgets/authoring.jl"],
    "Export (CairoMakie)" => ["export/runtests.jl", "export/options.jl", "export/display.jl"],
    "Fonts (CairoMakie)" => ["fonts/runtests.jl"],
    "GPU (GLMakie)" => RUN_GPU_TESTS ? ["gpu/runtests.jl"] : String[],
    # Browser presenting: a local server, no browser and no GPU needed.
    "WGLMakie (server)" => RUN_WGL_TESTS ? ["wglmakie/runtests.jl"] : String[],
    # GLMakie's window guards with a mocked monitor check: no window, no display needed. Last,
    # since loading GLMakie makes it the default backend of `present` and of video exports.
    "GLMakie without a display" => HAS_GLMAKIE ? ["gpu/no_display.jl"] : String[],
]
#! format: on

selected(path) = isempty(ARGS) || any(a -> startswith(path, a), ARGS)
const TOPICS = [t => filter(selected, fs) for (t, fs) in SUITE if any(selected, fs)]

# `JOBS` processes, each running every `JOBS`-th topic (in order: the GLMakie guards stay last);
# their outputs are printed when they are done.
function run_in_processes(jobs)
    groups = filter(!isempty, [reduce(vcat, last.(TOPICS[i:jobs:end]); init=String[]) for i in 1:jobs])
    procs = map(groups) do files
        out = tempname()
        io = open(out, "w")
        cmd = addenv(`$(Base.julia_cmd()) --project=$(Base.active_project()) $(@__FILE__) $files`,
                     "LANTERN_TEST_JOBS" => "1")
        return (process=run(pipeline(cmd; stdout=io, stderr=io); wait=false), io, out, files)
    end
    failed = String[]
    for p in procs
        wait(p.process)
        close(p.io)
        println("\n─── ", join(p.files, ", "), " ───\n", read(p.out, String))
        rm(p.out; force=true)
        success(p.process) || append!(failed, p.files)
    end
    isempty(failed) || error("tests failed in a process that ran: ", join(failed, ", "))
    println("All $(length(groups)) test processes passed.")
    return nothing
end

if JOBS > 1
    run_in_processes(JOBS)
    exit()
end

using Lantern

if RUN_GPU_TESTS
    HAS_GLMAKIE || error("LANTERN_TEST_GPU=1 needs GLMakie in the test environment")
    # Fail now rather than crash in GLFW at the first window (it does when it sees no monitor).
    using GLMakie
    Lantern.display_available(GLMakieBackend()) ||
        error("LANTERN_TEST_GPU=1 needs a display, but GLFW sees no monitor (is the display asleep?)")
    using CairoMakie
    CairoMakie.activate!()   # as without the GPU tests; the GLMakie tests name their backend
end

RUN_GPU_TESTS || @info "Skipping the GPU tests (set LANTERN_TEST_GPU=1 to run them)."
RUN_WGL_TESTS || @info "Skipping the WGLMakie tests (WGLMakie not available or LANTERN_TEST_WGL=0)."
HAS_GLMAKIE || @info "Skipping the GLMakie guard tests (GLMakie not available)."

# Include `path` in a new module (`Main.<path as a name>`).
function testfile(path::AbstractString)
    name = Symbol(replace(chopsuffix(path, ".jl"), r"\W" => "_"))
    mod = Core.eval(Main, Expr(:module, true, name, Expr(:block)))
    Base.include(mod, joinpath(@__DIR__, path))
    return nothing
end

@testset "Lantern" begin
    for (topic, files) in TOPICS
        @testset "$topic" begin
            for f in files
                @testset "$f" testfile(f)
            end
        end
    end
end
