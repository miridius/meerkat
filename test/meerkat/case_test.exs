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

  # A synchronous module on ExUnit.Case would skip the global-state check, and
  # a leak there would fail whichever module the run happened to order next.
  test "every synchronous test module uses Meerkat.Case or a template built on it" do
    offenders =
      for file <- Path.wildcard("test/**/*_test.exs"),
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/^\s*use ExUnit\.Case\b/ and not (line =~ ~r/async: true/),
          do: "#{file}:#{n}"

    assert offenders == []
  end
end
