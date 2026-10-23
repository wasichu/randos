defmodule RandosWeb.AboutLive do
  use RandosWeb, :live_view

  alias Randos.Calls.Lifecycle

  @impl true
  def mount(_params, _session, socket) do
    gettext_comment(
      ~s(The page that explains what randos is \("about us"\), not "approximately".)
    )

    {:ok,
     assign(socket,
       page_title: gettext("About"),
       call_minutes: div(Lifecycle.call_duration_seconds(), 60),
       extension_minutes: div(Lifecycle.extension_duration_seconds(), 60),
       max_call_minutes: div(Lifecycle.max_call_duration_seconds(), 60)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-[calc(100vh-5rem)] bg-stone-50 text-stone-950">
        <article class="mx-auto max-w-3xl px-4 py-10 sm:px-8 sm:py-16">
          <header class="space-y-5">
            <div class="flex items-center gap-3">
              <img src={~p"/images/logo.svg"} alt="" class="size-11" />
              <h1 class="text-4xl font-semibold tracking-normal text-stone-950">
                <% gettext_comment(
                  "Title of the page that explains what randos is (\"about us\"), not \"approximately\". randos is the site's name: keep it as it is, in Latin letters, lowercase."
                ) %>
                {gettext("About randos")}
              </h1>
            </div>
            <p class="text-xl leading-8 text-stone-700">
              {gettext("randos is a place for anonymous, audio-only language conversation.")}
            </p>
          </header>

          <div class="mt-10 space-y-9 text-base leading-7 text-stone-700">
            <section class="space-y-3">
              <h2 class="text-xl font-semibold tracking-normal text-stone-950">
                {gettext("A doorway, not a platform")}
              </h2>
              <p>
                {gettext(
                  "You choose the language you want to speak and the language you want to hear. randos pairs you with someone compatible for a short conversation, then gets out of the way."
                )}
              </p>
              <p>
                {elem(meant_for(), 0)}<a
                  href="https://www.dreaming.com/blog-posts/crosstalk"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-medium text-teal-700 underline decoration-teal-200 underline-offset-4 transition hover:text-teal-900 hover:decoration-teal-700"
                >
                  <% gettext_comment("Link text: the name of a way to practise where each person speaks their own language and understands the other's (not electrical crosstalk).") %>
                  {gettext("crosstalk")}
                </a>{elem(
                  meant_for(),
                  1
                )}
              </p>
            </section>

            <section class="space-y-3">
              <h2 class="text-xl font-semibold tracking-normal text-stone-950">
                {gettext("Intentionally minimal")}
              </h2>
              <p>
                {gettext(
                  "There are no accounts, profiles, contacts, followers, feeds, streaks, scores, or permanent social graph. randos is closer to conversational infrastructure than social media."
                )}
              </p>
              <p>
                {gettext(
                  "The interface is quiet on purpose. The goal is low-pressure human presence, not performance or engagement loops."
                )}
              </p>
            </section>

            <section class="space-y-3">
              <h2 class="text-xl font-semibold tracking-normal text-stone-950">
                {gettext("Ephemeral by default")}
              </h2>
              <p>
                {gettext(
                  "Conversations are private and are not stored. The server coordinates the call, but it does not keep recordings or build a history around who you spoke with."
                )}
              </p>
              <p id="about-call-length">
                {gettext(
                  "A conversation lasts %{call} minutes. When time is up, it continues for another %{extension} minutes only if both people choose to, up to %{max} minutes in all. You can leave at any time.",
                  call: @call_minutes,
                  extension: @extension_minutes,
                  max: @max_call_minutes
                )}
              </p>
              <p id="about-privacy">
                {gettext(
                  "What each part of randos sees, logs, and keeps, with the configuration behind every claim:"
                )}
                <a
                  id="privacy-link"
                  href="https://github.com/wasichu/randos/blob/main/docs/privacy.md"
                  class="font-medium text-teal-700 underline decoration-teal-200 underline-offset-4 transition hover:text-teal-900 hover:decoration-teal-700"
                >
                  <% gettext_comment(
                    "Link text, inside a sentence: the page on what randos sees, logs and keeps (privacy)."
                  ) %>
                  {gettext("privacy")}
                </a>
              </p>
            </section>

            <section id="about-translations" class="space-y-3">
              <h2 class="text-xl font-semibold tracking-normal text-stone-950">
                {gettext("Translations")}
              </h2>
              <p>
                {gettext(
                  "The translations of this site were made by machine and haven't been reviewed by people yet. If something reads wrong in your language, please help fix it: find the text, write how it should read, and we'll do the rest."
                )}
              </p>
              <.link
                id="fix-translation-link"
                navigate={~p"/translations"}
                class="inline-flex items-center gap-2 font-medium text-teal-700 underline decoration-teal-200 underline-offset-4 transition hover:text-teal-900 hover:decoration-teal-700"
              >
                <.icon name="hero-language" class="size-4" />
                {gettext("Help fix a translation")}
              </.link>
            </section>

            <section class="flex flex-col gap-3 border-t border-stone-200 pt-6 text-sm sm:flex-row sm:items-center sm:justify-between">
              <p class="text-stone-500">
                {gettext("randos is free software (AGPL-3.0) and built in public.")}
              </p>
              <a
                href="https://github.com/wasichu/randos"
                target="_blank"
                rel="noopener noreferrer"
                class="inline-flex items-center gap-2 font-medium text-stone-700 transition hover:text-teal-800"
              >
                <.icon name="hero-code-bracket" class="size-4" />
                {gettext("View on GitHub")}
              </a>
            </section>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end

  # One sentence for translators, with the link's place marked: the text
  # around %{crosstalk} goes on either side of the link. (Never rendered as
  # HTML: translations are plain text.)
  @link_mark "\u{E000}"
  defp meant_for do
    gettext_comment(
      "%{crosstalk} is replaced by a link reading \"crosstalk\" (translated separately); keep it."
    )

    text =
      gettext(
        "It is meant for %{crosstalk}, language exchange, listening practice, and ordinary casual conversation without forcing people into rigid modes or labels.",
        crosstalk: @link_mark
      )

    case String.split(text, @link_mark, parts: 2) do
      [before, rest] -> {before, rest}
      # A translation that lost the mark: the sentence, then the link.
      [whole] -> {whole <> " ", ""}
    end
  end
end
