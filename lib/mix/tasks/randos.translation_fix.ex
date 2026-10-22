defmodule Mix.Tasks.Randos.TranslationFix do
  @shortdoc "Applies one checked translation fix to its .po file"
  @moduledoc """
      mix randos.translation_fix FIX.json

  Sets one entry's `msgstr` in `priv/gettext/<locale>/LC_MESSAGES/default.po`.
  `FIX.json` comes from `tools/translate`'s `randos_translate.issue_fix`
  (`locale`, `msgid`, `msgctxt`, `msgstr`), which has already checked it;
  the translation-fix workflow runs the two in turn. Written with Expo,
  as `mix gettext.merge` writes, so the diff is that one entry.

  It records nothing in `tools/translate/state`, so the shootout treats the
  text as a person's and never overwrites it.
  """
  use Mix.Task

  @impl Mix.Task
  def run([path]) do
    fix = path |> File.read!() |> JSON.decode!()

    case apply_fix(Path.join("priv/gettext", fix["locale"]), fix) do
      :ok -> Mix.shell().info("#{fix["locale"]}: #{inspect(fix["msgid"])} updated")
      {:error, why} -> Mix.raise(why)
    end
  end

  def run(_args), do: Mix.raise("usage: mix randos.translation_fix FIX.json")

  @doc "Sets the entry's msgstr in `<dir>/LC_MESSAGES/default.po`."
  @spec apply_fix(Path.t(), map()) :: :ok | {:error, String.t()}
  def apply_fix(dir, %{"msgid" => msgid, "msgstr" => msgstr} = fix) do
    path = Path.join([dir, "LC_MESSAGES", "default.po"])
    po = Expo.PO.parse_file!(path)
    context = fix["msgctxt"]

    case Enum.find_index(po.messages, &same_entry?(&1, msgid, context)) do
      nil ->
        {:error, "no entry #{inspect(msgid)} (context #{inspect(context)}) in #{path}"}

      index ->
        messages = List.update_at(po.messages, index, &%{&1 | msgstr: [msgstr]})
        File.write!(path, Expo.PO.compose(%{po | messages: messages}))
    end
  end

  defp same_entry?(%Expo.Message.Singular{} = message, msgid, context),
    do: text(message.msgid) == msgid and text(message.msgctxt) == context

  defp same_entry?(_plural, _msgid, _context), do: false

  defp text(nil), do: nil
  defp text(iodata), do: IO.iodata_to_binary(iodata)
end
