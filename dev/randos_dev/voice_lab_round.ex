defmodule RandosDev.VoiceLabRound do
  @moduledoc "One bounded Signalsmith strength audition; no production processor selection."
  use RandosWeb, :html

  @path Path.expand("../../tools/voice-dsp/results/masking-round.json", __DIR__)

  @engines Path.expand("../../tools/voice-dsp/results/engine-comparison.json", __DIR__)

  @gentle Path.expand("../../tools/voice-dsp/results/gentle-pitch.json", __DIR__)
  @buffering Path.expand("../../tools/voice-dsp/results/buffering.json", __DIR__)
  @root Path.expand("../..", __DIR__)

  def load(kind \\ "round") do
    {path, expected} =
      case kind do
        "engines" -> {@engines, 3}
        "gentle" -> {@gentle, 4}
        _ -> {@path, 5}
      end

    with {:ok, body} <- File.read(path),
         {:ok, %{"variants" => variants, "cases" => cases} = report}
         when is_list(variants) and is_map(cases) <- JSON.decode(body),
         true <- length(variants) == expected and map_size(cases) == 5 do
      report
    else
      _missing -> nil
    end
  end

  def buffering do
    with {:ok, body} <- File.read(@buffering),
         {:ok, %{"completed" => true} = report} <- JSON.decode(body) do
      sources =
        ~w(assets/js/voice_lab/dsp/bridge_worklet.js assets/js/voice_lab/dsp/worker.js assets/js/voice_lab/dsp/adapter.js assets/js/randos/voice/dsp_adapter.js assets/js/randos/voice/dsp_bridge.js assets/vendor/voice_dsp/manifest.json test/e2e/dsp_stream_fixture.mjs tools/voice-dsp/browser/buffering.mjs config/config.exs)

      fresh =
        Enum.all?(sources, fn path ->
          case File.read(Path.join(@root, path)) do
            {:ok, bytes} ->
              Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
                get_in(report, ["provenance", path])

            _ ->
              false
          end
        end)

      assets_fresh =
        Enum.all?(~w(dsp_worker.js dsp_bridge.js), fn name ->
          expected = get_in(report, ["executed_assets", name, "sha256"])

          is_binary(expected) and
            digest_path("priv/static/assets/js/voice_lab/" <> name) == expected
        end)

      Map.put(report, "fresh", fresh and assets_fresh and vendor_fresh?())
    else
      _ -> nil
    end
  end

  defp digest_path(path) do
    case File.read(Path.join(@root, path)) do
      {:ok, bytes} -> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      _ -> nil
    end
  end

  defp vendor_fresh? do
    with {:ok, bytes} <- File.read(Path.join(@root, "assets/vendor/voice_dsp/manifest.json")),
         {:ok, manifest} when is_map(manifest) <- JSON.decode(bytes) do
      binaries =
        Enum.all?(~w(world.mjs world.wasm spectral.mjs spectral.wasm), fn name ->
          expected = get_in(manifest, ["files", name])
          is_binary(expected) and digest_path("assets/vendor/voice_dsp/" <> name) == expected
        end)

      wrappers =
        Enum.all?(~w(world.cpp spectral.cpp), fn name ->
          expected = get_in(manifest, ["wrappers", name])
          is_binary(expected) and digest_path("tools/voice-dsp/browser/" <> name) == expected
        end)

      binaries and wrappers and is_binary(manifest["pins_sha256"]) and
        digest_path("tools/voice-dsp/browser/sources.json") == manifest["pins_sha256"]
    else
      _ -> false
    end
  end

  def short_buffer_ready?(report) do
    is_map(report) and report["fresh"] == true and report["short_available"] == true and
      Enum.all?(~w(baseline short), fn name ->
        get_in(report, ["trials", name, "fixture_pass"]) == true and
          get_in(report, ["trials", name, "sustained_pass"]) == true
      end)
  end

  def buffer_delay(report, mode) do
    case get_in(report || %{}, ["trials", mode, "summary", "delay_ms"]) do
      value when is_number(value) -> "#{round(value)} ms"
      _ -> "not completed"
    end
  end

  attr :id, :string, default: "round"
  attr :report, :map, default: nil

  def section(%{report: nil} = assigns) do
    ~H"""
    <p id={"voice-lab-#{@id}-missing"} class="rounded-lg border border-stone-200 p-5 text-sm">
      Run
      <code>{case @id do
        "engines" -> "just voice-dsp-engines"
        "gentle" -> "just voice-dsp-gentle"
        _ -> "just voice-dsp-round"
      end}</code>
      to prepare this comparison, then reload.
    </p>
    """
  end

  def section(assigns) do
    assigns =
      assigns
      |> assign(
        :count_word,
        Map.fetch!(%{"engines" => "three", "gentle" => "four", "round" => "five"}, assigns.id)
      )
      |> assign(
        :engine_choices,
        case assigns.id do
          "engines" ->
            [{"Signalsmith", "spectral"}, {"WORLD", "world"}, {"Neither is useful", "none"}]

          "gentle" ->
            [
              {"Current pitch shift", "current_pitch"},
              {"Half the pitch shift", "half_pitch"},
              {"No pitch shift · resonance retained", "zero_pitch"},
              {"None is useful", "none"}
            ]

          _ ->
            []
        end
      )

    ~H"""
    <div id={"voice-lab-#{@id}"} data-round={JSON.encode!(@report)} class="space-y-4">
      <header class="space-y-2">
        <h2 class="text-xl font-semibold">
          {@report["title"] || "How much masking still sounds good?"}
        </h2>
        <p class="max-w-3xl text-sm text-stone-600">
          {@report["intro"] ||
            "Compare the current Signalsmith voice with three stronger changes. Pick the best balance of disguise, naturalness and clear speech. “None is useful” is useful feedback too."}
        </p>
      </header>
      <div class="grid items-start gap-4 lg:grid-cols-[minmax(0,1fr)_22rem]">
        <div class="space-y-3 rounded-lg border border-stone-200 bg-white p-4">
          <div class="flex flex-wrap items-end gap-3">
            <div class="min-w-48 flex-1">
              <.input
                id={"voice-lab-#{@id}-source"}
                name="round_source"
                type="select"
                label="Sample"
                value=""
                options={[]}
              />
            </div>
            <button
              id={"voice-lab-#{@id}-all"}
              type="button"
              disabled
              aria-pressed="false"
              class="inline-flex items-center gap-2 rounded-md bg-teal-700 px-3 py-2 text-sm font-medium text-white transition hover:bg-teal-800 disabled:opacity-50"
            >
              <span data-play-icon><.icon name="hero-play-solid" class="size-4" /></span>
              <span data-stop-icon hidden><.icon name="hero-stop-solid" class="size-4" /></span>
              <span data-play-label>Play all {@count_word}</span>
            </button>
            <button
              id={"voice-lab-#{@id}-stop"}
              type="button"
              disabled
              class="inline-flex items-center gap-2 rounded-md border border-stone-300 px-3 py-2 text-sm transition hover:bg-stone-100 dark:hover:bg-stone-800 disabled:opacity-50"
            >
              <.icon name="hero-stop-solid" class="size-4" /> Stop
            </button>
            <label class="flex items-center gap-2 py-2 text-sm"><input
              id={"voice-lab-#{@id}-loop"}
              type="checkbox"
              class="accent-teal-700"
            /> Loop</label>
          </div>
          <p
            id={"voice-lab-#{@id}-note"}
            data-round-note
            hidden
            class="text-sm font-medium text-stone-700"
          >
          </p>
          <p
            id={"voice-lab-#{@id}-status"}
            role="status"
            data-state="loading"
            class="min-h-6 text-sm text-stone-600"
          >
            Preparing the comparison…
          </p>
          <div class="divide-y divide-stone-200 dark:divide-stone-700">
            <article
              :for={variant <- @report["variants"]}
              id={"voice-lab-#{@id}-row-#{variant["id"]}"}
              data-round-row={variant["id"]}
              data-active="false"
              class="flex items-center gap-3 rounded-md p-3 transition data-[active=true]:bg-teal-50 dark:data-[active=true]:bg-teal-950"
            >
              <button
                id={"voice-lab-#{@id}-play-#{variant["id"]}"}
                type="button"
                data-round-play={variant["id"]}
                disabled
                aria-pressed="false"
                aria-label={"Play #{variant["label"]}"}
                class="flex size-10 shrink-0 items-center justify-center rounded-full border border-stone-300 transition hover:bg-stone-100 dark:hover:bg-stone-800 disabled:opacity-50"
              >
                <span data-play-icon><.icon name="hero-play-solid" class="size-4" /></span>
                <span data-stop-icon hidden><.icon name="hero-stop-solid" class="size-4" /></span>
              </button>
              <div class="min-w-0 flex-1">
                <h3 class="text-sm font-semibold">{variant["label"]}</h3><p
                  data-round-description
                  class="text-xs text-stone-600"
                >
                </p>
              </div>
              <canvas
                id={"voice-lab-#{@id}-wave-#{variant["id"]}"}
                data-round-wave
                width="144"
                height="32"
                aria-hidden="true"
                class="hidden h-8 w-36 shrink-0 sm:block"
              ></canvas>
              <button
                :if={@id in ["engines", "gentle"] and variant["id"] != "original"}
                type="button"
                id={"voice-lab-#{@id}-live-#{variant["id"]}"}
                data-round-live={variant["id"]}
                disabled
                class="shrink-0 rounded-md border border-stone-300 px-2 py-1 text-xs hover:bg-stone-100 dark:hover:bg-stone-800 disabled:opacity-50"
              >Use live</button>
            </article>
          </div>
          <p class="text-xs text-stone-500">
            Play all follows this order, with a quarter-second pause between clips and at the loop boundary. Levels are matched across all {@count_word} versions. Waveforms share an amplitude scale; they do not measure masking strength.
          </p>
        </div>
        <div class="space-y-3">
          <RandosDev.VoiceLabReviews.feedback
            kind={@id}
            preference
            preference_choices={@engine_choices}
            voices={[{"comparison", "Choose one for this sample"}]}
            notes_placeholder="Optional: what sounds clearer, more disguised, nasal or artificial?"
          />
          <details class="rounded-lg border border-stone-200 p-4 text-sm text-stone-600">
            <summary class="cursor-pointer font-medium">What changed in this round?</summary>
            <p :for={text <- @report["details"] || []} class="mt-3">{text}</p>
            <div :if={@id == "round"}>
              <p class="mt-3">
                More pitch increases the shift from two to four semitones. More resonance keeps the current pitch shift and moves resonances further. Opposing directions uses a three-semitone shift and moves resonances the other way; it changes two things together.
              </p>
              <p class="mt-3">
                High/mid voices move down in pitch; low voice and Wasichu move up. Exact settings appear beside each recording. The test tone checks artifacts, not whether a person is disguised.
              </p>
              <p class="mt-3">
                These are browser-produced listening samples. Existing small native/browser differences on synthetic impulses remain unresolved. This round adds no performance measurement or privacy guarantee.
              </p>
            </div>
          </details>
        </div>
      </div>
    </div>
    """
  end
end
