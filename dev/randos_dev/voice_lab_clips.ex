defmodule RandosDev.VoiceLabClips do
  @moduledoc """
  Serves the voice lab's bundled clips (`dev/voice_lab/clips/*.wav`, see the
  ATTRIBUTION.md there) in development only, so they never ship with a
  release. `GET /dev/voice-lab/clips` lists them; `.../clips/:name` is one.
  """
  use RandosWeb, :controller

  @dir Path.expand("../voice_lab/clips", __DIR__)
  @recovery_dir Path.expand("../../tmp/voice-recovery", __DIR__)
  @model_dir Path.expand("../../tmp/voice-model", __DIR__)
  @browser_dir Path.expand("../../tmp/voice-browser", __DIR__)

  def index(conn, _params) do
    json(conn, %{clips: clips()})
  end

  # Only names from the listing: never a path built from the request.
  def show(conn, %{"name" => name}) do
    serve(conn, name, @dir)
  end

  def recovery(conn, %{"name" => name}) do
    serve(conn, name, @recovery_dir)
  end

  def models(conn, %{"name" => name}) do
    serve(conn, name, @model_dir)
  end

  def browser_probe(conn, params) do
    name = Map.get(params, "name", "report.html")

    types = %{
      "report.html" => "text/html",
      "dsp.html" => "text/html",
      "review.js" => "text/javascript",
      "report.css" => "text/css"
    }

    with {:ok, type} <- Map.fetch(types, name),
         path = Path.join(@browser_dir, name),
         true <- File.regular?(path) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type(type)
      |> send_file(200, path)
    else
      _missing ->
        send_resp(conn, 404, "Browser report unavailable. Run just voice-browser first.")
    end
  end

  defp serve(conn, name, dir) do
    if name in clips(dir) do
      conn
      |> put_resp_content_type("audio/wav")
      |> send_file(200, Path.join(dir, name))
    else
      send_resp(conn, 404, "")
    end
  end

  defp clips(dir \\ @dir) do
    case File.ls(dir) do
      {:ok, files} -> files |> Enum.filter(&String.ends_with?(&1, ".wav")) |> Enum.sort()
      {:error, _missing} -> []
    end
  end
end
