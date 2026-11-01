defmodule RandosDev.VoiceLabTest do
  # The lab's routes exist only with dev_routes (not in tests), so these
  # drive the LiveView and the controller directly. The page's behaviour is
  # checked in a browser by test/e2e/voice_lab_smoke.mjs.
  use RandosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RandosDev.VoiceLabBenchmark
  alias RandosDev.VoiceLabClips

  test "renders the lab's shell for its script", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, RandosDev.VoiceLabLive)

    assert has_element?(view, "#voice-lab[phx-update='ignore'][data-clips-path]")
    assert has_element?(view, "#voice-lab-source")
    refute has_element?(view, "#voice-lab-render")
    assert has_element?(view, "#voice-lab-processor option[value=pitch_shift]")
    assert has_element?(view, "#voice-lab-processor option[value=mcadams]")

    for processor <- ~w(quality_pitch quality_resonance quality_both quality_tvtsyn) do
      assert has_element?(view, "#voice-lab-processor optgroup option[value=#{processor}]")
    end

    for processor <- ~w(world_control world_pitch world_formants world_texture) do
      assert has_element?(view, "#voice-lab-processor optgroup option[value=#{processor}]")
    end

    for size <- [40, 80, 160] do
      assert has_element?(view, "#voice-lab-processor option[value=world_chunk_#{size}]")
    end

    refute has_element?(view, "#voice-lab-processor option[value=passthrough]")
    assert has_element?(view, "#voice-lab-results")
    assert has_element?(view, "#voice-lab-measure")
    assert has_element?(view, "#voice-lab-loop[aria-pressed=false]")
    assert has_element?(view, "#voice-lab-play-original")
    assert has_element?(view, "#voice-lab-play")
    assert has_element?(view, "#voice-lab-play-comparison")
    assert has_element?(view, "#voice-lab-review-listen")
    assert has_element?(view, "#voice-lab-review-recovery")
    assert has_element?(view, "#voice-lab-recovery-play-all")

    for tab <-
          ~w(listen round engines gentle envelope fargan fargan_mask fargan_combined bandwidth source_shape voice recovery models basics delay benchmark) do
      assert has_element?(view, "#voice-lab-view option[value=#{tab}]")
      assert has_element?(view, "#voice-lab-panel-#{tab}[role=region]")
    end

    assert has_element?(view, "#voice-lab-panel-voice[hidden] #voice-lab-live-stop")
    assert has_element?(view, "#voice-lab-sources")
    assert has_element?(view, "#voice-lab-live-mode")
    assert has_element?(view, "#voice-lab-live-engine")
    assert has_element?(view, "#voice-lab-live-profile")
    assert has_element?(view, "#voice-lab-live-pitch-strength")
    assert has_element?(view, "#voice-lab-live-buffering option[value=baseline]")
    assert has_element?(view, "#voice-lab-live-dsp-metrics")
    assert has_element?(view, "#voice-lab-panel-basics[hidden]")
    assert has_element?(view, "#voice-lab-panel-benchmark[hidden] #voice-lab-benchmark")
  end

  test "shows the benchmark's results, or says it hasn't run", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, RandosDev.VoiceLabLive)
    assert has_element?(view, "#voice-lab-benchmark")

    report = %{
      "generated_at" => "2026-10-21T12:00:00+00:00",
      "models" => %{"speaker" => "ecapa", "asr" => "whisper"},
      "dataset" => %{"speakers" => 20},
      "baseline" => %{"eer" => 0.02, "wer" => 0.05},
      "results" => [
        %{
          "id" => "pitch_shift_plus_4",
          "label" => "Pitch shift +4",
          "eer_ignorant" => 0.4,
          "eer_informed" => 0.06,
          "wer" => 0.07,
          "verdict" => %{"kind" => "fools_ignorant_only", "text" => "Fools only the ignorant."}
        }
      ]
    }

    path =
      Path.join(
        System.tmp_dir!(),
        "voice-lab-benchmark-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, JSON.encode!(report))
    on_exit(fn -> File.rm(path) end)

    assert VoiceLabBenchmark.load(path) == report
    assert VoiceLabBenchmark.load(path <> ".missing") == nil

    ready =
      render_component(&VoiceLabBenchmark.section/1, report: report) |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(ready, "#voice-lab-benchmark[data-state='ready']")) == 1

    assert Enum.count(
             LazyHTML.query(
               ready,
               "#voice-lab-benchmark-pitch_shift_plus_4[data-verdict='fools_ignorant_only']"
             )
           ) == 1

    none = render_component(&VoiceLabBenchmark.section/1, report: nil) |> LazyHTML.from_fragment()
    assert Enum.count(LazyHTML.query(none, "#voice-lab-benchmark[data-state='none']")) == 1
  end

  test "lists the bundled clips and serves only those", %{conn: conn} do
    %{"clips" => clips} = conn |> VoiceLabClips.index(%{}) |> json_response(200)
    assert "low_voice.wav" in clips and "high_voice.wav" in clips
    assert "mencken_wasichu.wav" in clips

    served = VoiceLabClips.show(build_conn(), %{"name" => "low_voice.wav"})
    assert served.status == 200
    assert ["audio/wav" <> _] = get_resp_header(served, "content-type")

    for name <- ["ATTRIBUTION.md", "../voice_lab_live.ex", "/etc/passwd"] do
      assert VoiceLabClips.show(build_conn(), %{"name" => name}).status == 404
    end
  end

  test "recovery audio is restricted to generated WAV basenames" do
    dir = Path.expand("../../tmp/voice-recovery", __DIR__)
    File.mkdir_p!(dir)
    name = "test_#{System.unique_integer([:positive])}.wav"
    path = Path.join(dir, name)
    File.write!(path, "test wave")
    on_exit(fn -> File.rm(path) end)
    assert VoiceLabClips.recovery(build_conn(), %{"name" => name}).status == 200

    for invalid <- ["../serve.log", "/etc/passwd", "missing.wav"] do
      assert VoiceLabClips.recovery(build_conn(), %{"name" => invalid}).status == 404
    end
  end

  test "model audio is restricted to generated WAV basenames" do
    for name <- ["../serve.log", "/etc/passwd", "missing.wav", "config.json"] do
      assert VoiceLabClips.models(build_conn(), %{"name" => name}).status == 404
    end
  end

  test "browser report never serves model weights, raw data or arbitrary files" do
    for name <- ["../serve.log", "/etc/passwd", "model.onnx", "input.f32", "preparation.json"] do
      assert VoiceLabClips.browser_probe(build_conn(), %{"name" => name}).status == 404
    end
  end
end
