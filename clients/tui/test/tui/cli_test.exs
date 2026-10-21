defmodule Tui.CLITest do
  # The settings flags; they use the app's :config_path, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tui.CLI

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    Application.put_env(:tui, :config_path, path)
    on_exit(fn -> Application.put_env(:tui, :config_path, nil) end)
    %{path: path}
  end

  test "--settings shows the path, then what's saved", %{path: path} do
    assert capture_io(fn -> assert CLI.main(["--settings"]) == 0 end) =~ "(none saved yet"

    File.write!(path, ~s({"speaks": "es"}))
    out = capture_io(fn -> assert CLI.main(["--settings"]) == 0 end)
    assert out =~ "Settings: #{path}"
    assert out =~ ~s("speaks": "es")
  end

  test "--reset-settings forgets them", %{path: path} do
    File.write!(path, ~s({"speaks": "es"}))

    assert capture_io(fn -> assert CLI.main(["--reset-settings"]) == 0 end) =~
             "Forgot your settings"

    refute File.exists?(path)
    assert capture_io(fn -> assert CLI.main(["--reset-settings"]) == 0 end) =~ "No saved settings"
  end

  test "--edit-settings opens $EDITOR on the file (creating it) and checks it after", %{
    path: path
  } do
    # An "editor" that changes nothing, then one that breaks the file.
    System.put_env("VISUAL", "true")
    on_exit(fn -> System.delete_env("VISUAL") end)
    assert capture_io(fn -> assert CLI.main(["--edit-settings"]) == 0 end) =~ "Saved: #{path}"
    assert File.read!(path) |> Jason.decode!() == %{}

    breaker = Path.join(Path.dirname(path), "breaker.sh")
    File.write!(breaker, "#!/bin/sh\necho 'not json' > \"$1\"\n")
    File.chmod!(breaker, 0o755)
    System.put_env("VISUAL", breaker)

    assert capture_io(:stderr, fn -> assert CLI.main(["--edit-settings"]) == 1 end) =~
             "isn't a JSON object"
  end

  test "builds without a settings file say so" do
    Application.put_env(:tui, :config_path, nil)

    assert capture_io(:stderr, fn -> assert CLI.main(["--settings"]) == 1 end) =~
             "no settings file"
  end
end
