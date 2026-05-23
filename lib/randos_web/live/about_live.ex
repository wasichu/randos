defmodule RandosWeb.AboutLive do
  use RandosWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("About"))}
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
                {gettext("About Randos")}
              </h1>
            </div>
            <p class="text-xl leading-8 text-stone-700">
              {gettext("Randos is a small place for anonymous, audio-only language conversation.")}
            </p>
          </header>

          <div class="mt-10 space-y-9 text-base leading-7 text-stone-700">
            <section class="space-y-3">
              <h2 class="text-xl font-semibold tracking-normal text-stone-950">
                {gettext("A doorway, not a platform")}
              </h2>
              <p>
                {gettext(
                  "You choose the language you want to speak and the language you want to hear. Randos pairs you with someone compatible for a short conversation, then gets out of the way."
                )}
              </p>
              <p>
                {gettext("It is meant for")}
                <a
                  href="https://www.dreaming.com/blog-posts/crosstalk"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-medium text-teal-700 underline decoration-teal-200 underline-offset-4 transition hover:text-teal-900 hover:decoration-teal-700"
                >
                  {gettext("crosstalk")}
                </a>
                {gettext(
                  ", language exchange, listening practice, and ordinary casual conversation without forcing people into rigid modes or labels."
                )}
              </p>
            </section>

            <section class="space-y-3">
              <h2 class="text-xl font-semibold tracking-normal text-stone-950">
                {gettext("Intentionally minimal")}
              </h2>
              <p>
                {gettext(
                  "There are no accounts, profiles, contacts, followers, feeds, streaks, scores, or permanent social graph. Randos is closer to conversational infrastructure than social media."
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
              <p>
                {gettext(
                  "You can leave instantly at any time. When time is up, a conversation only continues if both people choose to extend it."
                )}
              </p>
            </section>

            <section class="space-y-3 rounded-md border border-stone-200 bg-white p-5">
              <h2 class="text-xl font-semibold tracking-normal text-stone-950">
                {gettext("What Randos is not")}
              </h2>
              <p>
                {gettext(
                  "It is not a social network, a content platform, or a metrics-driven language app. It is a simple audio room for brief practice with another person."
                )}
              </p>
            </section>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
