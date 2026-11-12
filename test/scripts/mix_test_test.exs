defmodule Meerkat.MixTestScriptTest do
  # The seams of scripts/mix-test.ts, whose logic scripts/mix-test.test.ts
  # covers: a real run of it against a tiny Mix project, and the test-file
  # slots scripts/run-test-file.sh holds while a stub mix runs. Both work in
  # one temporary git repo holding the repo's real scripts.
  use ExUnit.Case, async: true

  @root File.cwd!()

  # Records each time Mix loads it the run's arguments, MIX_ENV,
  # ELIXIR_ERL_OPTIONS, MIX_OS_CONCURRENCY_LOCK and the BEAM's schedulers.
  @mix_exs ~S"""
  defmodule Fixture.MixProject do
    use Mix.Project

    File.write!(
      Path.join(__DIR__, "loads"),
      Enum.join(
        [
          inspect(System.argv()),
          System.get_env("MIX_ENV"),
          System.get_env("ELIXIR_ERL_OPTIONS", "unset"),
          System.get_env("MIX_OS_CONCURRENCY_LOCK", "unset"),
          :erlang.system_info(:schedulers)
        ],
        " | "
      ) <> "\n",
      [:append]
    )

    def project, do: [app: :fixture, version: "0.1.0"]
  end
  """

  # Passes on its first run only, so the run again that its time limit
  # forces fails.
  @once_test ~S"""
  defmodule OnceTest do
    use ExUnit.Case, async: true

    test "runs once" do
      refute File.exists?("ran"), "ran again"
      File.write!("ran", "")
    end
  end
  """

  setup_all do
    base = Meerkat.TestHelpers.make_git_repo("meerkat-mix-test")
    on_exit(fn -> File.rm_rf!(base) end)

    File.mkdir_p!(Path.join(base, "scripts"))

    for script <- ~w(mix-test.ts run-test-file.sh gate-lock.sh) do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([base, "scripts", script]))
    end

    {:ok, base: base}
  end

  test "runs each test file in its own real mix test, and a slow one again", %{base: base} do
    # Paths that differ only in their slashes.
    write(
      base,
      "test/x/y_z_test.exs",
      "defmodule YZTest do\n  use ExUnit.Case, async: true\n  test \"passes\", do: :ok\nend\n"
    )

    write(base, "test/x_y/z_test.exs", @once_test)
    write(base, "test/test_helper.exs", "ExUnit.start()\n")
    write(base, "mix.exs", @mix_exs)

    write(
      base,
      "scripts/test-file-limit.json",
      Jason.encode!(%{
        limit_seconds: 60,
        cpu_limit_seconds: 0.001,
        exempt: %{"test/x/y_z_test.exs" => %{reason: "only z_test.exs is judged"}}
      })
    )

    assert {out, 1} =
             cmd(base, "bun", ["scripts/mix-test.ts"], [
               {"MIX_ENV", "dev"},
               {"ELIXIR_ERL_OPTIONS", "+S 2"}
             ])

    assert out =~ ~r"  test/x_y/z_test.exs: \d+\.\d s beside others; failed when run again\n"
    assert out =~ ~r"=== mix test test/x_y/z_test.exs, run again ===\n.*ran again"s
    assert out =~ "a test file run again failed."
    refute out =~ "x/y_z_test.exs"

    test_run = fn file ->
      ~s(["test", "--no-compile", "#{file}"] | test | +S 4 +sbwt none +S 2 | 0 | 2)
    end

    assert [~s(["compile"] | test | +S 2 | unset | 2) | tests] = lines(Path.join(base, "loads"))

    assert Enum.sort(tests) ==
             Enum.sort([
               test_run.("test/x/y_z_test.exs"),
               test_run.("test/x_y/z_test.exs"),
               test_run.("test/x_y/z_test.exs")
             ])
  end

  test "runs share the test-file slots, which mix test does not hold", %{base: base} do
    dir = Path.join(base, "slots")
    stubs = Path.join(dir, "stubs")
    File.mkdir_p!(stubs)

    File.write!(Path.join(stubs, "mix"), """
    #!/usr/bin/env bash
    echo "$* | ${ELIXIR_ERL_OPTIONS-unset} | ${MIX_OS_CONCURRENCY_LOCK-unset}" >> '#{dir}/runs'
    if [ -e /dev/fd/9 ]; then echo "$3" >> '#{dir}/slot_fd'; fi
    echo start >> '#{dir}/spans'
    sleep 0.5
    echo end >> '#{dir}/spans'
    """)

    File.chmod!(Path.join(stubs, "mix"), 0o755)

    files = for n <- 1..3, do: "test/#{n}_test.exs"

    runs =
      for file <- files do
        secs = Path.join(dir, Path.basename(file) <> ".secs")

        Task.async(fn ->
          {cmd(base, "bash", ["scripts/run-test-file.sh", "2", file, secs], [], stubs), secs}
        end)
      end

    secs = for {{out, status}, secs} <- Task.await_many(runs, :infinity), do: {status, out, secs}

    assert Enum.sort(lines(Path.join(dir, "runs"))) ==
             for(file <- files, do: "test --no-compile #{file} | +S 4 +sbwt none  | 0")

    assert most_at_once(Path.join(dir, "spans")) == 2
    refute File.exists?(Path.join(dir, "slot_fd"))

    # Why six decimals: see TIMEFORMAT in scripts/run-test-file.sh.
    {version, 0} = System.cmd("bash", ["-c", "echo ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"])
    [major, minor] = version |> String.split() |> Enum.map(&String.to_integer/1)
    digits = if {major, minor} >= {5, 3}, do: 6, else: 3

    for {status, out, secs} <- secs do
      assert status == 0, out
      assert File.read!(secs) =~ ~r/\A(\d+[.,]\d{#{digits}} ){2}\d+[.,]\d{#{digits}}\n\z/
    end
  end

  defp write(base, file, content) do
    File.mkdir_p!(Path.dirname(Path.join(base, file)))
    File.write!(Path.join(base, file), content)
  end

  # This suite's own runner may have set ELIXIR_ERL_OPTIONS and
  # MIX_OS_CONCURRENCY_LOCK, and CI sets CI. hook_env/0 keeps the test-file
  # slots in the fixture's repo when this suite runs in a hook.
  defp cmd(base, command, args, env, stubs \\ nil) do
    path =
      if stubs, do: stubs <> ":" <> System.fetch_env!("PATH"), else: System.fetch_env!("PATH")

    env =
      Map.merge(
        %{"ELIXIR_ERL_OPTIONS" => nil, "MIX_OS_CONCURRENCY_LOCK" => nil, "CI" => nil},
        Map.new(env)
      )

    System.cmd(command, args,
      cd: base,
      env: [{"PATH", path} | Enum.to_list(env)] ++ Meerkat.TestHelpers.hook_env(),
      stderr_to_stdout: true
    )
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  defp most_at_once(spans) do
    spans
    |> lines()
    |> Enum.scan(0, fn
      "start", running -> running + 1
      "end", running -> running - 1
    end)
    |> Enum.max()
  end
end
