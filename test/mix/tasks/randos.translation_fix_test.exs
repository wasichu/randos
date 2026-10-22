defmodule Mix.Tasks.Randos.TranslationFixTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Randos.TranslationFix

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "es")
    File.mkdir_p!(Path.join(dir, "LC_MESSAGES"))
    path = Path.join([dir, "LC_MESSAGES", "default.po"])
    File.cp!("priv/gettext/es/LC_MESSAGES/default.po", path)
    %{dir: dir, path: path, before: File.read!(path)}
  end

  test "one entry changes, and nothing else in the file", %{dir: dir, path: path, before: before} do
    assert :ok =
             TranslationFix.apply_fix(dir, %{
               "msgid" => "Continue",
               "msgctxt" => "button",
               "msgstr" => "Seguir"
             })

    changed =
      List.myers_difference(String.split(before, "\n"), String.split(File.read!(path), "\n"))

    assert [{:del, [old]}, {:ins, ["msgstr \"Seguir\""]}] = Keyword.drop(changed, [:eq])
    assert String.starts_with?(old, "msgstr ")
  end

  test "the context tells same-text entries apart, and a missing one is an error", %{dir: dir} do
    assert {:error, "no entry \"Continue\" (context nil)" <> _} =
             TranslationFix.apply_fix(dir, %{
               "msgid" => "Continue",
               "msgctxt" => nil,
               "msgstr" => "x"
             })

    assert {:error, _} =
             TranslationFix.apply_fix(dir, %{"msgid" => "Not a string", "msgstr" => "x"})
  end
end
