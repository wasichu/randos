defmodule RandosWeb.ParticipantErrors do
  @moduledoc """
  What a participant's `error` means, in words, for every client: the
  LiveView renders it, and the participant channel sends it as the state's
  `error_message`, so the TUI shows the same text instead of its own copy.
  """
  use Gettext, backend: RandosWeb.Gettext

  @doc "The message for a participant error (`nil` for none)."
  @spec message(Randos.Participant.error() | nil) :: String.t() | nil
  def message(nil), do: nil

  def message(:adult_terms_required),
    do: gettext("Accept the 18+ acknowledgment before looking for a rando.")

  def message(:unsupported_language),
    do: gettext("Choose supported conversation languages.")

  def message(:call_start_failed),
    do: gettext("We couldn't start that call. Please try again.")

  def message(:microphone_denied),
    do:
      gettext("The call ended because microphone access was blocked. Allow it, then look again.")

  def message(:microphone_not_found),
    do: gettext("The call ended because no microphone was found.")

  def message(:audio_unavailable),
    do: gettext("The call ended because audio isn't available here.")

  def message(:audio_failed),
    do: gettext("The call ended because audio stopped working on this device.")
end
