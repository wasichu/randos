defmodule RandosDev.TranslationReviewLive do
  @moduledoc """
  The translation shootout's review page (Phase 6), at `/dev/translations`
  in development only: for each locale, every model's translation of every
  string side by side, the strings where the models disagree most first,
  each evaluator's score and rank beside each translation, the strings
  where the evaluators disagree on the best model, the failed checks, the
  translation that ships for each string (`review.pick` in tools/translate)
  and the model picked most. Data: `RandosDev.TranslationReview`.

  English on purpose, like the voice lab: it's a developer tool.
  """
  use RandosWeb, :live_view

  alias Randos.ConversationLanguages
  alias RandosDev.TranslationReview

  @impl true
  def mount(params, session, socket) do
    # (Mounted outside the router, as tests do, there are no params.)
    catalog = if is_map(params) and params["catalog"] == "tui", do: "tui", else: "site"
    path = session["path"] || TranslationReview.default_path(catalog)

    socket =
      case TranslationReview.load(path) do
        {:ok, review} ->
          # The locale with the most strings first. (Not `:locale`: the root
          # layout reads that for the page's own lang and dir.)
          {locale, _data} =
            Enum.max_by(review["locales"], fn {_code, d} -> length(d["strings"]) end)

          assign(socket, review: review, error: nil, review_locale: locale)

        {:error, error} ->
          assign(socket, review: nil, error: error, review_locale: nil)
      end

    {:ok, assign(socket, page_title: "Translation review", filter: "all", catalog: catalog)}
  end

  @impl true
  def handle_event("locale", %{"locale" => locale}, socket) do
    if Map.has_key?(socket.assigns.review["locales"], locale),
      do: {:noreply, assign(socket, review_locale: locale)},
      else: {:noreply, socket}
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    if filter in TranslationReview.filters(),
      do: {:noreply, assign(socket, filter: filter)},
      else: {:noreply, socket}
  end

  @impl true
  def render(%{review: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-3xl space-y-3 px-4 py-10 sm:px-8">
        <h1 class="text-3xl font-semibold">Translation review</h1>
        <.catalogs catalog={@catalog} />
        <p id="review-missing" class="text-stone-600">{@error}</p>
        <p class="text-stone-600">
          Run the shootout, then
          <code class="rounded bg-stone-100 px-1.5 py-0.5 text-sm">
            cd tools/translate && UV_PROJECT_ENVIRONMENT=.venv-test uv run python -m randos_translate.cli --catalog {@catalog} review
          </code>
        </p>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    data = assigns.review["locales"][assigns.review_locale]

    assigns =
      assign(assigns,
        data: data,
        rows: TranslationReview.strings(data, assigns.filter),
        counts:
          Map.new(TranslationReview.filters(), &{&1, length(TranslationReview.strings(data, &1))}),
        scorers: ordered_scorers(assigns.review["scorers"]),
        dir: RandosWeb.Locale.dir(assigns.review_locale)
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-[calc(100vh-5rem)] bg-stone-50 text-stone-950">
        <div id="translation-review" class="mx-auto max-w-7xl space-y-8 px-4 py-8 sm:px-8">
          <header class="space-y-2">
            <h1 class="text-3xl font-semibold tracking-normal">Translation review</h1>
            <.catalogs catalog={@catalog} />
            <p class="max-w-3xl text-stone-600">
              Every model's translation side by side, the strings where they disagree most first.
              Scores and ranks per evaluator; a warning where the evaluators disagree on the best
              model; red where a translation failed an automatic check.
            </p>
            <p id="review-runs" class="text-sm text-stone-500">
              {length(@review["runs"])} runs: {Enum.map_join(
                @review["runs"],
                ", ",
                &"#{&1["model"]} (#{Enum.join(&1["locales"], ", ")})"
              )}
            </p>
          </header>

          <nav id="review-locales" class="flex flex-wrap gap-2" aria-label="Locales">
            <button
              :for={code <- Map.keys(@review["locales"])}
              id={"review-locale-#{code}"}
              type="button"
              phx-click="locale"
              phx-value-locale={code}
              aria-pressed={to_string(code == @review_locale)}
              class={[
                "rounded-md border px-3 py-1.5 text-sm font-medium transition",
                if(code == @review_locale,
                  do: "border-teal-700 bg-teal-700 text-white",
                  else: "border-stone-300 bg-white text-stone-700 hover:bg-stone-100"
                )
              ]}
            >
              {ConversationLanguages.name(code)}
            </button>
          </nav>

          <section
            id="review-summary"
            class="overflow-x-auto rounded-lg border border-stone-200 bg-white"
          >
            <table class="w-full text-left text-sm">
              <thead class="border-b border-stone-200 text-stone-500">
                <tr>
                  <th class="px-4 py-2 font-medium">Model</th>
                  <th class="px-4 py-2 font-medium">Strings</th>
                  <th class="px-4 py-2 font-medium">Pass every check</th>
                  <th class="px-4 py-2 font-medium">Mean chrF</th>
                  <th class="px-4 py-2 font-medium">Mean rank</th>
                  <th class="px-4 py-2 font-medium">Picked for</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{model, s} <- @data["summary"]}
                  id={"review-summary-#{model}"}
                  class="border-b border-stone-100 last:border-0"
                >
                  <td class="px-4 py-2 font-medium">
                    {model}
                    <span
                      :if={@data["winner"] && @data["winner"]["model"] == model}
                      id="review-winner"
                      title={@data["winner"]["why"]}
                      class="ms-2 rounded-full bg-teal-50 px-2 py-0.5 text-xs font-medium text-teal-800"
                    >
                      most picked
                    </span>
                  </td>
                  <td class="px-4 py-2">{s["strings"]}</td>
                  <td class="px-4 py-2">{s["all_checks_pass"]}</td>
                  <td class="px-4 py-2">{s["mean_chrf"] || "—"}</td>
                  <td class="px-4 py-2">{s["mean_rank"] || "—"}</td>
                  <td class="px-4 py-2">{s["best_count"]}</td>
                </tr>
              </tbody>
            </table>
            <p :if={!@data["winner"]} id="review-no-winner" class="px-4 py-2 text-sm text-stone-500">
              Only one model ran for this locale, so there's nothing to compare yet.
            </p>
          </section>

          <nav id="review-filters" class="flex flex-wrap gap-2" aria-label="Filter strings">
            <button
              :for={filter <- RandosDev.TranslationReview.filters()}
              id={"review-filter-#{filter}"}
              type="button"
              phx-click="filter"
              phx-value-filter={filter}
              aria-pressed={to_string(filter == @filter)}
              class={[
                "rounded-full border px-3 py-1 text-sm transition",
                if(filter == @filter,
                  do: "border-stone-800 bg-stone-800 text-white",
                  else: "border-stone-300 bg-white text-stone-700 hover:bg-stone-100"
                )
              ]}
            >
              {filter_label(filter)} ({@counts[filter]})
            </button>
          </nav>

          <ol id="review-strings" class="space-y-4">
            <li
              :for={row <- @rows}
              id={"review-string-#{RandosDev.TranslationReview.key_id(row["key"])}"}
              class="rounded-lg border border-stone-200 bg-white p-4"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-3">
                <p class="font-medium">
                  {row["msgid"]}
                  <span :if={row["msgctxt"]} class="ms-1 text-xs text-stone-500">({row["msgctxt"]})</span>
                </p>
                <div
                  class="flex items-center gap-2 text-xs text-stone-500"
                  title="1 − mean pairwise chrF between the models' translations"
                >
                  <span>models disagree</span>
                  <span class="review-disagreement flex gap-0.5" aria-hidden="true">
                    <span
                      :for={step <- 1..10}
                      class={[
                        "h-1.5 w-2 rounded-sm",
                        if(step <= round(row["disagreement"] * 10),
                          do: "bg-teal-600",
                          else: "bg-stone-200"
                        )
                      ]}
                    ></span>
                  </span>
                  <span class="tabular-nums">{round(row["disagreement"] * 100)}%</span>
                </div>
              </div>

              <p
                :if={row["conflict"]}
                class="review-conflict mt-2 rounded-md bg-amber-50 px-3 py-1.5 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200"
              >
                Evaluators disagree: {Enum.map_join(
                  row["conflict"]["first_by"],
                  ", ",
                  &scorer_label(@scorers, &1)
                )} rank {row["conflict"]["model"]} first, {Enum.map_join(
                  row["conflict"]["last_by"],
                  ", ",
                  &scorer_label(@scorers, &1)
                )} last.
              </p>

              <div class="mt-3 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
                <div
                  :for={{model, t} <- row["translations"]}
                  class={[
                    "review-translation space-y-2 rounded-md border p-3",
                    if(t["failed"] != [],
                      do: "border-red-300 dark:border-red-800",
                      else: "border-stone-200"
                    )
                  ]}
                  data-model={model}
                >
                  <div class="flex items-center justify-between text-xs text-stone-500">
                    <span class="font-medium uppercase tracking-wide">{model}</span>
                    <span
                      :if={row["best"] == model}
                      title={row["best_why"]}
                      class="review-best rounded-full bg-teal-50 px-2 py-0.5 font-medium text-teal-800"
                    >
                      ships
                    </span>
                  </div>
                  <p :if={t["text"] != ""} dir={@dir} lang={@review_locale} class="text-base">
                    {t["text"]}
                  </p>
                  <p :if={t["text"] == ""} class="text-base italic text-stone-500">(empty)</p>
                  <p class="text-xs text-stone-500">back: {t["back_translation"]}</p>
                  <ul :if={t["failed"] != []} class="flex flex-wrap gap-1">
                    <li
                      :for={f <- t["failed"]}
                      class="review-failed rounded bg-red-50 px-1.5 py-0.5 text-xs text-red-700 dark:bg-red-950 dark:text-red-300"
                      data-check={f["check"]}
                      title={f["detail"]}
                    >
                      {f["check"]}
                    </li>
                  </ul>
                  <dl class="grid grid-cols-2 gap-x-3 text-xs">
                    <%= for {scorer, meta} <- @scorers do %>
                      <dt class="text-stone-500">{meta["label"]}</dt>
                      <dd class="tabular-nums" data-scorer={scorer}>
                        {format_score(scorer, t["scores"][scorer])}
                        <span :if={t["ranks"][scorer]} class="text-stone-400">#{t["ranks"][scorer]}</span>
                      </dd>
                    <% end %>
                  </dl>
                </div>
              </div>
            </li>
          </ol>
          <p :if={@rows == []} id="review-empty" class="text-stone-500">
            No strings match this filter.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp filter_label("all"), do: "All"
  defp filter_label("disagree"), do: "Models disagree"
  defp filter_label("conflict"), do: "Evaluators disagree"
  defp filter_label("failed"), do: "Failed a check"

  # The review's order (a JSON object, so a map here): chrF first, then the
  # QE models, then the judge; any other scorer after them.
  @scorer_order ~w(chrf metricx comet_kiwi judge judge_qwen)
  defp ordered_scorers(scorers) do
    Enum.sort_by(scorers, fn {name, _meta} ->
      Enum.find_index(@scorer_order, &(&1 == name)) || length(@scorer_order)
    end)
  end

  defp scorer_label(scorers, scorer),
    do: Enum.find_value(scorers, scorer, fn {name, meta} -> name == scorer && meta["label"] end)

  # COMET-Kiwi is 0–1 and picks turn on its second and third decimals
  # (0.87 against 0.86); the others read fine at one.
  defp format_score(_scorer, nil), do: "—"

  defp format_score("comet_kiwi", score) when is_float(score),
    do: :erlang.float_to_binary(score, decimals: 3)

  defp format_score(_scorer, score) when is_float(score),
    do: :erlang.float_to_binary(score, decimals: 1)

  defp format_score(_scorer, score), do: to_string(score)

  attr :catalog, :string, required: true

  # The website's strings or the terminal client's (`--catalog`).
  defp catalogs(assigns) do
    ~H"""
    <nav id="review-catalogs" class="flex gap-4 text-sm" aria-label="Which strings">
      <.link
        :for={{catalog, label, href} <- [{"site", "Website", ~p"/dev/translations"}, {"tui", "Terminal client", ~p"/dev/translations?catalog=tui"}]}
        id={"review-catalog-#{catalog}"}
        navigate={href}
        aria-current={if catalog == @catalog, do: "page"}
        class={[
          "font-medium",
          if(catalog == @catalog, do: "text-teal-800 underline", else: "text-stone-500 hover:text-teal-800")
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end
end
