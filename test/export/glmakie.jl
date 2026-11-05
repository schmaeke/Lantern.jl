# Video export with GLMakie (an invisible window). Included by `runtests.jl` with
# LANTERN_TEST_GPU=1, after `using GLMakie`.

@testset "video (GLMakie)" begin
    d = export_deck()
    @test resolve_backend(:auto) == GLMakieBackend()
    fps, sz = 10, (192, 108)
    path = joinpath(EXPORT_OUT, "export_test_gl.mp4")
    segs = video_schedule(d; hold=0.3)
    t = @elapsed export_video(d, path; fps, size=sz, hold=0.3)
    @info "export_video (GLMakie): $(round(t; digits = 2)) s"
    info = video_info(path)
    @test info.frames == video_nframes(segs, fps) && (info.width, info.height) == sz
    for j in (7, 12)
        i, ph = video_frame(segs, j / fps)
        frame = load_image(video_frame_png(path, j, joinpath(EXPORT_OUT, "frame_gl.png")))
        ref = capture(CairoMakieBackend(), materialize(d, i; size=sz, playhead=ph))
        @test export_diff(frame, ref) < 0.03
    end
end
