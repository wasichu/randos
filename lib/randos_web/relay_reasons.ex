defmodule RandosWeb.RelayReasons do
  @moduledoc """
  Why the relay check failed, in words: the status page shows them for the
  codes in the status snapshot (`t:RandosWeb.RelayHealth.Turn.reason/0`, as
  strings). The TUI has its own words for the same codes.
  """
  use Gettext, backend: RandosWeb.Gettext

  @doc "The words for a reason code (an unknown one reads as \"refused\")."
  @spec message(String.t()) :: String.t()
  def message("no_answer") do
    gettext_comment("Why the relay check failed: the relay server didn't answer.")
    gettext("no answer")
  end

  def message("couldnt_connect") do
    gettext_comment("Why the relay check failed: no connection to the relay server.")
    gettext("couldn't connect")
  end

  def message("couldnt_resolve") do
    gettext_comment("Why the relay check failed: the relay server's name didn't resolve (DNS).")
    gettext("couldn't find the server")
  end

  def message("connection_closed") do
    gettext_comment("Why the relay check failed: the relay server closed the connection.")
    gettext("connection closed")
  end

  def message("unexpected_reply") do
    gettext_comment("Why the relay check failed: the relay server's reply made no sense.")
    gettext("unexpected reply")
  end

  def message("no_challenge") do
    gettext_comment("Why the relay check failed: the relay server didn't ask for credentials.")
    gettext("no credentials asked for")
  end

  def message("credentials_refused") do
    gettext_comment("Why the relay check failed: the relay server refused our credentials.")
    gettext("credentials refused")
  end

  def message("tls_failed") do
    gettext_comment("Why the relay check failed: the secure (TLS) connection failed.")
    gettext("secure connection failed")
  end

  def message(_refused) do
    gettext_comment("Why the relay check failed: the relay server refused the request.")
    gettext("refused")
  end
end
