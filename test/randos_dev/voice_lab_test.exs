defmodule RandosDev.VoiceLabTest do
  # The lab's routes exist only with dev_routes (not in tests), so these
  # drive the LiveView and the controller directly. The page's behaviour is
  # checked in a browser by test/e2e/voice_lab_smoke.mjs.
  use RandosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RandosDev.VoiceLabClips

  test "renders the lab's shell for its script", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, RandosDev.VoiceLabLive)

    assert has_element?(view, "#voice-lab[phx-update='ignore'][data-clips-path]")
    assert has_element?(view, "#voice-lab-source")
    assert has_element?(view, "#voice-lab-render")
    assert has_element?(view, "#voice-lab-results")
    assert has_element?(view, "#voice-lab-measure")
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
