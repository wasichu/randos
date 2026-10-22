defmodule RandosWeb.Translations do
  @moduledoc """
  The site's strings in each language, for the public `/translations` page:
  read from the `.po` files at compile time (they only change with a
  deploy), in the template's order. And the link that opens a translation
  fix on GitHub (`.github/ISSUE_TEMPLATE/translation.yml`) with everything
  but the fix filled in; its parameters are the form's field ids.
  """

  @issues "https://github.com/wasichu/randos/issues/new"

  @type entry :: %{msgid: String.t(), msgctxt: String.t() | nil, msgstr: String.t()}

  @locales for {code, _name} <- RandosWeb.Locale.all(), code != "en", do: code
  @paths Map.new(@locales, fn locale ->
           {locale, Path.expand("../../priv/gettext/#{locale}/LC_MESSAGES/default.po", __DIR__)}
         end)
  for {_locale, path} <- @paths, do: @external_resource(path)

  @entries Map.new(@paths, fn {locale, path} ->
             entries =
               for message <- Expo.PO.parse_file!(path).messages,
                   msgid = IO.iodata_to_binary(message.msgid),
                   msgid != "" do
                 msgstr =
                   case message do
                     %Expo.Message.Singular{msgstr: text} ->
                       IO.iodata_to_binary(text)

                     %Expo.Message.Plural{msgstr: forms} ->
                       forms
                       |> Enum.sort()
                       |> Enum.map(fn {_n, text} -> IO.iodata_to_binary(text) end)
                       |> Enum.reject(&(&1 == ""))
                       |> Enum.join(" / ")
                   end

                 %{
                   msgid: msgid,
                   msgctxt: message.msgctxt && IO.iodata_to_binary(message.msgctxt),
                   msgstr: msgstr
                 }
               end

             {locale, entries}
           end)

  @doc "The languages that have translations (every interface language but English)."
  @spec locales() :: [String.t()]
  def locales, do: @locales

  @doc "A language's strings, English and translation, in the template's order."
  @spec entries(String.t()) :: [entry()]
  def entries(locale), do: Map.get(@entries, locale, [])

  @doc "The GitHub link that opens a fix for `entry` in `locale`, filled in but for the fix."
  @spec suggest_url(String.t(), entry()) :: String.t()
  def suggest_url(locale, entry) do
    @issues <>
      "?" <>
      URI.encode_query(%{
        "template" => "translation.yml",
        "labels" => "translation",
        "title" => "Translation fix (#{locale}): #{String.slice(entry.msgid, 0, 50)}",
        "locale" => locale,
        "english" => entry.msgid,
        "context" => entry.msgctxt || "",
        "current" => entry.msgstr
      })
  end
end
