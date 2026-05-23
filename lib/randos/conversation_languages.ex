defmodule Randos.ConversationLanguages do
  @moduledoc """
  Stable language codes used for conversation preferences.
  """

  @languages [
    {"English (EN)", "en"},
    {"Español (ES)", "es"},
    {"中文 (ZH)", "zh"},
    {"हिन्दी (HI)", "hi"},
    {"العربية (AR)", "ar"},
    {"Português (PT)", "pt"},
    {"বাংলা (BN)", "bn"},
    {"Русский (RU)", "ru"},
    {"日本語 (JA)", "ja"},
    {"Français (FR)", "fr"},
    {"Deutsch (DE)", "de"},
    {"한국어 (KO)", "ko"},
    {"Italiano (IT)", "it"},
    {"Türkçe (TR)", "tr"},
    {"Bahasa Indonesia (ID)", "id"}
  ]

  @doc """
  Returns conversation language names and stable internal codes.
  """
  @spec all() :: [{String.t(), String.t()}]
  def all, do: @languages

  @doc """
  Returns supported stable internal language codes.
  """
  @spec codes() :: [String.t()]
  def codes do
    Enum.map(@languages, fn {_name, code} -> code end)
  end

  @doc """
  Finds a display label for a language code.
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
