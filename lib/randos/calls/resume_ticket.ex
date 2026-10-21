defmodule Randos.Calls.ResumeTicket do
  @moduledoc """
  Resume tickets: how a participant whose connection to the server dropped
  gets back into their call (`Randos.Calls.CallCoordinator.resume/4`).

  A ticket is 128 random bits, given to one participant of one call and
  held only in their client's memory. It identifies nothing but "the person
  in this seat of this call", works once (a resume issues a fresh one), and
  dies with the call. The server keeps only a hash of it, as a key in a
  `Registry` owned by the call's coordinator, so tickets vanish with the
  coordinator process; nothing is stored or logged.
  """

  @registry Randos.Calls.ResumeTickets

  @doc "The registry holding tickets' hashes (in the app's supervision tree)."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "A fresh ticket (URL-safe text for the client) and its registry key."
  @spec new() :: {String.t(), binary()}
  def new do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {ticket, key(ticket)}
  end

  @doc "The registry key for a ticket: its hash, so the ticket itself isn't kept."
  @spec key(String.t()) :: binary()
  def key(ticket) when is_binary(ticket), do: :crypto.hash(:sha256, ticket)

  @doc "The call and participant a ticket belongs to, if it's live."
  @spec lookup(term(), atom()) :: {:ok, pid(), String.t()} | :error
  def lookup(ticket, registry \\ @registry)

  def lookup(ticket, registry) when is_binary(ticket) and byte_size(ticket) <= 64 do
    case Registry.lookup(registry, key(ticket)) do
      [{call_pid, participant_id}] -> {:ok, call_pid, participant_id}
      [] -> :error
    end
  end

  def lookup(_ticket, _registry), do: :error
end
