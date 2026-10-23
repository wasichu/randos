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
    {"Bahasa Indonesia (ID)", "id"},
    {"Tiếng Việt (VI)", "vi"},
    {"اردو (UR)", "ur"},
    {"Kiswahili (SW)", "sw"},
    {"فارسی (FA)", "fa"},
    {"Filipino (FIL)", "fil"}
  ]
  @supported_language_codes Enum.map(@languages, fn {_name, code} -> code end)

  # Codes browsers send for a language randos lists under another code:
  # Filipino is standardized Tagalog, and a few browsers still say `tl`.
  @aliases %{"tl" => "fil"}

  @doc """
  The supported code for a primary language subtag: itself, or the code
  randos lists it under (`tl` is `fil`); `nil` for anything else.
  """
  @spec resolve(String.t()) :: String.t() | nil
  def resolve(code) when is_binary(code) do
    code = Map.get(@aliases, code, code)
    if code in @supported_language_codes, do: code
  end

  @doc """
  Returns conversation language names and stable internal codes.
  """
  @spec all() :: [{String.t(), String.t()}]
  def all, do: @languages

  @doc """
  Returns supported stable internal language codes.
  """
  @spec codes() :: [String.t()]
  def codes, do: @supported_language_codes

  @doc """
  Returns true when a stable internal language code is supported.
  """
  @spec supported?(String.t()) :: boolean()
  def supported?(code) when is_binary(code), do: code in codes()

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

  @doc """
  Normalizes a browser locale into a supported language code.
  """
  @spec code_from_locale(String.t() | nil) :: String.t()
  def code_from_locale(locale) when is_binary(locale) do
    locale
    |> String.split(["-", "_"], parts: 2)
    |> List.first()
    |> String.downcase()
    |> resolve()
    |> Kernel.||("en")
  end

  def code_from_locale(_locale), do: "en"
end
