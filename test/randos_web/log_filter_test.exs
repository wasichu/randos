defmodule RandosWeb.LogFilterTest do
  # Phoenix logs LiveView connect params and channel join params; a resume
  # ticket arrives in both and must never be written out (docs/privacy.md).
  use ExUnit.Case, async: true

  test "a resume ticket is filtered from Phoenix's logged parameters" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "resume_ticket" => "wFnjXn6uuyQnFlzlvLqksA",
        "vsn" => "2.0.0"
      })

    assert filtered == %{"resume_ticket" => "[FILTERED]", "vsn" => "2.0.0"}
  end
end
