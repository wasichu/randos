defmodule RandosWeb.VoiceProcessorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RandosWeb.VoiceProcessor

  setup do
    on_exit(fn ->
      Application.delete_env(:randos, :voice_processor)
      Application.delete_env(:randos, :require_built_voice_processor)
    end)
  end

  test "no processor is fine" do
    assert VoiceProcessor.check!() == :ok
  end

  test "a built processor's name is fine; the built ones are listed" do
    [name | _] = VoiceProcessor.available()
    Application.put_env(:randos, :voice_processor, name)
    Application.put_env(:randos, :require_built_voice_processor, true)
    assert VoiceProcessor.check!() == :ok
    assert "passthrough" in VoiceProcessor.available()
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
