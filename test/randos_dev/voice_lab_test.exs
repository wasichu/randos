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
    assert has_element?(view, "#voice-lab-render")
    assert has_element?(view, "#voice-lab-results")
    assert has_element?(view, "#voice-lab-measure")
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

    served = VoiceLabClips.show(build_conn(), %{"name" => "low_voice.wav"})
    assert served.status == 200
    assert ["audio/wav" <> _] = get_resp_header(served, "content-type")

    for name <- ["ATTRIBUTION.md", "../voice_lab_live.ex", "/etc/passwd"] do
      assert VoiceLabClips.show(build_conn(), %{"name" => name}).status == 404
    end
  end
end
