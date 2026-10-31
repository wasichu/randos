defmodule RandosDev.VoiceLabModels do
  @moduledoc "Dev-only listening results from isolated, offline audio experiments."
  use RandosWeb, :html

  @path Path.expand("../../tools/voice-model/results/seed-vc-v2.json", __DIR__)
  @browser_audio Path.expand("../../tools/voice-browser/results/listening.json", __DIR__)
  @comparisons Path.expand("../../tools/voice-browser/results/comparisons.json", __DIR__)
  @sound_quality Path.expand("../../tools/voice-browser/results/sound-quality.json", __DIR__)
  @dsp_audio Path.expand("../../tools/voice-dsp/results/listening.json", __DIR__)
  @tone_audio Path.expand("../../tools/voice-browser/results/tone.json", __DIR__)
  @gentle_pitch Path.expand("../../tools/voice-dsp/results/gentle-pitch.json", __DIR__)
  @envelope Path.expand("../../tools/voice-dsp/results/selective-resonance.json", __DIR__)
  @bandwidth Path.expand("../../tools/voice-dsp/results/bandwidth.json", __DIR__)
  @source_shape Path.expand("../../tools/voice-dsp/results/source.json", __DIR__)
  @fargan Path.expand("../../tools/voice-fargan/results/quality.json", __DIR__)
  @fargan_mask Path.expand("../../tools/voice-fargan/results/masking.json", __DIR__)
  @fargan_combined Path.expand("../../tools/voice-fargan/results/combined.json", __DIR__)
  @engine_comparison Path.expand("../../tools/voice-dsp/results/engine-comparison.json", __DIR__)
  @masking_round Path.expand("../../tools/voice-dsp/results/masking-round.json", __DIR__)
  @browser_dsp Path.expand("../../tools/voice-dsp/results/browser-listening.json", __DIR__)
  @chunked_audio Path.expand("../../tools/voice-dsp/results/chunked.json", __DIR__)
  @browser_additional Path.expand(
                        "../../tools/voice-browser/results/browser-listening.json",
                        __DIR__
                      )

  def seed_context(report, result) do
    %{
      view: "model",
      mode: "average_voice_style",
      processor: "seed_vc_v2",
      build_id: report["build_id"],
      source_id: result["source_sha256"],
      sample: result["clip"],
      run_id: report["generated_at"],
      case_id: result["id"]
    }
  end

  def listening_data(seed, browser_path \\ @browser_audio) do
    seed_cases =
      for result <- (seed && seed["results"]) || [], result["status"] == "ready", into: %{} do
        {result["clip"] <> ".wav", %{audio: result["audio"], context: seed_context(seed, result)}}
      end

    browser_cases =
      with {:ok, body} <- File.read(browser_path),
           {:ok, %{"clip" => clip, "audio" => audio, "provider" => "wasm"} = item} <-
             JSON.decode(body) do
        %{
          (clip <> ".wav") => %{
            audio: audio,
            context: %{
              view: "model",
              mode: "browser_wasm",
              processor: "tvtsyn_browser",
              build_id: item["build_id"],
              source_id: item["source_sha256"],
              sample: clip,
              run_id: item["generated_at"],
              case_id: clip
            }
          }
        }
      else
        _missing -> %{}
      end

    base = %{"seed_vc_v2" => seed_cases, "tvtsyn_browser" => browser_cases}

    Enum.reduce(
      [
        @browser_additional,
        @comparisons,
        @sound_quality,
        @dsp_audio,
        @tone_audio,
        @chunked_audio,
        @browser_dsp,
        @masking_round,
        @engine_comparison,
        @gentle_pitch,
        @envelope,
        @bandwidth,
        @source_shape,
        @fargan,
        @fargan_mask,
        @fargan_combined
      ],
      base,
      &merge_candidates/2
    )
  end

  defp merge_candidates(path, base) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"candidates" => candidates}} when is_map(candidates) <- JSON.decode(body) do
      Map.merge(base, candidates, fn _processor, old, new -> Map.merge(old, new) end)
    else
      _missing -> base
    end
  end

  def load do
    with {:ok, body} <- File.read(@path),
         {:ok, %{"results" => [_ | _]} = report} <- JSON.decode(body) do
      report
    else
      _missing -> nil
    end
  end

  attr :report, :map, default: nil

  def section(%{report: nil} = assigns) do
    ~H"""
    <section id="voice-lab-models" class="rounded-lg border border-stone-200 bg-white p-5">
      <h2 class="text-lg font-semibold">Pretrained model experiment</h2>
      <p class="mt-2 text-sm text-stone-600">
        Run <code>just voice-model</code> to prepare the four public-clip comparisons, then reload.
        This isolated offline experiment downloads model weights; it never uses microphone audio.
      </p>
    </section>
    """
  end

  def section(assigns) do
    ~H"""
    <section id="voice-lab-models" class="space-y-4 rounded-lg border border-stone-200 bg-white p-5">
      <header class="space-y-2">
        <p class="text-sm">
          <a
            id="voice-lab-browser-report"
            href="/dev/voice-lab/browser-probe"
            class="text-teal-700 underline"
          >
            Open TVTSyn browser feasibility: timings and listening comparison
          </a>
        </p>
        <h2 class="text-lg font-semibold">Seed-VC v2: rebuild speech with a different voice</h2>
        <p class="max-w-3xl text-sm text-stone-600">
          Instead of warping the original resonances, this pretrained model compresses speech
          into content tokens and generates new speech. This run enables style regeneration
          and the model's “average voice” mode. It does not try to imitate a chosen person.
        </p>
        <p class="max-w-3xl text-sm text-stone-600">
          Listen for naturalness, clear words, and resemblance to the original person.
          Also note changed words, pronunciation, accent, pauses or emotion. This is an offline
          sound experiment: recovery resistance, speaker matching and live browser performance
          have not been tested for this model.
        </p>
      </header>
      <div class="flex flex-wrap items-end gap-4">
        <.input
          id="voice-lab-model-choice"
          name="model_choice"
          type="select"
          label="Sample"
          value={hd(@report["results"])["id"]}
          options={Enum.map(@report["results"], &{String.replace(&1["clip"], "_", " "), &1["id"]})}
        />
        <button
          id="voice-lab-model-play-all"
          type="button"
          aria-pressed="false"
          class="inline-flex items-center gap-2 rounded-md bg-teal-700 px-4 py-2 text-sm font-medium text-white transition hover:bg-teal-800"
        >
          <span data-play-icon><.icon name="hero-play-solid" class="size-4" /></span>
          <span data-stop-icon hidden><.icon name="hero-stop-solid" class="size-4" /></span>
          <span data-play-label>Play original → converted</span>
        </button>
        <label class="flex items-center gap-2 py-2 text-sm">
          <input id="voice-lab-model-loop" type="checkbox" class="accent-teal-700" /> Loop playback
        </label>
      </div>
      <p id="voice-lab-model-status" role="status" class="text-sm text-stone-600"></p>
      <article
        :for={{result, index} <- Enum.with_index(@report["results"])}
        id={"voice-lab-model-#{result["id"]}"}
        data-model-case={result["id"]}
        data-ready={to_string(result["status"] == "ready")}
        data-review-context={JSON.encode!(seed_context(@report, result))}
        hidden={index != 0}
        class="space-y-4"
      >
        <%= if result["status"] == "ready" do %>
          <div class="grid gap-4 md:grid-cols-2">
            <div
              :for={
                {key, label} <- [{"original", "Original"}, {"converted", "Converted · Seed-VC v2"}]
              }
              class="min-w-0 space-y-2"
            >
              <h3 id={"model-#{result["id"]}-#{key}-label"} class="text-sm font-medium">{label}</h3>
              <audio
                id={"model-#{result["id"]}-#{key}"}
                data-recovery-audio
                controls
                preload="none"
                aria-labelledby={"model-#{result["id"]}-#{key}-label"}
                class="w-full"
              >
                <source src={"/dev/voice-lab/models/#{result["audio"][key]}"} type="audio/wav" />
              </audio>
            </div>
          </div>
          <p class="text-sm text-stone-600">
            {Float.round(result["input_seconds"], 2)} s input → {Float.round(
              result["output_seconds"],
              2
            )} s output; {Float.round(result["inference_seconds"], 2)} s to generate this clip
            ({if index == 0, do: "first inference, includes warm-up", else: "model already loaded"}).
            This is whole-clip processing time, not added call delay. {result[
              "samples_at_unit_boundary"
            ]} output samples reached the vocoder's ±1 limit; {result["listening_clipped_samples"]} clipped during listening export.
          </p>
        <% else %>
          <p class="text-sm text-red-700 dark:text-red-400">
            This sample did not complete: {result["error"] || result["status"]}. Its failure is retained in the report.
          </p>
        <% end %>
      </article>
      <RandosDev.VoiceLabReviews.feedback
        kind="model"
        voices={[{"disguised", "Converted voice"}]}
        notes_placeholder="Did words, pronunciation, accent or emotion change? Does it still resemble the original person?"
      />
      <details class="rounded-md border border-stone-200 p-3 text-sm text-stone-600">
        <summary class="cursor-pointer font-medium">What ran, and what remains unknown</summary>
        <p class="mt-3">
          One fixed configuration across all four samples: 30 diffusion steps, style regeneration
          on, anonymization-only on, seed {@report["seed"]}. Device: {@report["device"]};
          dtype: {@report["dtype"]}. Each displayed recording is scaled by {@report["listen_gain"]} for listening headroom; no per-clip loudness matching or trimming is applied.
        </p>
        <p class="mt-3">
          The upstream wrapper still processes a fixed mid-voice reference, even in average-voice
          mode. Speaker-style and acoustic-prompt conditioning are cleared, but reference
          content still reaches the generator: reference independence has not been verified.
          Its output streaming
          reads the entire input first. This does not establish real-time or browser feasibility.
          Code and weights remain separate from the application under ignored local storage.
        </p>
        <p class="mt-3">
          Seed-VC and its weights are GPL-licensed. This is a research candidate, not a selected
          production dependency. Exact model revisions, hashes, settings and diagnostics live in <code>tools/voice-model/results/seed-vc-v2.json</code>. <a
            href="https://github.com/Plachtaa/seed-vc"
            class="text-teal-700 underline"
          >Upstream model</a>.
        </p>
        <p class="mt-3">
          Generated {@report["generated_at"]}. Run <code>just voice-model</code>
          to regenerate missing audio.
        </p>
      </details>
    </section>
    """
  end
end
