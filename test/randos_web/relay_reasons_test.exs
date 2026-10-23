defmodule RandosWeb.RelayReasonsTest do
  use ExUnit.Case, async: true

  alias RandosWeb.RelayHealth.Turn
  alias RandosWeb.RelayReasons

  test "every reason the relay check gives has its own words" do
    messages = for reason <- Turn.reasons(), do: RelayReasons.message(Atom.to_string(reason))

    assert Enum.all?(messages, &(is_binary(&1) and &1 != ""))
    assert length(Enum.uniq(messages)) == length(Turn.reasons())
  end
end
