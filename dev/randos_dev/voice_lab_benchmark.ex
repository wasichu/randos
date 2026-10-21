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

  attr :report, :map, default: nil

  @doc "The lab's Benchmark section, from `load/1`'s report."
  def section(%{report: nil} = assigns) do
    ~H"""
    <section id="voice-lab-benchmark" class="mx-auto max-w-6xl px-4 pb-10 sm:px-8" data-state="none">
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
    <section id="voice-lab-benchmark" class="mx-auto max-w-6xl px-4 pb-10 sm:px-8" data-state="ready">
      <div class="space-y-4 rounded-lg border border-stone-200 bg-white p-5">
        <header class="space-y-2">
          <h2 class="text-lg font-semibold tracking-normal">Benchmark: can you still be recognized?</h2>
          <p class="max-w-3xl text-sm text-stone-600">
            A speaker-recognition model ({@report["models"]["speaker"]}) tries to tell
            {@report["dataset"]["speakers"]} LibriSpeech speakers apart after each processor, and
            speech recognition ({@report["models"]["asr"]}) checks they're still understood.
            Equal error rate (EER): 0% means voices are told apart perfectly and 50% means it's
            guessing, so higher is more anonymous. The <em>ignorant</em>
            attacker compares with the original voices; the <em>informed</em>
            one knows the processor and its setting, and processes its reference voices the same
            way. Only fooling the informed attacker counts.
          </p>
          <p id="voice-lab-benchmark-baseline" class="text-sm text-stone-700">
            Original voices: EER {percent(@report["baseline"]["eer"])}, word error rate {percent(
              @report["baseline"]["wer"]
            )}. Run {@report["generated_at"]}.
          </p>
        </header>
        <div class="overflow-x-auto">
          <table class="w-full text-left text-sm">
            <thead class="text-stone-500">
              <tr>
                <th class="py-2 pe-4 font-medium">Processor</th>
                <th class="py-2 pe-4 font-medium">EER, ignorant</th>
                <th class="py-2 pe-4 font-medium">EER, informed</th>
                <th class="py-2 pe-4 font-medium">EER, shifted back</th>
                <th class="py-2 pe-4 font-medium">Word error rate</th>
                <th class="py-2 font-medium">Verdict</th>
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
                <td class="py-2 pe-4 tabular-nums">{percent(result["eer_undo"])}</td>
                <td class="py-2 pe-4 tabular-nums">{percent(result["wer"])}</td>
                <td class="py-2 text-stone-700">{result["verdict"]["text"]}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end
end
