defmodule Meerkat.E2eInputsTest do
  # Runs the repo's real scripts/e2e-inputs.ts, which decides which paths
  # check.sh may skip the e2e steps for.
  use ExUnit.Case, async: true

  @root File.cwd!()

  @not_inputs ~w(
    README.md
    docs/features/cli.md
    test/scripts/pre_commit_test.exs
    test/support/test_helpers.ex
    scripts/mix-test.ts
    scripts/check.sh.bak
    scripts/checked-trees.sh
    .github/workflows/ci.yml
    .lefthook/pre-push/pre-push.sh
    lefthook.yml
    .claude/settings.json
    .worktreeinclude
    .formatter.exs
    biome.json
    LICENSE
  )

  @inputs ~w(
    scripts/check.sh
    scripts/e2e-inputs.ts
    lib/meerkat/git.ex
    config/dev.exs
    assets/svelte/DiffViewer.svelte
    bin/meerkat-beam
    tests/e2e/decision.spec.ts
    tests/e2e/lib/setup.ts
    test/support/test.gitconfig
    .github/toolchain.env
    playwright.config.ts
    mix.exs
    mix.lock
    package.json
    pnpm-lock.yaml
    .gitignore
    .gitattributes
    new-file.txt
    contest/x
    my-scripts/x.sh
    lefthook.yml.bak
    LICENSE.txt
    sub/biome.json
  )

  test "prints the paths the e2e run may use, and only those" do
    assert run(Enum.join(@not_inputs ++ @inputs, "\n") <> "\n") ==
             {Enum.join(@inputs, "\n") <> "\n", 0}
  end

  test "reads the path of a git ls-tree entry after its tab" do
    tree = """
    100644 blob 0123456789abcdef0123456789abcdef01234567\ttest/x_test.exs
    100644 blob 0123456789abcdef0123456789abcdef01234567\tlib/x.ex
    """

    assert run(tree) ==
             {"100644 blob 0123456789abcdef0123456789abcdef01234567\tlib/x.ex\n", 0}
  end

  test "--none exits 0 when no path is an e2e input" do
    assert run(Enum.join(@not_inputs, "\n"), ["--none"]) == {"", 0}
  end

  test "--none exits 1 when any path is an e2e input" do
    assert run("test/x_test.exs\nlib/x.ex\n", ["--none"]) == {"", 1}
  end

  # Catches the allowlist drifting over a file the e2e run reads: every
  # tracked path a quoted string containing `/` in the e2e suite or its config
  # names, as written or relative to that file, must count as an e2e input.
  test "every repo path the e2e suite names is an e2e input" do
    tracked = String.split(Meerkat.TestHelpers.git(@root, ["ls-files"]), "\n", trim: true)

    sources = [
      "playwright.config.ts" | Enum.filter(tracked, &String.starts_with?(&1, "tests/e2e/"))
    ]

    named =
      for source <- sources,
          text = File.read!(Path.join(@root, source)),
          [_, literal] <- Regex.scan(~r/["'`]([^"'`\s]*\/[^"'`\s]*)["'`]/, text),
          dir = Path.join(@root, Path.dirname(source)),
          path <- [literal, Path.relative_to(Path.expand(literal, dir), @root)],
          file <- tracked,
          file == path or String.starts_with?(file, String.trim_trailing(path, "/") <> "/"),
          uniq: true,
          do: file

    # The scan finds the one path outside tests/e2e/ the fixture reads.
    assert "test/support/test.gitconfig" in named
    assert run(Enum.join(named, "\n") <> "\n") == {Enum.join(named, "\n") <> "\n", 0}
  end

  defp run(stdin, args \\ []) do
    System.cmd("bash", ["-c", ~s(printf %s "$0" | bun scripts/e2e-inputs.ts "$@"), stdin | args])
  end
end
