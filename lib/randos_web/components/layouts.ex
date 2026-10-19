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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-4 border-b border-stone-200 bg-stone-50/90 px-5 py-4 backdrop-blur dark:border-stone-800 dark:bg-stone-950/90 sm:px-8">
      <a
        href="/"
        class="inline-flex items-center gap-3 text-sm font-semibold text-stone-950 dark:text-stone-50"
      >
        <img src={~p"/images/logo.svg"} alt="" class="size-9" />
        <span>{gettext("Randos")}</span>
      </a>
      <nav class="flex items-center gap-3 text-sm font-medium text-stone-600 dark:text-stone-300">
        <.link
          navigate={~p"/about"}
          class="inline-flex items-center gap-1.5 transition hover:text-stone-950 dark:hover:text-white"
        >
          <.icon name="hero-information-circle" class="size-4" />
          {gettext("About")}
        </.link>
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

    <.flash_group flash={@flash} />
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
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
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
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
