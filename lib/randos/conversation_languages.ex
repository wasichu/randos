defmodule Randos.ConversationLanguages do
  @moduledoc """
  Stable language codes used for conversation preferences.
  """

  @languages [
    {"English", "en"},
    {"Spanish", "es"},
    {"French", "fr"},
    {"German", "de"},
    {"Italian", "it"},
    {"Portuguese", "pt"}
  ]

  @doc """
  Returns conversation language names and stable internal codes.
  """
  @spec all() :: [{String.t(), String.t()}]
  def all, do: @languages

  @doc """
  Finds an English display name for a language code.
  """
  @spec name(String.t()) :: String.t()
  def name(code) when is_binary(code) do
    @languages
    |> Enum.find_value(fn
      {name, ^code} -> name
      _language -> nil
    end)
    |> Kernel.||(code)
  end
end
