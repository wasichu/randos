defmodule Randos.ConversationLanguagesTest do
  use ExUnit.Case

  alias Randos.ConversationLanguages

  test "returns the intentionally limited global language set" do
    assert ConversationLanguages.all() == [
             {"English (EN)", "en"},
             {"Español (ES)", "es"},
             {"中文 (ZH)", "zh"},
             {"हिन्दी (HI)", "hi"},
             {"العربية (AR)", "ar"},
             {"Português (PT)", "pt"},
             {"বাংলা (BN)", "bn"},
             {"Русский (RU)", "ru"},
             {"日本語 (JA)", "ja"},
             {"Français (FR)", "fr"},
             {"Deutsch (DE)", "de"},
             {"한국어 (KO)", "ko"},
             {"Italiano (IT)", "it"},
             {"Türkçe (TR)", "tr"},
             {"Bahasa Indonesia (ID)", "id"}
           ]
  end

  test "returns stable internal language codes" do
    assert ConversationLanguages.codes() == [
             "en",
             "es",
             "zh",
             "hi",
             "ar",
             "pt",
             "bn",
             "ru",
             "ja",
             "fr",
             "de",
             "ko",
             "it",
             "tr",
             "id"
           ]
  end

  test "checks supported stable internal language codes" do
    assert ConversationLanguages.supported?("ja")
    refute ConversationLanguages.supported?("zz")
  end

  test "looks up display labels by code" do
    assert ConversationLanguages.name("pt") == "Português (PT)"
    assert ConversationLanguages.name("zz") == "zz"
  end

  test "normalizes browser locales into supported language codes" do
    assert ConversationLanguages.code_from_locale("en-US") == "en"
    assert ConversationLanguages.code_from_locale("es-MX") == "es"
    assert ConversationLanguages.code_from_locale("pt-BR") == "pt"
    assert ConversationLanguages.code_from_locale("ja-JP") == "ja"
    assert ConversationLanguages.code_from_locale("zh_Hans_CN") == "zh"
    assert ConversationLanguages.code_from_locale("tl-PH") == "en"
    assert ConversationLanguages.code_from_locale(nil) == "en"
  end
end
