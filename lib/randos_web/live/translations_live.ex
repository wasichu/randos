defmodule RandosWeb.TranslationsLive do
  @moduledoc """
  The site's text in one language next to the English, each with a link that
  opens a translation fix on GitHub with everything but the fix filled in
  (`RandosWeb.Translations`). Read-only: nothing is stored or sent from here.
  The language is `?lang=`, else the interface language; English has nothing
  to fix, so it shows only the language picker.
  """
  use RandosWeb, :live_view

  alias RandosWeb.{Locale, Translations}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Translations"), query: "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    lang =
      if params["lang"] in Translations.locales(),
        do: params["lang"],
        else: if(socket.assigns.locale in Translations.locales(), do: socket.assigns.locale)

    {:noreply, socket |> assign(lang: lang) |> filter(socket.assigns.query)}
  end

  @impl true
  def handle_event("filter", %{"query" => query}, socket), do: {:noreply, filter(socket, query)}

  defp filter(%{assigns: %{lang: nil}} = socket, query),
    do: assign(socket, query: query, entries: [])

  defp filter(socket, query) do
    needle = query |> String.trim() |> String.downcase()

    entries =
      socket.assigns.lang
      |> Translations.entries()
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _index} ->
        needle == "" or
          String.contains?(String.downcase(entry.msgid), needle) or
          String.contains?(String.downcase(entry.msgstr), needle)
      end)

    assign(socket, query: query, entries: entries)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-[calc(100vh-5rem)] bg-stone-50 text-stone-950">
        <article class="mx-auto max-w-3xl px-4 py-10 sm:px-8 sm:py-16">
          <header class="space-y-4">
            <h1 class="text-4xl font-semibold tracking-normal text-stone-950">
              {gettext("Help fix a translation")}
            </h1>
            <p class="text-base leading-7 text-stone-700">
              {gettext(
                "This site's translations were made by machine. If something reads wrong, find it below and press “Suggest a fix”: it opens an issue on GitHub with everything filled in but your fix (you need a GitHub account). A pull request with your fix opens on its own, and it goes live once it's reviewed."
              )}
            </p>
          </header>

          <nav id="translation-languages" class="mt-8 flex flex-wrap gap-2">
            <.link
              :for={code <- Translations.locales()}
              id={"translation-lang-#{code}"}
              patch={~p"/translations?#{[lang: code]}"}
              aria-current={code == @lang && "page"}
              class={[
                "rounded-md border px-3 py-1.5 text-sm transition",
                code == @lang && "border-teal-600 bg-teal-50 text-teal-900",
                code != @lang &&
                  "border-stone-200 bg-white text-stone-700 hover:border-stone-400 hover:text-stone-950"
              ]}
            >
              {language_name(code)}
            </.link>
          </nav>

          <p :if={is_nil(@lang)} id="translation-pick" class="mt-6 text-stone-600">
            {gettext("Pick the language you'd like to check.")}
          </p>

          <div :if={@lang} class="mt-8 space-y-4">
            <form id="translation-filter" phx-change="filter" phx-submit="filter">
              <label for="translation-query" class="sr-only">{gettext("Find a phrase")}</label>
              <input
                id="translation-query"
                name="query"
                type="search"
                value={@query}
                phx-debounce="200"
                placeholder={
                  gettext("Find a phrase, in English or %{language}", language: language_name(@lang))
                }
                class="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-sm text-stone-950 placeholder:text-stone-400 focus:border-teal-600 focus:outline-none focus:ring-2 focus:ring-teal-600/20"
              />
            </form>

            <p :if={@entries == []} id="translation-none" class="text-sm text-stone-500">
              {gettext("Nothing matches.")}
            </p>

            <ol id="translations-list" class="space-y-3">
              <li
                :for={{entry, index} <- @entries}
                id={"translation-#{index}"}
                class="rounded-lg border border-stone-200 bg-white p-4"
              >
                <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div class="min-w-0 space-y-2 text-sm leading-6">
                    <p dir="ltr" class="text-stone-500">
                      <span
                        :if={entry.msgctxt}
                        class="me-1.5 rounded bg-stone-100 px-1.5 py-0.5 text-xs text-stone-600"
                      >
                        {entry.msgctxt}
                      </span>
                      <.with_placeholders text={entry.msgid} />
                    </p>
                    <p :if={entry.msgstr != ""} dir={Locale.dir(@lang)} class="text-stone-950">
                      <.with_placeholders text={entry.msgstr} />
                    </p>
                    <p :if={entry.msgstr == ""} class="italic text-stone-400">
                      {gettext("Not translated yet")}
                    </p>
                  </div>
                  <a
                    id={"suggest-#{index}"}
                    href={Translations.suggest_url(@lang, entry)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex shrink-0 items-center gap-1.5 text-sm font-medium text-teal-700 transition hover:text-teal-900"
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                    {gettext("Suggest a fix")}
                  </a>
                </div>
              </li>
            </ol>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end

  # `%{...}` placeholders kept whole (a line never breaks inside one) and set
  # apart, since a fix must keep them exactly.
  attr :text, :string, required: true

  defp with_placeholders(assigns) do
    parts =
      ~r/%\{[a-z_]+\}/
      |> Regex.split(assigns.text, include_captures: true)
      |> Enum.map(&{Regex.match?(~r/^%\{[a-z_]+\}$/, &1), &1})

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <%= for {placeholder?, part} <- @parts do %>
      <span
        :if={placeholder?}
        class="whitespace-nowrap rounded bg-stone-100 px-1 font-mono text-[0.85em] text-teal-800"
      >{part}</span>{if not placeholder?, do: part}
    <% end %>
    """
  end

  defp language_name(code),
    do: Enum.find_value(Locale.all(), code, fn {c, name} -> if c == code, do: name end)
end
