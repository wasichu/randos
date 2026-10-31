defmodule RandosDev.VoiceLabReviews do
  @moduledoc "Text-only local listening feedback and withdrawals; never part of production."
  use RandosWeb, :html

  @root Path.expand("../..", __DIR__)
  @path Path.join(@root, "tools/voice-eval/results/listening-reviews.jsonl")
  @choices %{
    "naturalness" => [
      {"Natural", "natural"},
      {"A little artificial", "slightly_artificial"},
      {"Very artificial", "very_artificial"}
    ],
    "clarity" => [
      {"Easy to understand", "clear"},
      {"Some words unclear", "some_unclear"},
      {"Hard to understand", "hard"}
    ],
    "resemblance" => [
      {"Sounds like the original person", "same"},
      {"Partly resembles the original", "partial"},
      {"Sounds like a different person", "different"}
    ]
  }

  @doc "Fingerprint the processing build and bundled sources for exact-context drafts."
  def build_id do
    files = [
      "assets/js/randos/voice/randos_voice.wasm",
      "assets/js/randos/voice/pitch_shift.js",
      "assets/js/randos/voice/worklet.js",
      "assets/js/randos/voice/seam.js",
      "assets/js/voice_lab/mcadams.js",
      "assets/js/voice_lab/processors.js",
      "assets/js/voice_lab/comparison.js",
      "assets/js/voice_lab/test_tone.js",
      "assets/js/voice_lab/lab.js"
    ]

    clips = Path.wildcard(Path.join(@root, "dev/voice_lab/clips/*.wav"))

    bytes =
      Enum.map(Enum.map(files, &Path.join(@root, &1)) ++ clips, fn path ->
        [Path.relative_to(path, @root), 0, File.read!(path)]
      end)

    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  @doc "The exact bundled source bytes, or generator code for the test tone."
  def source_ids do
    sources = Path.wildcard(Path.join(@root, "dev/voice_lab/clips/*.wav"))
    ids = Map.new(sources, fn path -> {Path.basename(path), digest(File.read!(path))} end)

    Map.put(
      ids,
      "test_tone",
      digest(File.read!(Path.join(@root, "assets/js/voice_lab/test_tone.js")))
    )
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "Validate and append one bounded record to a fixed local JSONL file."
  def save(payload, path \\ @path) do
    with {:ok, record} <- validate(payload),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [JSON.encode!(record), "\n"], [:append]) do
      {:ok, record["saved_at"]}
    else
      {:error, :invalid_review} = error -> error
      {:error, _reason} -> {:error, :storage_failed}
    end
  end

  defp validate(%{"context" => context, "ratings" => ratings, "notes" => notes} = payload)
       when is_map(context) and is_map(ratings) and is_binary(notes) do
    valid = valid_content?(payload)

    if valid and byte_size(notes) <= 8000 and String.valid?(notes) and
         String.length(notes) <= 2000 and
         valid_context?(context) and valid_ratings?(ratings, context) do
      {:ok,
       Map.merge(payload, %{
         "schema_version" => 1,
         "saved_at" => DateTime.to_iso8601(DateTime.utc_now())
       })}
    else
      {:error, :invalid_review}
    end
  end

  defp validate(_payload), do: {:error, :invalid_review}

  defp valid_content?(%{"withdrawn" => true, "ratings" => ratings, "notes" => ""} = payload),
    do:
      map_size(ratings) == 0 and
        Enum.sort(Map.keys(payload)) == ~w(context notes ratings withdrawn)

  defp valid_content?(%{"ratings" => ratings, "notes" => notes} = payload),
    do:
      Enum.sort(Map.keys(payload)) == ~w(context notes ratings) and
        (map_size(ratings) > 0 or String.trim(notes) != "")

  defp valid_context?(%{"view" => "listen", "build_id" => build} = context) do
    Map.keys(context) |> Enum.sort() ==
      ~w(build_id mode parameters processor sample source_id view) and
      fingerprint?(build) and fingerprint?(context["source_id"]) and context["mode"] == "forward" and
      common_context?(context)
  end

  defp valid_context?(
         %{"view" => "recovery", "run_id" => run, "case_id" => id, "headroom" => gain} = context
       ) do
    Map.keys(context) |> Enum.sort() ==
      ~w(build_id case_id headroom mode parameters processor run_id sample source_id view) and
      text?(run, 80) and text?(id, 100) and number?(gain, 0.001, 1) and
      fingerprint?(context["build_id"]) and fingerprint?(context["source_id"]) and
      context["mode"] == "approximate_inverse_capped" and
      context["processor"] == "mcadams" and common_context?(context)
  end

  defp valid_context?(%{"view" => "model"} = context) do
    Map.keys(context) |> Enum.sort() ==
      ~w(build_id case_id mode processor run_id sample source_id view) and
      {context["processor"], context["mode"]} in [
        {"seed_vc_v2", "average_voice_style"},
        {"tvtsyn_browser", "browser_wasm"},
        {"tvtsyn_native", "native_onnx"},
        {"tvtsyn_int8", "dynamic_int8_onnx"},
        {"hybrid_down_2", "fixed_dsp"},
        {"hybrid_up_2", "fixed_dsp"},
        {"hybrid_mild", "fixed_dsp"},
        {"quality_pitch", "rms_matched"},
        {"quality_resonance", "rms_matched"},
        {"quality_both", "rms_matched"},
        {"quality_tvtsyn", "rms_matched"},
        {"world_control", "model_free_dsp"},
        {"world_pitch", "model_free_dsp"},
        {"world_formants", "model_free_dsp"},
        {"world_texture", "model_free_dsp"},
        {"world_chunk_40", "chunked_world"},
        {"world_chunk_80", "chunked_world"},
        {"world_chunk_160", "chunked_world"},
        {"browser_world", "browser_dsp"},
        {"browser_spectral", "browser_dsp"},
        {"browser_time", "browser_dsp"},
        {"spectral_more_pitch", "browser_dsp_round"},
        {"spectral_more_resonance", "browser_dsp_round"},
        {"spectral_opposing", "browser_dsp_round"},
        {"preferred_spectral", "preferred_engines"},
        {"preferred_world", "preferred_engines"},
        {"gentle_current_pitch", "gentle_pitch"},
        {"gentle_half_pitch", "gentle_pitch"},
        {"gentle_zero_pitch", "gentle_pitch"},
        {"envelope_current", "selective_resonance"},
        {"envelope_bend_a", "selective_resonance"},
        {"envelope_bend_b", "selective_resonance"},
        {"fargan_control", "fargan_resynthesis"},
        {"fargan_mask_control", "fargan_masking"},
        {"fargan_mask_pitch", "fargan_masking"},
        {"fargan_mask_envelope", "fargan_masking"},
        {"fargan_combined", "fargan_combined"},
        {"texture_bandwidth_control", "texture_bandwidth"},
        {"texture_bandwidth_narrower", "texture_bandwidth"},
        {"texture_bandwidth_wider", "texture_bandwidth"},
        {"texture_source_control", "texture_source"},
        {"texture_source_softer", "texture_source"},
        {"texture_source_sharper", "texture_source"}
      ] and
      fingerprint?(context["build_id"]) and fingerprint?(context["source_id"]) and
      text?(context["sample"], 100) and text?(context["case_id"], 100) and
      text?(context["run_id"], 80)
  end

  defp valid_context?(%{"view" => "round"} = context) do
    Map.keys(context) |> Enum.sort() ==
      ~w(build_id case_id mode processor run_id sample source_id view) and
      {context["processor"], context["mode"]} in [
        {"signalsmith", "signalsmith_strength_1"},
        {"signalsmith_world", "engine_comparison_1"},
        {"signalsmith", "gentle_pitch_1"},
        {"signalsmith_envelope", "selective_resonance_1"},
        {"fargan", "fargan_quality_1"},
        {"fargan", "fargan_masking_1"},
        {"fargan", "fargan_combined_1"},
        {"signalsmith_texture", "bandwidth_1"},
        {"signalsmith_texture", "source_1"}
      ] and
      fingerprint?(context["build_id"]) and fingerprint?(context["source_id"]) and
      text?(context["sample"], 100) and text?(context["case_id"], 100) and
      text?(context["run_id"], 80)
  end

  defp valid_context?(_context), do: false

  defp common_context?(%{
         "sample" => sample,
         "processor" => "mcadams",
         "parameters" => %{"alpha" => alpha} = params
       }),
       do: text?(sample, 100) and map_size(params) == 1 and number?(alpha, 0.5, 1)

  defp common_context?(%{
         "sample" => sample,
         "processor" => "pitch_shift",
         "parameters" => %{"semitones" => pitch, "window_ms" => window} = params
       }),
       do:
         text?(sample, 100) and map_size(params) == 2 and number?(pitch, -12, 12) and
           number?(window, 10, 100)

  defp common_context?(_context), do: false

  defp valid_ratings?(ratings, %{"view" => "round", "mode" => mode}) do
    allowed =
      case mode do
        "engine_comparison_1" -> ~w(spectral world none unsure)
        "gentle_pitch_1" -> ~w(current_pitch half_pitch zero_pitch none unsure)
        "selective_resonance_1" -> ~w(current bend_a bend_b none unsure)
        "bandwidth_1" -> ~w(reference control narrower wider none unsure)
        "source_1" -> ~w(reference control softer sharper none unsure)
        "fargan_quality_1" -> ~w(acceptable rough unusable unsure)
        "fargan_masking_1" -> ~w(control pitch envelope reference none unsure)
        "fargan_combined_1" -> ~w(control combined reference none unsure)
        _ -> ~w(current more_pitch more_resonance opposing none unsure)
      end

    ratings == %{} or
      (Map.keys(ratings) == ["comparison"] and
         is_map(ratings["comparison"]) and
         Map.keys(ratings["comparison"]) == ["preference"] and
         ratings["comparison"]["preference"] in allowed)
  end

  defp valid_ratings?(ratings, %{"view" => view}) do
    voices = if view == "recovery", do: ~w(disguised recovered), else: ~w(disguised)

    Enum.all?(ratings, fn {voice, answers} ->
      voice in voices and is_map(answers) and map_size(answers) > 0 and
        Enum.all?(answers, fn {question, answer} ->
          Enum.any?(Map.get(@choices, question, []), fn {_label, value} -> answer == value end) or
            (Map.has_key?(@choices, question) and answer == "unsure")
        end)
    end)
  end

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max

  defp number?(value, low, high), do: is_number(value) and value >= low and value <= high
  defp fingerprint?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  attr :kind, :string, required: true
  attr :voices, :list, default: [{"disguised", "Modified voice"}]
  attr :preference_choices, :list, default: []
  attr :preference, :boolean, default: false
  attr :preference_label, :string, default: "Best balance of disguise, naturalness and clarity"
  attr :notes_placeholder, :string, default: "For example: nasal at 0.7, clearer at 0.8…"

  def feedback(assigns) do
    questions =
      if assigns.preference,
        do: [{"preference", assigns.preference_label}],
        else: [
          {"naturalness", "Naturalness"},
          {"clarity", "Clarity"},
          {"resemblance", "Resemblance to the original person"}
        ]

    choices =
      if assigns.preference,
        do: %{
          "preference" => [
            {"Current", "current"},
            {"More pitch", "more_pitch"},
            {"More resonance", "more_resonance"},
            {"Opposing directions", "opposing"},
            {"None is useful", "none"}
          ]
        },
        else: @choices

    choices =
      if assigns.preference and assigns.preference_choices != [],
        do: %{"preference" => assigns.preference_choices},
        else: choices

    values =
      for {voice, _} <- assigns.voices,
          {key, _label} <- questions,
          into: %{},
          do: {"#{voice}_#{key}", ""}

    assigns =
      assigns
      |> assign(:review_form, to_form(Map.put(values, "notes", ""), as: "voice_review"))
      |> assign(:questions, questions)
      |> assign(:choices, choices)

    ~H"""
    <.form
      for={@review_form}
      id={"voice-lab-review-#{@kind}"}
      data-voice-review={@kind}
      class="space-y-3 rounded-lg border border-stone-200 bg-white p-4"
    >
      <h3 class="text-base font-medium">Your listening feedback</h3>
      <p data-review-context-label class="text-sm text-stone-600"></p>
      <fieldset :for={{voice, label} <- @voices} class="space-y-2">
        <legend class="text-sm font-medium">{label}</legend>
        <div class={if @preference, do: "grid gap-3", else: "grid gap-3 md:grid-cols-3"}>
          <.input
            :for={{question, label} <- @questions}
            field={@review_form["#{voice}_#{question}"]}
            id={"voice-lab-review-#{@kind}-#{voice}-#{question}"}
            type="select"
            label={label}
            options={[{"Not judged", ""}] ++ @choices[question] ++ [{"Unsure", "unsure"}]}
            data-review-voice={voice}
            data-review-question={question}
          />
        </div>
      </fieldset>
      <.input
        field={@review_form[:notes]}
        id={"voice-lab-review-#{@kind}-notes"}
        type="textarea"
        label="Notes (optional)"
        rows="2"
        maxlength="2000"
        data-review-notes
        placeholder={@notes_placeholder}
      />
      <div class="flex flex-wrap items-center gap-3">
        <button
          type="submit"
          data-review-save
          disabled
          class="rounded-md bg-teal-700 px-4 py-2 text-sm font-medium text-white transition hover:bg-teal-800 disabled:opacity-50"
        >Save now</button>
        <p
          id={"voice-lab-review-#{@kind}-status"}
          data-review-status
          role="status"
          class="text-sm text-stone-600"
        >
          Choose a sample to start.
        </p>
      </div>
      <p class="text-xs text-stone-500">
        Reviews auto-save after a short pause and every five seconds while editing.
        Drafts are also backed up in this browser. Only ratings, notes and sample/settings
        are saved to this development checkout so the assistant can read them on its next turn.
        When you're finished, just say “reviews ready.” No audio is recorded or sent.
      </p>
    </.form>
    """
  end
end
