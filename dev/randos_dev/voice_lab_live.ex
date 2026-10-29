defmodule RandosDev.VoiceLabLive do
  @moduledoc """
  Development-only voice lab at `/dev/voice-lab`: listen to bundled clips
  through the call's own worklets, learn the audio basics, measure added
  call delay, and inspect the saved benchmark. The dev-only lab bundle owns
  the ignored DOM. Audio stays in the browser; microphone preview is explicit and never recorded.
  Strings are English because this is a developer tool.
  """
  use RandosWeb, :live_view

  alias RandosDev.VoiceLabBenchmark
  alias RandosDev.VoiceLabGuide
  alias RandosDev.VoiceLabModels
  alias RandosDev.VoiceLabRecovery
  alias RandosDev.VoiceLabRound
  alias RandosDev.VoiceLabReviews

  @impl true
  def mount(_params, _session, socket) do
    model_experiment = VoiceLabModels.load()
    buffering = VoiceLabRound.buffering()

    {:ok,
     assign(socket,
       buffering_report: buffering,
       short_buffer_ready: VoiceLabRound.short_buffer_ready?(buffering),
       gentle_pitch: VoiceLabRound.load("gentle"),
       engine_comparison: VoiceLabRound.load("engines"),
       masking_round: VoiceLabRound.load(),
       page_title: "Voice lab",
       voice_lab: true,
       review_build: VoiceLabReviews.build_id(),
       review_sources: VoiceLabReviews.source_ids(),
       benchmark: VoiceLabBenchmark.load(),
       recovery: VoiceLabRecovery.load(),
       model_experiment: model_experiment,
       prepared_models: VoiceLabModels.listening_data(model_experiment)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="voice-lab"
        phx-update="ignore"
        class="mx-auto max-w-6xl space-y-6 px-4 py-8 text-stone-950 sm:px-8"
        data-clips-path="/dev/voice-lab/clips"
        data-review-build={@review_build}
        data-review-sources={JSON.encode!(@review_sources)}
        data-prepared-models={JSON.encode!(@prepared_models)}
      >
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold tracking-normal">Voice lab</h1>
          <p class="max-w-3xl text-stone-600">
            Explore voice disguises: how natural they sound, how different they sound
            from the original, and what they cost a call. The benchmark separately tests
            whether a model can match the speaker to known recordings.
          </p>
          <p class="text-sm text-stone-600">
            Bundled samples or a live microphone preview. Microphone audio is never recorded or uploaded. Headphones recommended.
          </p>
        </header>

        <p class="text-sm">
          <a
            id="voice-lab-dsp-report"
            href="/dev/voice-lab/browser-probe/dsp.html"
            class="text-teal-700 underline"
          >Browser DSP experiment: size, processing and delay</a>
        </p>
        <nav role="tablist" aria-label="Voice lab views" class="flex flex-wrap gap-2">
          <button
            :for={
              {key, label} <- [
                {"listen", "Listen & compare"},
                {"round", "Masking round"},
                {"engines", "Engine comparison"},
                {"gentle", "Gentler pitch"},
                {"voice", "Try your voice"},
                {"recovery", "Recovery test"},
                {"models", "Models"},
                {"basics", "Audio basics"},
                {"delay", "Call delay"},
                {"benchmark", "Benchmark"}
              ]
            }
            id={"voice-lab-tab-#{key}"}
            type="button"
            role="tab"
            aria-controls={"voice-lab-panel-#{key}"}
            aria-selected={if key == "listen", do: "true", else: "false"}
            tabindex={if key == "listen", do: "0", else: "-1"}
            data-tab={key}
            class="rounded-md border border-stone-300 px-4 py-2 text-sm font-medium transition hover:bg-stone-100 aria-selected:border-teal-700 aria-selected:bg-teal-700 aria-selected:text-white"
          >
            {label}
          </button>
        </nav>

        <section
          id="voice-lab-panel-listen"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-listen"
          class="space-y-5"
        >
          <div
            id="voice-lab-player-panel"
            class="space-y-4 rounded-lg border border-stone-200 bg-white p-4 sm:p-5"
          >
            <section
              id="voice-lab-results"
              class="grid gap-5 md:grid-cols-2 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_18rem]"
              aria-label="Original and modified audio"
            >
              <article
                :for={version <- ["original", "modified"]}
                id={"voice-lab-result-#{version}"}
                class="min-w-0 space-y-3"
              >
                <h2 data-result-title class="text-lg font-semibold">
                  {if version == "original", do: "Original", else: "Modified"}
                </h2>
                <p data-description class="min-h-12 text-sm text-stone-600">
                  {if version == "original",
                    do: "The sample exactly as it was supplied.",
                    else: "The selected modification, with your settings."}
                </p>
                <button
                  id={if version == "original", do: "voice-lab-play-original", else: "voice-lab-play"}
                  type="button"
                  disabled
                  aria-pressed="false"
                  class="inline-flex items-center gap-2 rounded-md bg-teal-700 px-4 py-2 font-medium text-white transition hover:bg-teal-800 disabled:opacity-50"
                >
                  <span data-play-icon><.icon name="hero-play-solid" class="size-4" /></span>
                  <span data-stop-icon hidden><.icon name="hero-stop-solid" class="size-4" /></span>
                  <span data-play-label>{if version == "original",
                    do: "Play original",
                    else: "Play modified"}</span>
                </button>
                <p data-metrics class="min-h-10 text-sm tabular-nums text-stone-600"></p>
                <figure class="space-y-2">
                  <div class="flex justify-between text-xs text-stone-600">
                    <span>Frequency ↑</span><span>4,000 Hz at top</span>
                  </div>
                  <canvas
                    role="img"
                    aria-label={"#{version} spectrogram: time left to right, frequency bottom to top"}
                    class="h-36 w-full rounded-md bg-stone-950"
                  ></canvas>
                  <figcaption class="flex justify-between text-xs text-stone-600">
                    <span>0 seconds</span><span data-duration>Not prepared yet</span>
                  </figcaption>
                </figure>
              </article>
              <div
                id="voice-lab-playback"
                role="group"
                aria-labelledby="voice-lab-playback-label"
                class="min-w-0 space-y-3 border-t border-stone-200 pt-4 md:col-span-2 lg:col-span-1 lg:border-t-0 lg:border-s lg:ps-5 lg:pt-0"
              >
                <h2 id="voice-lab-playback-label" class="text-sm font-medium">Playback</h2>
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    id="voice-lab-stop"
                    type="button"
                    disabled
                    class="inline-flex items-center gap-2 rounded-md border border-stone-300 px-4 py-2 transition hover:bg-stone-100 disabled:opacity-50"
                  >
                    <.icon name="hero-stop-solid" class="size-4" />
                    <span>Stop</span>
                  </button>
                  <button
                    id="voice-lab-loop"
                    type="button"
                    aria-pressed="false"
                    class="inline-flex items-center gap-2 rounded-md border border-stone-300 px-4 py-2 transition hover:bg-stone-100 aria-pressed:border-teal-700 aria-pressed:bg-teal-700 aria-pressed:text-white"
                  >
                    <.icon name="hero-arrow-path" class="size-4" />
                    <span data-loop-label>Loop off</span>
                  </button>
                </div>
                <button
                  id="voice-lab-play-comparison"
                  type="button"
                  disabled
                  aria-pressed="false"
                  class="inline-flex w-full items-center gap-2 rounded-md border border-stone-300 px-3 py-2 text-sm font-medium transition hover:bg-stone-100 aria-pressed:border-teal-700 aria-pressed:bg-teal-700 aria-pressed:text-white disabled:opacity-50"
                >
                  <span data-play-icon><.icon name="hero-play-solid" class="size-4" /></span>
                  <span data-stop-icon hidden><.icon name="hero-stop-solid" class="size-4" /></span>
                  <span data-play-label>Play original → modified</span>
                </button>
                <div
                  id="voice-lab-controls"
                  class="space-y-3"
                >
                  <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-1">
                    <.input
                      id="voice-lab-source"
                      name="source"
                      value=""
                      type="select"
                      label="Sample"
                      class="w-full rounded-md border border-stone-300 bg-white px-3 py-1.5 text-sm text-stone-950 focus:border-teal-700 focus:outline-2 focus:outline-teal-700"
                      options={[]}
                    />
                    <.input
                      id="voice-lab-processor"
                      name="processor"
                      value="pitch_shift"
                      type="select"
                      label="Modification"
                      class="w-full rounded-md border border-stone-300 bg-white px-3 py-1.5 text-sm text-stone-950 focus:border-teal-700 focus:outline-2 focus:outline-teal-700"
                      options={[
                        {"Gentler pitch · Signalsmith",
                         [
                           {"Gentler · current pitch", "gentle_current_pitch"},
                           {"Gentler · half pitch", "gentle_half_pitch"},
                           {"Gentler · resonance only", "gentle_zero_pitch"}
                         ]},
                        {"Preferred settings · engine comparison",
                         [
                           {"Preferred · Signalsmith", "preferred_spectral"},
                           {"Preferred · WORLD", "preferred_world"}
                         ]},
                        {"Stronger masking · Signalsmith",
                         [
                           {"Signalsmith · more pitch", "spectral_more_pitch"},
                           {"Signalsmith · more resonance", "spectral_more_resonance"},
                           {"Signalsmith · opposing directions", "spectral_opposing"}
                         ]},
                        {"Browser DSP · three approaches",
                         [
                           {"Browser DSP · WORLD pitch + resonance", "browser_world"},
                           {"Browser DSP · Signalsmith pitch + resonance", "browser_spectral"},
                           {"Browser DSP · McAdams + delay-line pitch", "browser_time"}
                         ]},
                        {"WORLD · chunking comparison",
                         [
                           {"WORLD · 40 ms chunks vs whole recording", "world_chunk_40"},
                           {"WORLD · 80 ms chunks vs whole recording", "world_chunk_80"},
                           {"WORLD · 160 ms chunks vs whole recording", "world_chunk_160"}
                         ]},
                        {"Model-free DSP · WORLD",
                         [
                           {"WORLD · unchanged resynthesis control", "world_control"},
                           {"WORLD · pitch only", "world_pitch"},
                           {"WORLD · pitch + resonances", "world_formants"},
                           {"WORLD · pitch + resonances + breathiness", "world_texture"}
                         ]},
                        {"Sound quality check · four public recordings",
                         [
                           {"Sound check · pitch only", "quality_pitch"},
                           {"Sound check · resonance only", "quality_resonance"},
                           {"Sound check · pitch + resonance", "quality_both"},
                           {"Sound check · TVTSyn reference", "quality_tvtsyn"}
                         ]},
                        {"Adjustable DSP",
                         [{"Pitch shift", "pitch_shift"}, {"McAdams (experimental)", "mcadams"}]},
                        {"Earlier experiments",
                         [
                           {"Seed-VC v2 (pre-rendered)", "seed_vc_v2"},
                           {"TVTSyn · browser WASM (pre-rendered)", "tvtsyn_browser"},
                           {"TVTSyn · four-sample comparison", "tvtsyn_native"},
                           {"TVTSyn · INT8 experiment", "tvtsyn_int8"},
                           {"DSP preset · α 0.9, pitch −2", "hybrid_down_2"},
                           {"DSP preset · α 0.9, pitch +2", "hybrid_up_2"},
                           {"DSP preset · α 0.85, pitch −1", "hybrid_mild"}
                         ]}
                      ]}
                    />
                  </div>
                  <div id="voice-lab-params" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-1"></div>
                  <p id="voice-lab-parameter-hint" class="text-sm text-stone-600">
                    Drag, type, or use −/+ to adjust.
                  </p>
                  <p id="voice-lab-processor-note" class="text-sm text-stone-600"></p>
                  <div class="flex flex-wrap items-center gap-3">
                    <span
                      id="voice-lab-status"
                      role="status"
                      class="text-sm text-stone-600"
                      data-state="idle"
                    >Loading samples…</span>
                  </div>
                </div>
              </div>
            </section>
          </div>
          <p class="text-sm text-stone-600">
            Play either version. Only one plays at a time; switching keeps your place.
            The back-to-back button starts the pair from the beginning; Loop repeats the
            pair. Changing a sample, modification or slider stops playback.
          </p>
          <VoiceLabReviews.feedback kind="listen" />
          <details id="voice-lab-sources" class="rounded-lg border border-stone-200 bg-white p-4">
            <summary class="cursor-pointer font-medium">Where do these samples come from?</summary>
            <div class="mt-3 space-y-2 text-sm text-stone-600">
              <p>
                Six-second excerpts from public-domain LibriVox recordings. The first three span low, middle, and high pitches; the fourth is Wasichu’s 2009 Mencken reading:
              </p>
              <ul class="list-disc space-y-1 ps-5">
                <li>
                  Low: NickT0708 reading “Love and Alchemy” by Robert Kennaway Douglas (47–53 seconds).
                </li>
                <li>
                  Middle: Yoganandh T reading “Akin to Love” by Lucy Maud Montgomery (42–48 seconds).
                </li>
                <li>
                  High: Elsie Selwyn reading “Going to Shrewsbury” by Sarah Orne Jewett (21–27 seconds).
                </li>
                <li>
                  Wasichu: “Damn! A Book of Calumny” by H. L. Mencken, part 1 (60–66 seconds), cataloged January 2009.
                </li>
              </ul>
              <p>
                The MP3 excerpts were converted to 24 kHz mono, 16-bit WAV with short fades at the edges. The lab resamples them to 48 kHz for processing; that does not restore frequencies missing from the originals. The test tone is generated here in the browser.
              </p>
              <a
                href="https://librivox.org/short-story-collection-vol-109-by-various/"
                class="underline"
              >Short Story Collection Vol. 109 and reader credits</a>
              <a
                href="https://librivox.org/damn-a-book-of-calumny-by-hl-mencken/"
                class="block underline"
              >Damn! A Book of Calumny, read by Wasichu</a>
            </div>
          </details>
          <details
            id="voice-lab-spectrogram-help"
            class="rounded-lg border border-stone-200 bg-white p-4"
          >
            <summary class="cursor-pointer font-medium">
              What am I looking at in these images?
            </summary>
            <p class="mt-3 max-w-3xl text-sm text-stone-600">
              These are spectrograms: maps of the frequencies in a sound over time.
              Read left to right as the clip plays. Low sounds are near the bottom, high
              sounds near the top; brighter teal means more energy at that frequency.
              Horizontal stripes often show the voice’s repeating vibration and its harmonics.
              Pitch shifting moves those patterns up or down. Each image scales brightness
              separately, so use your ears to compare loudness. A different-looking image
              does not prove that the speaker is anonymous.
            </p>
          </details>
        </section>

        <section
          id="voice-lab-panel-voice"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-voice"
          hidden
        >
          <div class="space-y-5 rounded-lg border border-stone-200 bg-white p-5 sm:p-6">
            <header class="space-y-2">
              <h2 class="text-xl font-semibold">Hear your own voice live</h2>
              <p class="max-w-3xl text-stone-600">
                Speak into your microphone and hear either the original or modified sound through your headphones. Nothing is saved, recorded, or uploaded; there is no replay.
              </p>
            </header>
            <p id="voice-lab-live-headphones" class="max-w-3xl font-medium">
              Use headphones and start with low volume. Speakers can feed the microphone back into itself and produce a loud squeal.
            </p>
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                id="voice-lab-live-mode"
                name="live_mode"
                type="select"
                label="Preview settings"
                value="listen"
                options={[
                  {"From Listen & compare", "listen"},
                  {"Signalsmith / WORLD experiment", "dsp"}
                ]}
              />
            </div>
            <div id="voice-lab-live-dsp-settings" hidden class="space-y-3">
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  id="voice-lab-live-engine"
                  name="live_engine"
                  type="select"
                  label="Engine"
                  value="spectral"
                  options={[{"Signalsmith", "spectral"}, {"WORLD", "world"}]}
                />
                <.input
                  id="voice-lab-live-profile"
                  name="live_profile"
                  type="select"
                  label="Direction and resonance"
                  value="lower_mild"
                  options={[
                    {"Lower · mild resonance (×0.90)", "lower_mild"},
                    {"Lower · stronger resonance (×0.80)", "lower_resonance"},
                    {"Higher · mild resonance (×1.10)", "higher_mild"},
                    {"Higher · stronger resonance (×1.25)", "higher_resonance"}
                  ]}
                />
              </div>
              <.input
                id="voice-lab-live-pitch-strength"
                name="pitch_strength"
                type="select"
                label="Pitch movement"
                value="current_pitch"
                options={[
                  {"Current shift · two semitones", "current_pitch"},
                  {"Half the shift · one semitone", "half_pitch"},
                  {"No pitch shift · resonance retained", "zero_pitch"}
                ]}
              />
              <details
                id="voice-lab-live-buffer-experiment"
                class="rounded-md border border-stone-200 p-3"
              >
                <summary class="cursor-pointer text-sm font-medium">
                  Playback delay experiment
                </summary>
                <div class="mt-3 space-y-2">
                  <.input
                    id="voice-lab-live-buffering"
                    name="buffering"
                    type="select"
                    label="Playback buffering"
                    value="baseline"
                    disabled={not @short_buffer_ready}
                    data-short-ready={to_string(@short_buffer_ready)}
                    options={[
                      {"Current · more buffering margin", "baseline"},
                      {"Shorter delay · experimental", "short"}
                    ]}
                  />
                  <p :if={@short_buffer_ready} class="text-sm text-stone-600">
                    Both local one-minute tests completed without interruptions: current {VoiceLabRound.buffer_delay(
                      @buffering_report,
                      "baseline"
                    )}, shorter {VoiceLabRound.buffer_delay(@buffering_report, "short")}, before device delay. Shorter has less spare buffering; other devices may stop. Current remains the default. Signalsmith only.
                  </p>
                  <p :if={not @short_buffer_ready} class="text-sm text-stone-600">
                    The shorter setting is unavailable until <code>just voice-dsp-buffering</code>
                    passes with this build. Current buffering remains available.
                  </p>
                </div>
              </details>
              <p class="text-sm text-stone-600">
                An experimental, delayed headphone monitor. Choose a profile by ear; changing settings stops the microphone. Input uses fixed headroom, without the recorded comparisons’ level matching. An overloaded processor stops visibly instead of playing your original voice.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <button
                :for={version <- ["original", "modified"]}
                id={"voice-lab-live-#{version}"}
                type="button"
                disabled
                aria-pressed="false"
                aria-describedby="voice-lab-live-headphones"
                class="inline-flex items-center gap-2 rounded-md bg-teal-700 px-4 py-2 font-medium text-white transition hover:bg-teal-800 disabled:opacity-50"
              >
                <span data-live-play-icon><.icon name="hero-play-solid" class="size-4" /></span>
                <span data-live-stop-icon hidden><.icon name="hero-stop-solid" class="size-4" /></span>
                <span data-live-label>{if version == "original",
                  do: "Hear original",
                  else: "Hear modified"}</span>
              </button>
              <button
                id="voice-lab-live-stop"
                type="button"
                disabled
                class="inline-flex items-center gap-2 rounded-md border border-stone-300 px-4 py-2 transition hover:bg-stone-100 disabled:opacity-50"
              >
                <.icon name="hero-stop-solid" class="size-4" /> Stop microphone
              </button>
            </div>
            <p
              id="voice-lab-live-status"
              role="status"
              data-state="idle"
              class="text-sm text-stone-600"
            >
              Microphone off. Choose a version to start; your browser will ask for permission.
            </p>
            <p id="voice-lab-live-dsp-metrics" role="status" hidden class="text-sm text-stone-600">
            </p>
            <div class="space-y-2">
              <p id="voice-lab-live-settings" class="text-sm text-stone-600"></p>
              <button id="voice-lab-live-settings-link" type="button" class="text-sm underline">Change pitch settings in Listen & compare</button>
            </div>
            <p class="max-w-3xl text-sm text-stone-600">
              Switching versions keeps the same microphone open. Stop or leave this tab to close it. This preview uses the call’s microphone settings, including echo cancellation, noise suppression, and automatic gain where supported. It includes local playback delay but no network or remote listener.
            </p>
          </div>
        </section>
        <section
          id="voice-lab-panel-basics"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-basics"
          hidden
        >
          <VoiceLabGuide.basics />
        </section>
        <section
          id="voice-lab-panel-delay"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-delay"
          hidden
        >
          <VoiceLabGuide.delay />
        </section>
        <section
          id="voice-lab-panel-benchmark"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-benchmark"
          hidden
        >
          <VoiceLabBenchmark.section report={@benchmark} />
        </section>
        <section
          id="voice-lab-panel-recovery"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-recovery"
          hidden
        >
          <VoiceLabRecovery.section report={@recovery} />
        </section>
        <section
          id="voice-lab-panel-gentle"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-gentle"
          hidden
        >
          <VoiceLabRound.section id="gentle" report={@gentle_pitch} />
        </section>
        <section
          id="voice-lab-panel-engines"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-engines"
          hidden
        >
          <VoiceLabRound.section id="engines" report={@engine_comparison} />
        </section>
        <section
          id="voice-lab-panel-round"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-round"
          hidden
        >
          <VoiceLabRound.section report={@masking_round} />
        </section>
        <section
          id="voice-lab-panel-models"
          role="tabpanel"
          aria-labelledby="voice-lab-tab-models"
          hidden
        >
          <VoiceLabModels.section report={@model_experiment} />
        </section>
      </div>
    </Layouts.app>
    """
  end
end
