defmodule RandosDev.VoiceLabLive do
  @moduledoc """
  The voice lab (Phase 5, `docs/architecture/refactor_plan.md`), at
  `/dev/voice-lab` in development only: render a clip through each voice
  processor offline (OfflineAudioContext, the same AudioWorklet code a call
  runs), switch between them at the same position, compare spectrograms,
  and measure what the seam costs a live call.

  This module renders only the page's shell; `assets/js/voice_lab/lab.js`
  (a dev-only bundle, loaded by the root layout when `voice_lab` is set)
  owns everything inside `#voice-lab`. Nothing is recorded, stored, or
  uploaded. Strings are English on purpose: the lab is a developer tool,
  not part of the product.
  """
  use RandosWeb, :live_view

  alias RandosDev.VoiceLabBenchmark

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Voice lab",
       voice_lab: true,
       benchmark: VoiceLabBenchmark.load()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-[calc(100vh-5rem)] bg-stone-50 text-stone-950">
        <div
          id="voice-lab"
          phx-update="ignore"
          class="mx-auto max-w-6xl space-y-8 px-4 py-8 sm:px-8"
          data-clips-path="/dev/voice-lab/clips"
        >
          <header class="space-y-2">
            <h1 class="text-3xl font-semibold tracking-normal">Voice lab</h1>
            <p class="max-w-3xl text-stone-600">
              Each processor renders the clip offline with the same AudioWorklet code a
              call runs. Switch while playing to compare at the same moment. Headphones
              recommended; nothing you do here is recorded or sent anywhere.
            </p>
          </header>

          <section id="voice-lab-controls" class="grid gap-6 rounded-lg border border-stone-200 bg-white p-5 sm:grid-cols-2">
            <label class="block space-y-1">
              <span class="text-sm font-medium text-stone-700">Source</span>
              <select id="voice-lab-source" class="w-full rounded-md border border-stone-300 bg-white px-3 py-2">
              </select>
            </label>
            <div id="voice-lab-params" class="space-y-3"></div>
            <div class="flex flex-wrap items-center gap-3 sm:col-span-2">
              <button
                id="voice-lab-render"
                type="button"
                class="rounded-md bg-teal-700 px-4 py-2 font-medium text-white transition hover:bg-teal-800 disabled:opacity-50"
              >
                Render
              </button>
              <button
                id="voice-lab-play"
                type="button"
                class="rounded-md border border-stone-300 px-4 py-2 font-medium transition hover:bg-stone-100 disabled:opacity-50"
                disabled
              >
                Play
              </button>
              <button
                id="voice-lab-stop"
                type="button"
                class="rounded-md border border-stone-300 px-4 py-2 font-medium transition hover:bg-stone-100 disabled:opacity-50"
                disabled
              >
                Stop
              </button>
              <span id="voice-lab-status" class="text-sm text-stone-600" data-state="idle">
                Pick a source and render.
              </span>
            </div>
          </section>

          <section id="voice-lab-results" class="space-y-4"></section>

          <section id="voice-lab-seam" class="space-y-3 rounded-lg border border-stone-200 bg-white p-5">
            <h2 class="text-lg font-semibold tracking-normal">What the seam costs a call</h2>
            <p class="max-w-3xl text-sm text-stone-600">
              A click train sent live through a processor (as a call would) and directly,
              recorded side by side: the difference is the delay the processor adds.
              Silent: nothing plays.
            </p>
            <div class="flex flex-wrap items-center gap-3">
              <button
                id="voice-lab-measure"
                type="button"
                class="rounded-md border border-stone-300 px-4 py-2 font-medium transition hover:bg-stone-100 disabled:opacity-50"
              >
                Measure passthrough
              </button>
              <span id="voice-lab-seam-result" class="text-sm text-stone-700" data-state="idle"></span>
            </div>
          </section>
        </div>
        <%!-- Outside #voice-lab (which its script owns), so LiveView renders it. --%>
        <VoiceLabBenchmark.section report={@benchmark} />
      </div>
    </Layouts.app>
    """
  end
end
