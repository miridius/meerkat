defmodule Meerkat.CaseTest do
  use ExUnit.Case, async: true

  alias Meerkat.Case

  @state %{app_env: %{repo_path: "/r"}, os_env: %{"TOKEN" => "secret"}, cwd: "/w"}

  describe "changes/2" do
    test "names each changed application env key, OS variable and the working directory" do
      now = %{app_env: %{review_id: "x"}, os_env: %{"TOKEN" => "other"}, cwd: "/elsewhere"}

      assert Case.changes(@state, now) == [
               "application env :meerkat key :repo_path",
               "application env :meerkat key :review_id",
               ~s(OS environment variable "TOKEN"),
               "working directory, now /elsewhere"
             ]
    end

    test "never includes an OS variable's value" do
      now = %{@state | os_env: %{"TOKEN" => "leaked"}}
      refute Enum.any?(Case.changes(@state, now), &(&1 =~ "secret" or &1 =~ "leaked"))
    end

    test "reports nothing for unchanged state" do
      assert Case.changes(@state, @state) == []
    end
  end

  test "global_state/0 counts an application env key set to nil as unset" do
    Application.put_env(:meerkat, :case_test_nil_key, nil)
    on_exit(fn -> Application.delete_env(:meerkat, :case_test_nil_key) end)

    refute Map.has_key?(Case.global_state().app_env, :case_test_nil_key)
  end

  test "assert_restored!/1 fails naming a key the test left changed" do
    before = Case.global_state()
    assert Case.assert_restored!(before) == :ok

    Application.put_env(:meerkat, :case_test_leaked_key, 1)
    on_exit(fn -> Application.delete_env(:meerkat, :case_test_leaked_key) end)

    assert_raise ExUnit.AssertionError, ~r/:case_test_leaked_key/, fn ->
      Case.assert_restored!(before)
    end
  end

  @test_dir Path.expand("..", __DIR__)

  # A synchronous module on ExUnit.Case would skip the global-state check, so
  # a leak there could fail a later test in another order.
  test "every synchronous test module uses Meerkat.Case or a template built on it" do
    files = Path.wildcard(Path.join(@test_dir, "**/*_test.exs"))
    assert Path.join(@test_dir, "meerkat/decision_test.exs") in files

    offenders =
      for file <- files,
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/^\s*use ExUnit\.Case\b/ and not (line =~ ~r/async: true/),
          do: "#{file}:#{n}"

    assert offenders == []
  end

  test "every other case template applies Meerkat.Case's isolation" do
    templates =
      for file <- Path.wildcard(Path.join(@test_dir, "support/*.ex")),
          Path.basename(file) != "case.ex",
          File.read!(file) =~ "use ExUnit.CaseTemplate",
          do: file

    assert templates != []

    for file <- templates do
      assert File.read!(file) =~ "Meerkat.Case.isolate_global_state(tags)", file
    end
  end
end
