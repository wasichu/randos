defmodule RandosDev.VoiceLabRecovery do
  @moduledoc "Dev-only listening review of the public-clip approximate recovery probe."
  use RandosWeb, :html

  @path Path.expand("../../tools/voice-eval/results/reconstruction.json", __DIR__)

  def load do
    with {:ok, body} <- File.read(@path),
         {:ok, %{"results" => results} = report} when is_list(results) and results != [] <-
           JSON.decode(body) do
      report
    else
      _missing -> nil
    end
  end

  attr :report, :map, default: nil

  def section(%{report: nil} = assigns) do
    ~H"""
    <section id="voice-lab-recovery" class="rounded-lg border border-stone-200 bg-white p-5">
      <h2 class="text-lg font-semibold">Recovery test</h2>
      <p class="mt-2 text-sm text-stone-600">
        Run <code>just voice-recovery</code> to prepare comparisons from the four public
        listening samples, then reload. No microphone recordings are used.
      </p>
    </section>
    """
  end

  def section(assigns) do
    ~H"""
    <section id="voice-lab-recovery" class="space-y-4 rounded-lg border border-stone-200 bg-white p-5">
      <h2 class="text-lg font-semibold">Recovery test: can the original voice be approximated?</h2>
      <p class="max-w-3xl text-sm text-stone-600">
        The attacker receives only the disguised audio and its known processing setting.
        It estimates a new vocal-tract model and tries reversing the resonance change.
        The original is used only for comparison. This is one approximate attack, not
        a test of every possible reconstruction method.
      </p>
      <div class="flex flex-wrap items-end gap-4">
        <.input
          id="voice-lab-recovery-choice"
          name="recovery_choice"
          type="select"
          label="Recording and disguise setting"
          value={hd(@report["results"])["id"]}
          options={
            Enum.map(
              @report["results"],
              &{"#{String.replace(&1["clip"], "_", " ")} · α=#{&1["alpha"]}", &1["id"]}
            )
          }
        />
        <button
          id="voice-lab-recovery-play-all"
          type="button"
          aria-pressed="false"
          class="inline-flex items-center gap-2 rounded-md bg-teal-700 px-4 py-2 text-sm font-medium text-white transition hover:bg-teal-800"
        >
          <span data-play-icon><.icon name="hero-play-solid" class="size-4" /></span>
          <span data-stop-icon hidden><.icon name="hero-stop-solid" class="size-4" /></span>
          <span data-play-label>Play all: original → disguised → recovered</span>
        </button>
        <button
          id="voice-lab-recovery-stop"
          type="button"
          class="inline-flex items-center gap-2 rounded-md border border-stone-300 px-4 py-2 text-sm hover:bg-stone-100"
        >
          <.icon name="hero-stop-solid" class="size-4" /> Stop
        </button>
        <label class="flex items-center gap-2 py-2 text-sm">
          <input id="voice-lab-recovery-loop" type="checkbox" class="accent-teal-700" /> Loop playback
        </label>
      </div>
      <p
        id="voice-lab-recovery-playback-status"
        role="status"
        data-state="idle"
        class="text-sm text-stone-600"
      >
      </p>
      <article
        :for={{result, index} <- Enum.with_index(@report["results"])}
        id={"voice-lab-recovery-#{result["id"]}"}
        data-recovery-case={result["id"]}
        data-review-context={
          JSON.encode!(%{
            view: "recovery",
            mode: "approximate_inverse_capped",
            build_id: @report["renderer_sha256"],
            source_id: result["source_sha256"],
            sample: result["clip"],
            processor: "mcadams",
            parameters: %{alpha: result["alpha"]},
            run_id: @report["generated_at"],
            headroom: @report["headroom"],
            case_id: result["id"]
          })
        }
        hidden={index != 0}
        class="space-y-4"
      >
        <div class="grid gap-4 md:grid-cols-3">
          <.player
            :for={
              {key, label} <- [
                {"original", "Original"},
                {"disguised", "Disguised"},
                {"recovered", "Approximate recovery, known setting"}
              ]
            }
            result={result}
            version={key}
            label={label}
          />
        </div>
        <p class="text-sm text-stone-600">
          Does recovery sound closer to the original person's voice? Separately, is it
          natural and easy to understand? Matching a speaker model is not evidence that
          the original sound has been recovered. Only one clip plays at a time.
        </p>
        <details class="rounded-md border border-stone-200 p-3 text-sm text-stone-600">
          <summary class="cursor-pointer font-medium">Controls and processing diagnostics</summary>
          <div class="mt-3 grid gap-4 md:grid-cols-2">
            <.player
              result={result}
              version="sham"
              label="Sham recovery: disguised → unchanged processing"
            />
            <.player
              result={result}
              version="control"
              label="Bandwidth control: original → unchanged processing twice"
            />
          </div>
          <p class="mt-3">
            Every comparison starts from an original scaled once by 0.25 for headroom; no recovery
            setting or gain is fitted to the original. Each pass flushes and removes
            its known 21.3 ms delay for aligned comparison. These clips do not follow
            the sliders in Listen &amp; compare.
          </p>
          <div class="mt-3 overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr>
                  <th class="pe-3">Pass</th><th class="pe-3">Failed frames</th><th class="pe-3">
                    Clipped samples
                  </th><th>Frames with capped pole angles</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={
                  {key, label} <- [
                    {"forward", "Disguise"},
                    {"inverse", "Recovery"},
                    {"sham", "Sham"},
                    {"control_second", "Second control pass"}
                  ]
                }>
                  <td class="pe-3">{label}</td><td>{result["processing"][key]["failed_frames"]}</td>
                  <td>{result["processing"][key]["clipped_samples"]}</td>
                  <td>
                    {result["processing"][key]["corrected_frames"]} / {result["processing"][key][
                      "frames"
                    ]}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="mt-3">
            Reestimated poles can fall outside the forward transform's range. The inverse
            caps their angles just below π instead of folding them back into the spectrum;
            the counts above expose this approximation. A broken attack is inconclusive,
            not evidence that the disguise resists reconstruction.
          </p>
          <p class="mt-3">
            Log-spectrum distance to original (dB): disguised {result["spectral_distance_db"][
              "disguised"
            ]},
            recovery {result["spectral_distance_db"]["recovered"]}, sham {result[
              "spectral_distance_db"
            ]["sham"]},
            bandwidth control {result["spectral_distance_db"]["control"]}.
            Lower is closer numerically; this is not a naturalness or identity score.
          </p>
        </details>
      </article>
      <RandosDev.VoiceLabReviews.feedback
        kind="recovery"
        voices={[{"disguised", "Disguised voice"}, {"recovered", "Recovered voice"}]}
      />
      <p class="text-xs text-stone-500">
        Generated {@report["generated_at"]} from the four bundled LibriVox excerpts.
        Audio is generated locally under <code>tmp/voice-recovery</code>; regenerate
        with <code>just voice-recovery</code> if files are missing.
      </p>
    </section>
    """
  end

  attr :result, :map, required: true
  attr :version, :string, required: true
  attr :label, :string, required: true

  defp player(assigns) do
    ~H"""
    <div class="min-w-0 space-y-2">
      <h3
        id={"recovery-#{@result["id"]}-#{@version}-label"}
        class="text-sm font-medium text-stone-950"
      >
        {@label}
      </h3>
      <audio
        id={"recovery-#{@result["id"]}-#{@version}"}
        data-recovery-audio
        data-recovery-version={@version}
        controls
        preload="none"
        aria-labelledby={"recovery-#{@result["id"]}-#{@version}-label"}
        class="w-full"
      >
        <source src={"/dev/voice-lab/recovery/#{@result["audio"][@version]}"} type="audio/wav" />
      </audio>
    </div>
    """
  end
end
