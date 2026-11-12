defmodule Meerkat.BumpHexRequirementsTest do
  # Runs the real scripts/bump-hex-requirements.exs on a mix.exs each test
  # writes.
  use ExUnit.Case, async: true

  @script Path.expand("scripts/bump-hex-requirements.exs")

  @mix_exs """
  defp deps do
    [
      # {:bandit, "~> 1.0"},
      {:bandit, "~> 1.11.0"},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.0"}
    ]
  end
  """

  setup do
    dir = Meerkat.TestHelpers.tmp_path("meerkat-hex-requirements")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "moves each excluding ~> requirement to the release, keeping its precision", ctx do
    assert {out, 0} = bump(ctx, @mix_exs, ~w(bandit 1.12.5 jason 1.4.5 plug 2.1.0))

    assert out =~ ~s(mix.exs bandit "~> 1.11.0" -> "~> 1.12.5")
    assert out =~ ~s(jason "~> 1.2" allows 1.4.5; another dependency holds it back)
    assert out =~ ~s(mix.exs plug "~> 1.0" -> "~> 2.1")

    assert File.read!(Path.join(ctx.dir, "mix.exs")) ==
             @mix_exs
             |> String.replace(~s({:bandit, "~> 1.11.0"}), ~s({:bandit, "~> 1.12.5"}))
             |> String.replace(~s({:plug, "~> 1.0"}), ~s({:plug, "~> 2.1"}))
  end

  test "refuses a requirement it cannot move, naming it", ctx do
    for {mix_exs, message} <- [
          {String.replace(@mix_exs, "~> 1.0", "== 1.0.0"),
           ~s(mix.exs plug "== 1.0.0" excludes 2.1.0; edit the requirement by hand.)},
          {String.replace(@mix_exs, "{:plug", "{:plugs"),
           ~s(mix.exs has no {:plug, "<requirement>"} entry to move to 2.1.0.)},
          {String.replace(@mix_exs, "~> 1.0", "~>> 1.0"),
           ~s(mix.exs plug "~>> 1.0" is not a valid requirement.)}
        ] do
      assert {out, 1} = bump(ctx, mix_exs, ~w(plug 2.1.0))
      assert out =~ "pre-commit: " <> message
      assert File.read!(Path.join(ctx.dir, "mix.exs")) == mix_exs
    end
  end

  defp bump(ctx, mix_exs, args) do
    File.write!(Path.join(ctx.dir, "mix.exs"), mix_exs)
    System.cmd("elixir", [@script | args], cd: ctx.dir, stderr_to_stdout: true)
  end
end
