defmodule RandosWeb.VoiceProcessorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RandosWeb.VoiceProcessor

  # A built-assets directory of our own: the real one exists only after an
  # asset build. Digested and compressed copies aren't processors.
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    for file <- ~w(passthrough.js pitch_shift.js pitch_shift-1a2b3c.js pitch_shift.js.gz),
        do: File.write!(Path.join(dir, file), "")

    Application.put_env(:randos, :voice_processor_dir, dir)

    on_exit(fn ->
      Application.delete_env(:randos, :voice_processor)
      Application.delete_env(:randos, :require_built_voice_processor)
      Application.delete_env(:randos, :voice_processor_dir)
    end)
  end

  test "no processor is fine" do
    assert VoiceProcessor.check!() == :ok
  end

  test "a built processor's name is fine; the built ones are listed" do
    assert VoiceProcessor.available() == ["passthrough", "pitch_shift"]
    Application.put_env(:randos, :voice_processor, "pitch_shift")
    Application.put_env(:randos, :require_built_voice_processor, true)
    assert VoiceProcessor.check!() == :ok
  end

  test "an unknown name: production refuses to start, development warns" do
    Application.put_env(:randos, :voice_processor, "pitch_shfit")
    assert capture_log(fn -> assert VoiceProcessor.check!() == :ok end) =~ "pitch_shfit"

    Application.put_env(:randos, :require_built_voice_processor, true)
    assert_raise RuntimeError, ~r/names no built voice processor/, &VoiceProcessor.check!/0

    Application.put_env(:randos, :voice_processor, "../../../etc/passwd")
    assert_raise RuntimeError, &VoiceProcessor.check!/0
  end
end
