defmodule RandosWeb.ParticipantErrors do
  @moduledoc """
  What a participant's `error` means, in words, for every client: the
  LiveView renders it, and the participant channel sends it as the state's
  `error_message`, so the TUI shows the same text instead of its own copy.
  """
  use Gettext, backend: RandosWeb.Gettext

  @doc """
  The words for a participant's `notice` (`nil` for none): news, not an
  error, e.g. that an invitation call ended.
  """
  @spec notice(:call_ended | nil) :: String.t() | nil
  def notice(nil), do: nil

  def notice(:call_ended) do
    gettext_comment(
      "Shown on the form after an invitation call the other person (or time) ended."
    )

    gettext("The call ended.")
  end

  @doc "The message for a participant error (`nil` for none)."
  @spec message(Randos.Participant.error() | nil) :: String.t() | nil
  def message(nil), do: nil

  def message(:adult_terms_required),
    do: gettext("Accept the 18+ acknowledgment before looking for a rando.")

  def message(:unsupported_language),
    do: gettext("Choose supported conversation languages.")

  def message(:call_start_failed),
    do: gettext("We couldn't start that call. Please try again.")

  def message(:invitation_invalid),
    do: gettext("That link doesn't work any more.")

  def message(:invitation_expired),
    do: gettext("Your link expired before anyone used it.")

  def message(:audio_mismatch),
    do:
      gettext("That call can't be joined from here: one of you has audio and the other doesn't.")

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
