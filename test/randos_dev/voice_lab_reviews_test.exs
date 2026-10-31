defmodule RandosDev.VoiceLabReviewsTest do
  use RandosWeb.ConnCase, async: true

  alias RandosDev.VoiceLabReviews
  alias RandosDev.VoiceLabReviewsController

  test "independent texture rounds accept only their own choices", %{path: path} do
    base = %{
      "view" => "round",
      "processor" => "signalsmith_texture",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "mid_voice",
      "case_id" => "mid_voice",
      "run_id" => "2026-10-31"
    }

    for {mode, choices, wrong} <- [
          {"bandwidth_1", ~w(reference control narrower wider none unsure), "softer"},
          {"source_1", ~w(reference control softer sharper none unsure), "narrower"}
        ] do
      context = Map.put(base, "mode", mode)

      for choice <- choices do
        assert {:ok, _} =
                 VoiceLabReviews.save(
                   %{
                     "context" => context,
                     "ratings" => %{"comparison" => %{"preference" => choice}},
                     "notes" => ""
                   },
                   path
                 )
      end

      assert {:error, :invalid_review} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => wrong}},
                   "notes" => ""
                 },
                 path
               )
    end

    for {mode, processors} <- [
          {"texture_bandwidth",
           ~w(texture_bandwidth_control texture_bandwidth_narrower texture_bandwidth_wider)},
          {"texture_source",
           ~w(texture_source_control texture_source_softer texture_source_sharper)}
        ],
        processor <- processors do
      context = Map.merge(base, %{"view" => "model", "mode" => mode, "processor" => processor})

      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{"context" => context, "ratings" => %{}, "notes" => "Clear but rough"},
                 path
               )
    end
  end

  defp review do
    %{
      "context" => %{
        "view" => "listen",
        "mode" => "forward",
        "source_id" => String.duplicate("b", 64),
        "sample" => "mid_voice.wav",
        "processor" => "mcadams",
        "parameters" => %{"alpha" => 0.75},
        "build_id" => String.duplicate("a", 64)
      },
      "ratings" => %{
        "disguised" => %{
          "naturalness" => "slightly_artificial",
          "clarity" => "clear",
          "resemblance" => "different"
        }
      },
      "notes" => "A little nasal; words are clear."
    }
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "randos-voice-reviews-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "appends exact settings and text, preserving earlier answers", %{path: path} do
    assert {:ok, _time} = VoiceLabReviews.save(review(), path)
    changed = put_in(review(), ["context", "parameters", "alpha"], 0.9)
    assert {:ok, _time} = VoiceLabReviews.save(changed, path)

    [first, second] =
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert first["context"]["parameters"]["alpha"] == 0.75
    assert second["context"]["parameters"]["alpha"] == 0.9
    assert first["notes"] == review()["notes"]
    assert first["schema_version"] == 1
  end

  test "withdrawal preserves history and a later answer reactivates the context", %{path: path} do
    original = review()
    withdrawal = Map.merge(original, %{"ratings" => %{}, "notes" => "", "withdrawn" => true})
    restored = Map.put(original, "notes", "A new judgment after withdrawal.")

    for payload <- [original, withdrawal, restored] do
      assert {:ok, _} = VoiceLabReviews.save(payload, path)
    end

    [first, withdrawn, latest] =
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert first["ratings"] == original["ratings"]
    assert first["notes"] == original["notes"]
    assert withdrawn["context"] == first["context"]
    assert withdrawn["withdrawn"] == true
    assert withdrawn["ratings"] == %{}
    assert withdrawn["notes"] == ""
    refute Map.has_key?(latest, "withdrawn")
    assert latest["context"] == withdrawn["context"]
    assert latest["notes"] == restored["notes"]
  end

  test "withdrawal requires an explicit true flag and empty content", %{path: path} do
    withdrawal = Map.merge(review(), %{"ratings" => %{}, "notes" => "", "withdrawn" => true})

    for payload <- [
          Map.delete(withdrawal, "withdrawn"),
          Map.put(withdrawal, "withdrawn", false),
          Map.put(withdrawal, "withdrawn", "true"),
          Map.put(withdrawal, "ratings", review()["ratings"]),
          Map.put(withdrawal, "notes", "still a judgment"),
          Map.put(withdrawal, "notes", "  "),
          put_in(withdrawal, ["context", "source_id"], "invalid")
        ] do
      assert {:error, :invalid_review} = VoiceLabReviews.save(payload, path)
    end

    refute File.exists?(path)
  end

  test "concurrent bounded appends keep complete parseable JSONL records", %{path: path} do
    results =
      1..24
      |> Task.async_stream(
        fn index ->
          VoiceLabReviews.save(
            Map.put(review(), "notes", "#{index}: " <> String.duplicate("音", 1800)),
            path
          )
        end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    records = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    assert length(records) == 24
    assert records |> Enum.map(& &1["notes"]) |> Enum.uniq() |> length() == 24
  end

  test "selective resonance round accepts only its exact choices and preserves context", %{
    path: path
  } do
    context = %{
      "view" => "round",
      "mode" => "selective_resonance_1",
      "processor" => "signalsmith_envelope",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "mid_voice",
      "case_id" => "mid_voice",
      "run_id" => "2026-10-29T00:00:00Z"
    }

    for preference <- ~w(current bend_a bend_b none unsure) do
      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => preference}},
                   "notes" => ""
                 },
                 path
               )
    end

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(
               %{
                 "context" => context,
                 "ratings" => %{"comparison" => %{"preference" => "zero_pitch"}},
                 "notes" => ""
               },
               path
             )

    for processor <- ~w(envelope_current envelope_bend_a envelope_bend_b) do
      model =
        Map.merge(context, %{
          "view" => "model",
          "mode" => "selective_resonance",
          "processor" => processor
        })

      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{"context" => model, "ratings" => %{}, "notes" => "Clear"},
                 path
               )
    end
  end

  test "zero pitch is a processed choice distinct from rejecting the round", %{path: path} do
    context = %{
      "view" => "round",
      "mode" => "gentle_pitch_1",
      "processor" => "signalsmith",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "high_voice",
      "case_id" => "high_voice",
      "run_id" => "2026-10-27T00:00:00Z"
    }

    for preference <- ~w(current_pitch half_pitch zero_pitch none unsure) do
      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => preference}},
                   "notes" => ""
                 },
                 path
               )
    end

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(
               %{
                 "context" => context,
                 "ratings" => %{"comparison" => %{"preference" => "world"}},
                 "notes" => ""
               },
               path
             )

    records = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    assert Enum.at(records, 2)["ratings"]["comparison"]["preference"] == "zero_pitch"
    assert Enum.at(records, 3)["ratings"]["comparison"]["preference"] == "none"
  end

  test "FARGAN masking preferences stay separate from quality assessments", %{path: path} do
    context = %{
      "view" => "round",
      "mode" => "fargan_masking_1",
      "processor" => "fargan",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "mid_voice",
      "case_id" => "mid_voice",
      "run_id" => "2026-10-30T00:00:00Z"
    }

    for choice <- ~w(control pitch envelope reference none unsure) do
      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => choice}},
                   "notes" => ""
                 },
                 path
               )
    end

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(
               %{
                 "context" => context,
                 "ratings" => %{"comparison" => %{"preference" => "acceptable"}},
                 "notes" => ""
               },
               path
             )

    for processor <- ~w(fargan_mask_control fargan_mask_pitch fargan_mask_envelope) do
      model =
        Map.merge(context, %{
          "view" => "model",
          "mode" => "fargan_masking",
          "processor" => processor
        })

      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{"context" => model, "ratings" => %{}, "notes" => "A little rough"},
                 path
               )
    end
  end

  test "final combined FARGAN round has its own preferences and context", %{path: path} do
    context = %{
      "view" => "round",
      "mode" => "fargan_combined_1",
      "processor" => "fargan",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "mid_voice",
      "case_id" => "mid_voice",
      "run_id" => "2026-10-30T00:00:00Z"
    }

    for choice <- ~w(control combined reference none unsure) do
      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => choice}},
                   "notes" => ""
                 },
                 path
               )
    end

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(
               %{
                 "context" => context,
                 "ratings" => %{"comparison" => %{"preference" => "pitch"}},
                 "notes" => ""
               },
               path
             )

    model =
      Map.merge(context, %{
        "view" => "model",
        "mode" => "fargan_combined",
        "processor" => "fargan_combined"
      })

    assert {:ok, _} =
             VoiceLabReviews.save(
               %{"context" => model, "ratings" => %{}, "notes" => "Compare directly"},
               path
             )
  end

  test "FARGAN quality assessment is not a masking preference", %{path: path} do
    context = %{
      "view" => "round",
      "mode" => "fargan_quality_1",
      "processor" => "fargan",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "mid_voice",
      "case_id" => "mid_voice",
      "run_id" => "2026-10-30T00:00:00Z"
    }

    for choice <- ~w(acceptable rough unusable unsure) do
      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => choice}},
                   "notes" => ""
                 },
                 path
               )
    end

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(
               %{
                 "context" => context,
                 "ratings" => %{"comparison" => %{"preference" => "bend_a"}},
                 "notes" => ""
               },
               path
             )

    model =
      Map.merge(context, %{
        "view" => "model",
        "mode" => "fargan_resynthesis",
        "processor" => "fargan_control"
      })

    assert {:ok, _} =
             VoiceLabReviews.save(
               %{"context" => model, "ratings" => %{}, "notes" => "Clear control"},
               path
             )
  end

  test "engine comparison preferences cannot use strength-round choices", %{path: path} do
    context = %{
      "view" => "round",
      "mode" => "engine_comparison_1",
      "processor" => "signalsmith_world",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "mid_voice",
      "case_id" => "mid_voice",
      "run_id" => "2026-10-27T00:00:00Z"
    }

    for preference <- ~w(spectral world none unsure) do
      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => preference}},
                   "notes" => ""
                 },
                 path
               )
    end

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(
               %{
                 "context" => context,
                 "ratings" => %{"comparison" => %{"preference" => "current"}},
                 "notes" => ""
               },
               path
             )
  end

  test "round preferences attach to the comparison and reject individual ratings", %{path: path} do
    context = %{
      "view" => "round",
      "mode" => "signalsmith_strength_1",
      "processor" => "signalsmith",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "high_voice",
      "case_id" => "high_voice",
      "run_id" => "2026-10-26T00:00:00Z"
    }

    for preference <- ~w(current more_pitch more_resonance opposing none unsure) do
      assert {:ok, _} =
               VoiceLabReviews.save(
                 %{
                   "context" => context,
                   "ratings" => %{"comparison" => %{"preference" => preference}},
                   "notes" => ""
                 },
                 path
               )
    end

    for ratings <- [
          %{"comparison" => %{"preference" => "original"}},
          %{"disguised" => %{"clarity" => "clear"}},
          %{"comparison" => %{"preference" => "none", "clarity" => "clear"}}
        ] do
      assert {:error, :invalid_review} =
               VoiceLabReviews.save(
                 %{"context" => context, "ratings" => ratings, "notes" => ""},
                 path
               )
    end

    assert {:ok, _} =
             VoiceLabReviews.save(
               %{"context" => context, "ratings" => %{}, "notes" => "The ending sounded rough."},
               path
             )
  end

  test "rejects unknown fields, invalid ratings, missing context and oversized notes", %{
    path: path
  } do
    invalid = [
      Map.put(review(), "audio", "not accepted"),
      put_in(review(), ["context", "path"], "/tmp/not-request-controlled"),
      put_in(review(), ["context", "parameters", "alpha"], 0.1),
      put_in(review(), ["ratings", "disguised", "clarity"], "invented"),
      Map.put(review(), "context", %{}),
      Map.put(review(), "notes", String.duplicate("a", 2001)),
      review() |> Map.put("ratings", %{}) |> Map.put("notes", " ")
    ]

    for payload <- invalid,
        do: assert({:error, :invalid_review} = VoiceLabReviews.save(payload, path))

    refute File.exists?(path)
  end

  test "accepts optional notes without forcing ratings and reports storage failure", %{path: path} do
    assert {:ok, _time} = VoiceLabReviews.save(Map.put(review(), "ratings", %{}), path)

    assert {:error, :storage_failed} =
             VoiceLabReviews.save(review(), path <> "/cannot-write.jsonl")
  end

  test "recovery feedback separates voices and retains source, build, mode and run", %{path: path} do
    context = %{
      "view" => "recovery",
      "sample" => "mid_voice",
      "processor" => "mcadams",
      "parameters" => %{"alpha" => 0.9},
      "run_id" => "2026-10-24T22:32:00Z",
      "case_id" => "mid_voice_0_9",
      "headroom" => 0.25,
      "mode" => "approximate_inverse_capped",
      "source_id" => String.duplicate("b", 64),
      "build_id" => String.duplicate("c", 64)
    }

    payload = %{
      review()
      | "context" => context,
        "ratings" => %{
          "disguised" => %{"resemblance" => "different"},
          "recovered" => %{"resemblance" => "same"}
        }
    }

    assert {:ok, _time} = VoiceLabReviews.save(payload, path)
    saved = path |> File.read!() |> String.trim() |> JSON.decode!()
    assert saved["context"] == context
    assert saved["ratings"]["disguised"]["resemblance"] == "different"
    assert saved["ratings"]["recovered"]["resemblance"] == "same"
  end

  test "invalid controller submissions return an actionable error", %{conn: conn} do
    response = VoiceLabReviewsController.create(conn, %{})
    assert %{"error" => _message} = json_response(response, 422)
  end

  test "model reviews retain run provenance and reject invented attack results", %{path: path} do
    context = %{
      "view" => "model",
      "mode" => "average_voice_style",
      "processor" => "seed_vc_v2",
      "build_id" => String.duplicate("a", 64),
      "source_id" => String.duplicate("b", 64),
      "sample" => "high_voice",
      "case_id" => "high_voice",
      "run_id" => "2026-10-24T23:00:00Z"
    }

    payload = Map.put(review(), "context", context)
    assert {:ok, _time} = VoiceLabReviews.save(payload, path)

    for processor <- ~w(quality_pitch quality_resonance quality_both quality_tvtsyn) do
      matched = Map.merge(context, %{"processor" => processor, "mode" => "rms_matched"})
      assert {:ok, _time} = VoiceLabReviews.save(Map.put(payload, "context", matched), path)

      assert {:error, :invalid_review} =
               VoiceLabReviews.save(
                 Map.put(payload, "context", Map.put(matched, "mode", "native_onnx")),
                 path
               )
    end

    for processor <- ~w(world_control world_pitch world_formants world_texture) do
      dsp = Map.merge(context, %{"processor" => processor, "mode" => "model_free_dsp"})
      assert {:ok, _time} = VoiceLabReviews.save(Map.put(payload, "context", dsp), path)

      assert {:error, :invalid_review} =
               VoiceLabReviews.save(
                 Map.put(payload, "context", Map.put(dsp, "mode", "native_onnx")),
                 path
               )
    end

    for processor <- ~w(gentle_current_pitch gentle_half_pitch gentle_zero_pitch) do
      gentle = Map.merge(context, %{"processor" => processor, "mode" => "gentle_pitch"})
      assert {:ok, _time} = VoiceLabReviews.save(Map.put(payload, "context", gentle), path)
    end

    for processor <- ~w(preferred_spectral preferred_world) do
      engine = Map.merge(context, %{"processor" => processor, "mode" => "preferred_engines"})
      assert {:ok, _time} = VoiceLabReviews.save(Map.put(payload, "context", engine), path)
    end

    for processor <- ~w(spectral_more_pitch spectral_more_resonance spectral_opposing) do
      round = Map.merge(context, %{"processor" => processor, "mode" => "browser_dsp_round"})
      assert {:ok, _time} = VoiceLabReviews.save(Map.put(payload, "context", round), path)
    end

    for processor <- ~w(browser_world browser_spectral browser_time) do
      browser = Map.merge(context, %{"processor" => processor, "mode" => "browser_dsp"})
      assert {:ok, _time} = VoiceLabReviews.save(Map.put(payload, "context", browser), path)

      assert {:error, :invalid_review} =
               VoiceLabReviews.save(
                 Map.put(payload, "context", Map.put(browser, "mode", "chunked_world")),
                 path
               )
    end

    for size <- [40, 80, 160] do
      context =
        Map.merge(context, %{"processor" => "world_chunk_#{size}", "mode" => "chunked_world"})

      assert {:ok, _time} = VoiceLabReviews.save(Map.put(payload, "context", context), path)

      assert {:error, :invalid_review} =
               VoiceLabReviews.save(
                 Map.put(payload, "context", Map.put(context, "mode", "model_free_dsp")),
                 path
               )
    end

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(put_in(payload, ["context", "mode"], "recovered"), path)

    assert {:error, :invalid_review} =
             VoiceLabReviews.save(
               put_in(payload, ["ratings", "recovered"], %{"resemblance" => "same"}),
               path
             )
  end
end
