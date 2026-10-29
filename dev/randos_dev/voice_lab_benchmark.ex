defmodule RandosDev.VoiceLabBenchmark do
  @moduledoc """
  The voice lab's benchmark: `tools/voice-eval/results/benchmark.json`,
  written by `just voice-eval` (whether ECAPA-TDNN can still identify a
  speaker after each processor setting, and Whisper's word error rate), and
  the section of the lab that shows it. Read when the lab loads; without a
  file, the section says how to run it.
  """
  use Phoenix.Component

  @path Path.expand("../../tools/voice-eval/results/benchmark.json", __DIR__)

  @doc "The latest results, or `nil` when the benchmark hasn't run."
  @spec load(Path.t()) :: map() | nil
  def load(path \\ @path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"results" => results} = report} when is_list(results) <- JSON.decode(body) do
      report
    else
      _missing_or_malformed -> nil
    end
  end

  @doc "A rate (0..1) as a whole percentage, or a dash."
  @spec percent(number() | nil) :: String.t()
  def percent(rate) when is_number(rate), do: "#{round(rate * 100)}%"
  def percent(_rate), do: "–"

  defp search(result, metric),
    do: Map.get(result, "#{metric}_adaptive", result["#{metric}_undo"])

  attr :report, :map, default: nil

  @doc "The lab's Benchmark section, from `load/1`'s report."
  def section(%{report: nil} = assigns) do
    ~H"""
    <section id="voice-lab-benchmark" class="space-y-4" data-state="none">
      <div class="rounded-lg border border-stone-200 bg-white p-5 text-sm text-stone-600">
        <h2 class="mb-1 text-lg font-semibold tracking-normal text-stone-950">Benchmark</h2>
        Not run yet: <code>just voice-eval</code>
        measures whether a speaker can still be identified after each processor.
      </div>
    </section>
    """
  end

  def section(assigns) do
    ~H"""
    <section id="voice-lab-benchmark" class="space-y-4" data-state="ready">
      <div class="space-y-4 rounded-lg border border-stone-200 bg-white p-5">
        <h2 id="voice-lab-benchmark-title" class="text-lg font-semibold tracking-normal">
          Benchmark: can you still be recognized?
        </h2>
        <div class="overflow-x-auto">
          <table class="w-full text-left text-sm">
            <thead class="text-stone-500">
              <tr>
                <th class="py-2 pe-4 font-medium">Processor</th>
                <th class="py-2 pe-4 font-medium">EER, original references</th>
                <th class="py-2 pe-4 font-medium">EER, matching settings</th>
                <th class="py-2 pe-4 font-medium">EER, search attack</th>
                <th class="py-2 pe-4 font-medium">Recognized: matching / search</th>
                <th class="py-2 pe-4 font-medium">Word error rate</th>
                <th class="py-2 font-medium">Finding in this test</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-stone-200">
              <tr
                :for={result <- @report["results"]}
                id={"voice-lab-benchmark-#{result["id"]}"}
                data-verdict={result["verdict"]["kind"]}
              >
                <td class="py-2 pe-4 font-medium">{result["label"]}</td>
                <td class="py-2 pe-4 tabular-nums">{percent(result["eer_ignorant"])}</td>
                <td class="py-2 pe-4 tabular-nums">{percent(result["eer_informed"])}</td>
                <td class="py-2 pe-4 tabular-nums">{percent(search(result, "eer"))}</td>
                <td class="py-2 pe-4 tabular-nums">
                  {percent(result["identification_informed"])} / {percent(
                    search(result, "identification")
                  )}
                </td>
                <td class="py-2 pe-4 tabular-nums">{percent(result["wer"])}</td>
                <td class="min-w-64 py-2 text-stone-700">
                  {result["verdict"]["text"]}
                  <details
                    :if={result["processing"]}
                    id={"voice-lab-benchmark-diagnostics-#{result["id"]}"}
                    class="mt-2 text-xs text-stone-600"
                  >
                    <summary class="cursor-pointer">Processing details</summary>
                    <p class="mt-1">
                      Trial audio: {result["processing"]["failed_frames"]} failed frames, {result[
                        "processing"
                      ]["clipped_samples"]} clipped samples.
                      Slowest measured native block: {Float.round(
                        result["processing"]["worst_block_ms"] * 1.0,
                        3
                      )} ms
                      (128 samples allow 2.67 ms at 48 kHz). This is an offline native
                      measurement; browser scheduling and WASM need separate checks.
                    </p>
                    <p :if={result["attack_processing"]} class="mt-1">
                      Attack audio: {result["attack_processing"]["failed_frames"]} failed frames, {result[
                        "attack_processing"
                      ]["clipped_samples"]} clipped samples.
                      Damaged references can weaken an attack and cannot support a privacy claim.
                    </p>
                  </details>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <header class="space-y-2">
          <h3 id="voice-lab-benchmark-explanation" class="text-base font-medium">
            How to read these results
          </h3>
          <p id="voice-lab-benchmark-scope" class="max-w-3xl text-sm text-stone-600">
            These research attacks describe the limits of each disguise. Their verdicts
            are not a pass/fail requirement for useful voice masking. We also judge how
            different and natural the voice sounds, whether pronunciation stays clear,
            and download, memory, compute and delay costs.
          </p>
          <p id="voice-lab-benchmark-threat" class="max-w-3xl text-sm text-stone-600">
            Imagine someone records a Randos conversation and already has recordings of
            people they suspect are speaking. This test asks whether a speaker model can
            match the disguised voice to one of those people. It does not require recovering
            the original-sounding voice or finding an unknown person's name.
          </p>
          <p class="max-w-3xl text-sm text-stone-600">
            A speaker-recognition model ({@report["models"]["speaker"]}) tries to tell {@report[
              "dataset"
            ]["speakers"]} LibriSpeech speakers apart after each processor, and
            speech recognition ({@report["models"]["asr"]}) checks they're still understood.
            Equal error rate (EER): 0% means voices are told apart perfectly and 50% means it's
            guessing in this verification test. Higher means this test has more difficulty;
            it does not establish anonymity. <em>Original references</em>
            means the attacker has
            recordings of the unmodified voice. <em>Matching settings</em>
            gives the attacker
            each trial call's exact parameters to transform every speaker's reference recordings.
            <em>Search attack</em>
            tries reversing pitch shifts, or searches a bank of McAdams
            settings while keeping their reference voices separate.
          </p>
          <p id="voice-lab-benchmark-identification" class="max-w-3xl text-sm text-stone-600">
            <em>Recognized</em>
            is how often the correct speaker ranks first among the {@report["dataset"]["speakers"]} enrolled people: lower is better, with {percent(
              1 / @report["dataset"]["speakers"]
            )} expected from uniform guessing.
            Matching and search results are shown separately. A dash means that attack was not run.
          </p>
          <p id="voice-lab-benchmark-sources" class="max-w-3xl text-sm text-stone-600">
            These {@report["dataset"]["speakers"]} speakers come from <a
              href="https://www.openslr.org/12"
              class="underline"
            >LibriSpeech test-clean</a>,
            English audiobook speech derived from LibriVox (CC BY 4.0). We select 10 women
            and 10 men, five clips each: two reference clips and three different test clips.
            They are separate from the four bundled listening samples.
          </p>
          <p id="voice-lab-benchmark-reconstruction" class="max-w-3xl text-sm text-stone-600">
            Recovering the original-sounding voice from a disguised recording is a separate
            attack. Pitch-shift search tries reversing the pitch change, then scores identity
            matching; it does not yet include a listening assessment of the recovered voice.
            The Recovery test tab provides a small, approximate McAdams reversal with the
            known setting, awaiting listening assessment. Its parameter-bank attack here
            only compares identities. Losing some information is not proof that approximate
            reconstruction is impossible.
          </p>
          <p id="voice-lab-benchmark-baseline" class="text-sm text-stone-700">
            Original voices: EER {percent(@report["baseline"]["eer"])}, word error rate {percent(
              @report["baseline"]["wer"]
            )}. Run {@report["generated_at"]}.
          </p>
        </header>
        <p id="voice-lab-benchmark-context" class="max-w-3xl text-sm text-stone-600">
          These are saved experiment results, not a test of the sliders you just changed.
          Lower word error rate means fewer transcription mistakes. Higher EER means this
          recognition test has more difficulty distinguishing speakers; it is not a percentage
          of people who are anonymous. This small, English-only benchmark is a research filter,
          not a privacy guarantee. A disguise may still be useful if it sounds natural,
          remains intelligible and sounds different from the original, even when this
          known-recording attack succeeds. Listening quality and how recognizable a voice
          is to people need separate assessment; these model scores do not measure them.
          The McAdams α=1 row controls for bandwidth, resampling and overlap-add; it bypasses
          formant modification. Its known 21.3 ms processing delay is removed only for offline
          scoring, after flushing the audio tail. You can hear McAdams in Listen &amp; compare
          and Try your voice, including the tested .7 and .9 coefficients. These experiments
          have not been enabled for calls.
        </p>
      </div>
    </section>
    """
  end
end
