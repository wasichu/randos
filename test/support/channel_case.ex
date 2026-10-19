defmodule RandosWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests (`Phoenix.ChannelTest` against the endpoint).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      @endpoint RandosWeb.Endpoint
    end
  end
end
