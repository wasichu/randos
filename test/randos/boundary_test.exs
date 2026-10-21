defmodule Randos.BoundaryTest do
  @moduledoc """
  The core (`Randos.*`) never calls the web layer (`RandosWeb.*`): the web
  layer is a shell over the core, not the other way round (AGENTS.md's
  layer table). Checked on the compiled code, so it sees every remote call
  and ignores mentions in docs. `Randos.Application` is exempt: it starts
  everything, the web layer included.

  This does what the `boundary` library would for our one rule, without a
  dependency.
  """
  use ExUnit.Case, async: true

  @exempt [Randos.Application]

  test "no core module calls the web layer" do
    {:ok, modules} = :application.get_key(:randos, :modules)

    core = Enum.filter(modules, &core?/1) -- @exempt
    assert core != [], "found no core modules to check"

    offenders =
      for module <- core,
          called <- calls(module),
          web?(called),
          do: {module, called}

    assert offenders == [],
           "the core calls the web layer:\n" <>
             Enum.map_join(offenders, "\n", fn {m, c} -> "  #{inspect(m)} → #{inspect(c)}" end)
  end

  # Core by where it lives (lib/randos/), so test support compiled into the
  # app (test/support/, like Randos.FakeTurn) isn't counted.
  @core_dir Path.expand("../../lib/randos", __DIR__)

  defp core?(module) do
    source = module.module_info(:compile)[:source] |> to_string()
    String.starts_with?(source, @core_dir <> "/")
  end

  defp web?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.RandosWeb")

  # The modules `module` calls, from its compiled import table.
  defp calls(module) do
    {^module, beam, _path} = :code.get_object_code(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports |> Enum.map(fn {called, _function, _arity} -> called end) |> Enum.uniq()
  end
end
