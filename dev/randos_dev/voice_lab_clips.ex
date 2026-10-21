defmodule RandosDev.VoiceLabClips do
  @moduledoc """
  Serves the voice lab's bundled clips (`dev/voice_lab/clips/*.wav`, see the
  ATTRIBUTION.md there) in development only, so they never ship with a
  release. `GET /dev/voice-lab/clips` lists them; `.../clips/:name` is one.
  """
  use RandosWeb, :controller

  @dir Path.expand("../voice_lab/clips", __DIR__)

  def index(conn, _params) do
    json(conn, %{clips: clips()})
  end

  # Only names from the listing: never a path built from the request.
  def show(conn, %{"name" => name}) do
    if name in clips() do
      conn
      |> put_resp_content_type("audio/wav")
      |> send_file(200, Path.join(@dir, name))
    else
      send_resp(conn, 404, "")
    end
  end

  defp clips do
    @dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".wav")) |> Enum.sort()
  end
end
