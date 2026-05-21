defmodule Randos.Comms do
  @moduledoc """
  Ash domain for anonymous language-practice communication concepts.

  This domain models durable concepts, but the current resources use ETS so
  records disappear when the server restarts.
  """

  use Ash.Domain

  resources do
    resource Randos.Comms.AnonymousSession
    resource Randos.Comms.CallSession
  end
end
