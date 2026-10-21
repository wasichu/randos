defmodule RandosDev.TranslationReviewTest do
  # The page's routes exist only with dev_routes (not in tests), so these
  # drive the LiveView directly, with a small review file written here (the
  # real one comes from tools/translate's `review` command).
  use RandosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RandosDev.TranslationReview

  @scorers %{
    "chrf" => %{"label" => "Back-translation chrF", "higher_is_better" => true},
    "metricx" => %{"label" => "MetricX-24", "higher_is_better" => false}
  }

  defp translation(text, chrf, metricx, ranks, failed \\ []) do
    %{
      "text" => text,
      "back_translation" => "back",
      "failed" => failed,
      "scores" => %{"chrf" => chrf, "metricx" => metricx},
      "ranks" => ranks
    }
  end

  defp review do
    %{
      "runs" => [%{"model" => "a", "locales" => ["es", "ar"], "strings" => 2, "at" => "1"}],
      "scorers" => @scorers,
      "locales" => %{
        "ar" => %{
          "models" => ["a"],
          "summary" => %{"a" => %{"strings" => 1, "all_checks_pass" => 1, "mean_chrf" => 50.0}},
          "winner" => nil,
          "strings" => [
            %{
              "key" => "About",
              "msgid" => "About",
              "msgctxt" => nil,
              "disagreement" => 0.0,
              "conflict" => nil,
              "best" => nil,
              "translations" => %{"a" => translation("حول", 50.0, nil, %{})}
            }
          ]
        },
        "es" => %{
          "models" => ["a", "b"],
          "summary" => %{
            "a" => %{
              "strings" => 2,
              "all_checks_pass" => 1,
              "mean_chrf" => 80.0,
              "mean_rank" => 1.5,
              "best_count" => 0
            },
            "b" => %{
              "strings" => 2,
              "all_checks_pass" => 2,
              "mean_chrf" => 70.0,
              "mean_rank" => 1.5,
              "best_count" => 2
            }
          },
          "winner" => %{"model" => "b", "why" => "passes every check on 2/2 strings"},
          "strings" => [
            %{
              "key" => "Mute",
              "msgid" => "Mute",
              "msgctxt" => "button",
              "disagreement" => 0.95,
              "conflict" => %{"model" => "a", "first_by" => ["chrf"], "last_by" => ["metricx"]},
              "best" => "b",
              "translations" => %{
                "a" => translation("Muerte", 90.0, 9.0, %{"chrf" => 1, "metricx" => 2}),
                "b" => translation("Silenciar", 60.0, 1.0, %{"chrf" => 2, "metricx" => 1})
              }
            },
            %{
              "key" => "%{time} left",
              "msgid" => "%{time} left",
              "msgctxt" => nil,
              "disagreement" => 0.1,
              "conflict" => nil,
              "best" => "b",
              "translations" => %{
                "a" =>
                  translation("quedan", 70.0, nil, %{}, [
                    %{"check" => "placeholders", "detail" => "expected ['%{time}'], got []"}
                  ]),
                "b" => translation("quedan %{time}", 70.0, nil, %{})
              }
            }
          ]
        }
      }
    }
  end

  setup do
    path = Path.join(System.tmp_dir!(), "review-#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(review()))
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp open(conn, path),
    do: live_isolated(conn, RandosDev.TranslationReviewLive, session: %{"path" => path})

  defp string_id(key), do: "#review-string-#{TranslationReview.key_id(key)}"

  test "shows each locale's models side by side, the winner, and the disagreements", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = open(conn, path)
    assert view |> element("#review-locale-es") |> render_click()

    assert has_element?(view, "#review-summary-a")
    assert has_element?(view, "#review-summary-b #review-winner")
    mute = string_id("Mute")
    assert has_element?(view, "#{mute} .review-translation[data-model='a']", "Muerte")
    assert has_element?(view, "#{mute} .review-translation[data-model='b']", "Silenciar")
    assert has_element?(view, "#{mute} .review-translation[data-model='b'] .review-best")
    assert has_element?(view, "#{mute} .review-conflict", "MetricX-24")
    assert has_element?(view, "#{mute} [data-scorer='metricx']", "9.0")
  end

  test "lists failed checks, and filters", %{conn: conn, path: path} do
    {:ok, view, _html} = open(conn, path)
    view |> element("#review-locale-es") |> render_click()
    left = string_id("%{time} left")
    assert has_element?(view, "#{left} .review-failed[data-check='placeholders']")

    view |> element("#review-filter-conflict") |> render_click()
    assert has_element?(view, string_id("Mute"))
    refute has_element?(view, left)

    view |> element("#review-filter-failed") |> render_click()
    assert has_element?(view, left)
    refute has_element?(view, string_id("Mute"))
  end

  test "right-to-left locales read right to left; one model means no winner", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = open(conn, path)
    view |> element("#review-locale-ar") |> render_click()

    assert has_element?(view, "#{string_id("About")} p[dir='rtl'][lang='ar']", "حول")
    assert has_element?(view, "#review-no-winner")
  end

  test "says how to make a review when there isn't one", %{conn: conn} do
    {:ok, view, _html} = open(conn, "/nonexistent/review.json")
    assert has_element?(view, "#review-missing", "no review yet")
  end
end
