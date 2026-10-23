defmodule Tui.LanguageTest do
  use ExUnit.Case, async: true

  alias Tui.Language

  test "the environment's locale names a language: LC_ALL, then LC_MESSAGES, then LANG" do
    assert Language.from_env(%{"LANG" => "es_ES.UTF-8"}) == "es"
    assert Language.from_env(%{"LANG" => "de_DE", "LC_ALL" => "pt_BR.UTF-8"}) == "pt"
    assert Language.from_env(%{"LANG" => "fr_FR", "LC_MESSAGES" => "ja_JP"}) == "ja"
    assert Language.from_env(%{"LANG" => "sr_RS@latin"}) == "sr"
    # Filipino goes by Tagalog's code on many systems.
    assert Language.from_env(%{"LANG" => "tl_PH.UTF-8"}) == "fil"
    assert Language.from_env(%{"LANG" => "C"}) == nil
    assert Language.from_env(%{"LANG" => ""}) == nil
    assert Language.from_env(%{}) == nil
  end

  test "the saved language wins, then the environment's, then English; only ones the TUI has" do
    # Without translations compiled in, English is all there is.
    assert Language.resolve("xx", %{"LANG" => "yy_YY"}) == "en"
    assert Language.resolve(nil, %{}) == "en"
    assert Language.resolve("en", %{"LANG" => "es_ES"}) in Language.available()
  end

  test "l cycles through the languages, wrapping" do
    languages = Language.available()
    assert hd(languages) == "en"
    assert Language.next(List.last(languages)) == "en"
    assert Language.next("not-one") == "en"
  end
end
