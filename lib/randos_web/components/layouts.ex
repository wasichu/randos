defmodule RandosWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use RandosWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :in_call, :boolean,
    default: false,
    doc: "hides the language switcher (switching reloads the page, ending the call)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-4 border-b border-stone-200 bg-stone-50/90 px-5 py-4 backdrop-blur dark:border-stone-800 dark:bg-stone-950/90 sm:px-8">
      <a
        href="/"
        class="inline-flex items-center gap-3 text-sm font-semibold text-stone-950 dark:text-stone-50"
      >
        <img src={~p"/images/logo.svg"} alt="" class="size-9" />
        <span>randos</span>
      </a>
      <nav class="flex items-center gap-3 text-sm font-medium text-stone-600 dark:text-stone-300">
        <.link
          navigate={~p"/about"}
          class="inline-flex items-center gap-1.5 transition hover:text-stone-950 dark:hover:text-white"
        >
          <.icon name="hero-information-circle" class="size-4" />
          {gettext("About")}
        </.link>
        <%!-- Hidden during a call: switching reloads the page, which would end it. --%>
        <div id="locale-switcher-slot" class={@in_call && "hidden"}>
          <.locale_switcher />
        </div>
        <button
          id="theme-toggle"
          type="button"
          data-theme-toggle
          aria-pressed="false"
          title={gettext("Switch theme")}
          class="inline-flex size-9 items-center justify-center rounded-md border border-stone-200 bg-white text-stone-600 transition hover:border-stone-400 hover:text-stone-950 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-200 dark:hover:border-stone-500 dark:hover:text-white"
        >
          <.icon name="hero-moon" class="size-4 dark:hidden" />
          <.icon name="hero-sun" class="hidden size-4 dark:block" />
          <span class="sr-only">{gettext("Toggle dark mode")}</span>
        </button>
      </nav>
    </header>

    <main>
      {render_slot(@inner_block)}
    </main>

    <.site_footer />

    <.flash_group flash={@flash} />
    """
  end

  # Quiet links on every page: whether calls work, what's kept, and the
  # code, with the commit this server runs (so anyone can read exactly that).
  defp site_footer(assigns) do
    assigns = assign(assigns, :commit, Application.get_env(:randos, :commit, ""))

    ~H"""
    <footer
      id="site-footer"
      class="mx-auto flex w-full max-w-6xl flex-wrap items-center gap-x-5 gap-y-2 px-5 py-8 text-sm text-stone-500 sm:px-8"
    >
      <.link id="footer-status" navigate={~p"/status"} class="transition hover:text-stone-900">
        {gettext("Status")}
      </.link>
      <a
        id="footer-privacy"
        href="https://github.com/wasichu/randos/blob/main/docs/privacy.md"
        class="transition hover:text-stone-900"
      >
        {gettext("Privacy")}
      </a>
      <a
        id="footer-source"
        href="https://github.com/wasichu/randos"
        class="transition hover:text-stone-900"
      >
        {gettext("Source (AGPL-3.0)")}
      </a>
      <a
        :if={@commit != ""}
        id="footer-commit"
        href={"https://github.com/wasichu/randos/commit/" <> String.replace_suffix(@commit, "-dirty", "")}
        title={
          if String.ends_with?(@commit, "-dirty"),
            do: gettext("Running this commit plus changes not yet committed"),
            else: gettext("The commit this server runs")
        }
        class="font-mono text-xs transition hover:text-stone-900"
      >
        {@commit}
      </a>
    </footer>
    """
  end

  # The interface language: a <details> menu of buttons in one small POST
  # form, so it works without JavaScript and prefetching can't trigger it.
  # RandosWeb.LocaleController remembers the choice and comes back here. Ignored by LiveView's patches
  # (it changes only on a full page load), so an open menu stays open.
  defp locale_switcher(assigns) do
    assigns =
      assign(assigns,
        current: Gettext.get_locale(RandosWeb.Gettext),
        locales: RandosWeb.Locale.all()
      )

    ~H"""
    <details id="locale-switcher" phx-update="ignore" class="group relative">
      <summary
        id="locale-switcher-toggle"
        title={gettext("Language")}
        class="inline-flex h-9 cursor-pointer list-none items-center gap-1.5 rounded-md border border-stone-200 bg-white px-2.5 text-stone-600 transition hover:border-stone-400 hover:text-stone-950 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-200 dark:hover:border-stone-500 dark:hover:text-white [&::-webkit-details-marker]:hidden"
      >
        <.icon name="hero-language" class="size-4" />
        <span class="uppercase">{@current}</span>
        <span class="sr-only">{gettext("Language")}</span>
      </summary>
      <form
        id="locale-options"
        method="post"
        action={~p"/locale"}
        class="absolute end-0 z-20 mt-2 max-h-80 w-48 overflow-y-auto rounded-md border border-stone-200 bg-white py-1 shadow-lg dark:border-stone-700 dark:bg-stone-900"
      >
        <button
          :for={{code, name} <- @locales}
          id={"locale-option-#{code}"}
          type="submit"
          name="locale"
          value={code}
          lang={code}
          aria-current={if code == @current, do: "true"}
          class={[
            "block w-full px-3 py-1.5 text-start transition hover:bg-stone-100 dark:hover:bg-stone-800",
            code == @current && "font-semibold text-teal-700 dark:text-teal-300"
          ]}
        >
          {name}
        </button>
      </form>
    </details>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
