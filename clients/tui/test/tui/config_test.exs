defmodule Tui.ConfigTest do
  use ExUnit.Case, async: true

  import Tui.TestSupport

  alias Tui.App
  alias Tui.Config
  alias Tui.Model

  @languages [
    %{"code" => "en", "name" => "English (EN)"},
    %{"code" => "es", "name" => "Español (ES)"},
    %{"code" => "fr", "name" => "Français (FR)"}
  ]

  @moduletag :tmp_dir

  test "saved settings come back; no file is no settings", %{tmp_dir: dir} do
    path = Path.join([dir, "nested", "config.json"])
    assert Config.load(path) == %{}
    assert Config.load(nil) == %{}

    settings = %{"speaks" => "es", "hears" => ["en", "es"], "adult_acknowledged" => true}
    assert Config.save(path, settings) == :ok
    assert Config.load(path) == settings
    assert Config.save(nil, settings) == :ok
  end

  @tag :capture_log
  test "an unreadable file is ignored, not fatal", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    File.write!(path, "{not json")
    assert Config.load(path) == %{}
    File.write!(path, "[1, 2]")
    assert Config.load(path) == %{}
  end

  test "the configured path: the user's config directory, a plain path, or none" do
    assert Config.path({:user_config, "randos/config.json"}) =~ ~r"randos/config\.json$"
    assert Config.path("tmp/x.json") == "tmp/x.json"
    assert Config.path(nil) == nil
  end

  test "the app starts from the saved settings and saves what changes", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    Config.save(path, %{
      "speaks" => "fr",
      "hears" => ["es", "fr"],
      "adult_acknowledged" => true,
      "input" => "Some Mic",
      "output" => nil
    })

    app =
      start_supervised!(
        {App, name: nil, test_mode: {100, 24}, connection: self(), test_pid: self(), config: path}
      )

    send(app, {:randos, {:joined, %{"state" => idle(), "languages" => @languages}}})

    assert_receive {:tui_model, ^app,
                    %Model{
                      status: :idle,
                      speaks: "fr",
                      hears: ["es", "fr"],
                      adult_acknowledged?: true
                    }}

    # Speak English instead (French → Spanish → English): saved straight
    # away, and the saved hearing languages stay (they were chosen, not automatic).
    keys(app, ["left", "left"])
    assert_receive {:tui_model, ^app, %Model{speaks: "en"}}

    assert %{"speaks" => "en", "hears" => ["en", "es", "fr"], "input" => "Some Mic"} =
             Config.load(path)
  end

  defp idle, do: %{"status" => "idle", "webrtc_role" => nil, "error" => nil, "call" => nil}
end
