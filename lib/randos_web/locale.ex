defmodule RandosWeb.Locale do
  @moduledoc """
  The interface language: English plus the 19 other practice languages.

  Resolved per request, in order: the person's explicit choice (the
  switcher in the header, remembered in the `randos_locale` cookie, which
  holds only the language code), then the browser's `Accept-Language`,
  then English. Missing translations fall back to English (gettext returns
  the English text for an empty `msgstr`).

  As a plug (in the `:browser` pipeline) it sets the request's locale and
  puts it in the session; as an `on_mount` hook it sets the LiveView
  process's locale from the session and assigns `:locale` for the root
  layout (`lang`, and `dir="rtl"` for Arabic, Urdu and Persian).
  """
  @behaviour Plug

  import Plug.Conn

  @cookie "randos_locale"
  # A year: a preference, not an identifier (only the code is stored).
  @cookie_max_age 60 * 60 * 24 * 365
  @default "en"
  @rtl ~w(ar ur fa)

  # The same languages, and endonyms, as the conversation languages.
  @locales Enum.map(Randos.ConversationLanguages.all(), fn {label, code} ->
             {code, String.replace(label, ~r/ \([A-Z]{2,3}\)$/, "")}
           end)
  @codes Enum.map(@locales, &elem(&1, 0))

  @doc "Every interface language as `{code, name in that language}`, English first."
  @spec all() :: [{String.t(), String.t()}]
  def all, do: @locales

  @doc "True for a supported interface language code."
  @spec supported?(term()) :: boolean()
  def supported?(code), do: code in @codes

  @doc ~s(The text direction for a locale: `"rtl"` for Arabic, Urdu and Persian, else `"ltr"`.)
  @spec dir(String.t()) :: String.t()
  def dir(locale) when locale in @rtl, do: "rtl"
  def dir(_locale), do: "ltr"

  @doc "The cookie that remembers an explicit choice."
  @spec cookie() :: String.t()
  def cookie, do: @cookie

  @doc "Sets the cookie for an explicit choice (`RandosWeb.LocaleController`)."
  @spec remember(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def remember(conn, locale) do
    put_resp_cookie(conn, @cookie, locale,
      max_age: @cookie_max_age,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https
    )
  end

  @doc """
  The best supported locale for an `Accept-Language` header, or `nil`.
  Region subtags are ignored (`pt-BR` is `pt`, `zh-Hant` is `zh`), an old
  code finds its language (`tl` is `fil`); `q` weights order the choices.
  """
  @spec from_accept_language(String.t() | nil) :: String.t() | nil
  def from_accept_language(nil), do: nil

  def from_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_range/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_code, q} -> q end, :desc)
    |> Enum.find_value(fn {code, _q} -> Randos.ConversationLanguages.resolve(code) end)
  end

  defp parse_language_range(range) do
    [tag | params] = range |> String.trim() |> String.split(";")
    code = tag |> String.split("-") |> hd() |> String.downcase()
    if code == "" or code == "*", do: nil, else: {code, quality(params)}
  end

  defp quality(params) do
    Enum.find_value(params, 1.0, fn param ->
      with "q=" <> q <- String.trim(param),
           {q, _rest} <- Float.parse(q) do
        q
      else
        _other -> nil
      end
    end)
  end

  ## Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    locale =
      Enum.find([conn.cookies[@cookie], accept_language(conn)], @default, &supported?/1)

    Gettext.put_locale(RandosWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_session("locale", locale)
  end

  defp accept_language(conn),
    do: conn |> get_req_header("accept-language") |> List.first() |> from_accept_language()

  ## LiveView

  @doc false
  def on_mount(:default, _params, session, socket) do
    locale = if supported?(session["locale"]), do: session["locale"], else: @default
    Gettext.put_locale(RandosWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end
end
