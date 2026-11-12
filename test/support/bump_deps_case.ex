defmodule Meerkat.BumpDepsCase do
  @moduledoc """
  Shared fixture and helpers for the tests that commit or rebase through the
  repo's real lefthook.yml and the scripts `build_fixture/1` copies. Only mix,
  pnpm, bun, bunx and curl are replaced, by stubs on PATH (the bun stub hands
  hex-cooldown.ts, rebase-bump.ts and e2e-inputs.ts to the real bun), plus the fixture's own
  mix-test.sh, mutate.sh and dep-exemptions.json: the stubs log each run,
  report the outdated packages a test sets up, and record an update by
  appending a line to the lockfile or manifest it would change. The tests are
  split across files to keep each file's BEAM time down.
  """

  import Meerkat.TestHelpers, only: [git: 2, hook_env: 0]

  @mix_exs """
  defmodule Fixture.MixProject do
    use Mix.Project

    defp deps do
      [
        {:bandit, "~> 1.11.0"},
        {:jason, "~> 1.2"},
        {:plug, "~> 1.0"}
      ]
    end
  end
  """

  @hex_header "Dependency  Only  Current  Latest  Status\n"

  @hex_behind @hex_header <>
                """
                bandit            1.11.0   1.12.5  Update not possible
                jason             1.4.3    1.4.5   Update possible
                plug              1.20.3   2.1.0   Update not possible
                mdex              0.14.1   0.14.1  Up-to-date
                """

  @old "2020-01-01T00:00:00.000000Z"

  @dep_files ~w(mix.exs mix.lock package.json pnpm-lock.yaml assets/package.json)

  defmacro __using__(_opts) do
    quote do
      use Meerkat.Case, async: false

      import Meerkat.TestHelpers, only: [git: 2, stage: 3]
      import Meerkat.BumpDepsCase

      # Built once, then copied for each test.
      setup_all do
        template =
          Meerkat.TestHelpers.fixture_template("meerkat-bump-deps-template", &build_fixture/1)

        {:ok, template: template}
      end

      setup %{template: template} do
        {:ok, fixture_paths(Meerkat.TestHelpers.copy_fixture(template, "meerkat-bump-deps"))}
      end
    end
  end

  def mix_exs, do: @mix_exs
  def hex_header, do: @hex_header
  def hex_behind, do: @hex_behind

  def fixture_paths(base) do
    [
      work: Path.join(base, "work"),
      stubs: Path.join(base, "stubs"),
      log: Path.join(base, "log"),
      hex_out: Path.join(base, "hex.out"),
      pnpm_out: Path.join(base, "pnpm.json"),
      seen: Path.join(base, "seen"),
      fail_update: Path.join(base, "fail-update"),
      npm_latest: Path.join(base, "npm-latest"),
      refuse: Path.join(base, "refuse"),
      fail_get: Path.join(base, "fail-deps-get"),
      fail_install: Path.join(base, "fail-pnpm-install"),
      git_env: Path.join(base, "git-env"),
      hex_api: Path.join(base, "hex-api")
    ]
  end

  def build_fixture(base) do
    %{
      work: work,
      stubs: stubs,
      log: log,
      hex_out: hex_out,
      pnpm_out: pnpm_out,
      seen: seen,
      fail_update: fail_update,
      npm_latest: npm_latest,
      refuse: refuse,
      fail_get: fail_get,
      fail_install: fail_install,
      git_env: git_env,
      hex_api: hex_api
    } = Map.new(fixture_paths(base))

    synced = Path.join(base, "deps-synced")
    # Read at run time, not compile time: a compiled module copied from
    # another checkout's _build would otherwise copy that checkout's scripts.
    root = File.cwd!()

    File.mkdir_p!(Path.join(work, "scripts"))
    git(base, ["init", "-q", "--initial-branch=main", work])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])

    File.cp!(Path.join(root, "lefthook.yml"), Path.join(work, "lefthook.yml"))

    for script <-
          ~w(check.sh checked-trees.sh e2e-inputs.ts no-main-commits.sh bump-deps.sh
             bump-hex-requirements.exs deps-common.sh gate-lock.sh hex-cooldown.ts rebase-bump.ts) do
      File.cp!(Path.join([root, "scripts", script]), Path.join([work, "scripts", script]))
    end

    # Fixed rather than copied, so a new upstream release cannot change it.
    File.write!(
      Path.join([work, "scripts", "dep-exemptions.json"]),
      ~s({"shiki": {"version": "4.4.3", "reason": "upstream needs shiki 3"}})
    )

    # These tests cover the dependency bump, not the runner; keep the fixture's
    # runner as `exec mix test` so check.sh's test step is logged as `mix test`.
    File.write!(Path.join([work, "scripts", "mix-test.sh"]), "exec mix test\n")
    # test/scripts/pre_commit_test.exs covers the mutation gate.
    File.write!(Path.join([work, "scripts", "mutate.sh"]), "exit 0\n")

    File.write!(Path.join(work, ".gitignore"), "node_modules\n")
    File.write!(Path.join(work, "mix.exs"), @mix_exs)

    for file <-
          ~w(mix.lock package.json pnpm-workspace.yaml pnpm-lock.yaml assets/package.json code.txt
             .tool-versions .github/toolchain.env .github/actions/toolchain/action.yml) do
      File.mkdir_p!(Path.dirname(Path.join(work, file)))
      File.write!(Path.join(work, file), "base\n")
    end

    git(work, ["add", "-A"])
    no_hooks(work, ["commit", "-qm", "base"])
    no_hooks(work, ["switch", "-q", "-c", "feature"])

    Meerkat.TestHelpers.install_lefthook(work)

    File.write!(hex_out, @hex_header <> "mdex  0.14.1  0.14.1  Up-to-date\n")
    File.write!(pnpm_out, "{}")

    File.mkdir_p!(stubs)
    File.mkdir_p!(npm_latest)
    File.mkdir_p!(refuse)

    # Like real deps/ before deps.get has fetched the locked versions,
    # hex.outdated aborts until deps.get has run.
    File.write!(Path.join(stubs, "stub"), """
    #!/usr/bin/env bash
    cmd="$(basename "$0") $*"
    # The real bun judges which paths are e2e inputs.
    case "$cmd" in
      "bun "*e2e-inputs.ts*) exec '#{System.find_executable("bun")}' "$@" ;;
    esac
    echo "$cmd" >> '#{log}'
    case "$cmd" in
      "mix deps.get --check-locked" | "pnpm install --frozen-lockfile "*)
        echo "$cmd: ${GIT_INDEX_FILE-unset}" >> '#{git_env}'
        if [[ "$1" == deps.get && -e '#{fail_get}' ]]; then echo "** (Mix) lock would change"; exit 1; fi
        if [[ "$1" == install && -e '#{fail_install}' ]]; then echo "ERR_PNPM_OUTDATED_LOCKFILE"; exit 1; fi
        if [[ "$1" == deps.get ]]; then touch '#{synced}'; fi ;;
      "mix hex.outdated")
        if [[ ! -e '#{synced}' ]]; then
          echo "  lock mismatch: the dependency is out of date. To fetch locked version run \\"mix deps.get\\""
          echo "** (Mix) Can't continue due to errors on dependencies"
          exit 1
        fi
        cat '#{hex_out}'; exit 1 ;;
      "curl "*/api/packages/*) url="${@: -1}"; cat '#{hex_api}'/"${url##*/}.json" ;;
      "mix deps.update "*)
        [[ -e '#{fail_update}' ]] && exit 1
        echo "updated ${cmd#mix deps.update }" >> mix.lock ;;
      "pnpm -r outdated --format json")
        echo " WARN  deprecated subdependency" >&2
        cat '#{pnpm_out}'; exit 1 ;;
      "pnpm view "*" dist-tags.latest")
        if [[ -e '#{npm_latest}'/"$2" ]]; then cat '#{npm_latest}'/"$2"
        else jq -r --arg n "$2" '.[$n].latest' '#{pnpm_out}'; fi ;;
      "pnpm -r update --latest --lockfile-only --ignore-scripts "*)
        # Only a scratch copy of the workspace, without the repo's scripts/.
        [[ ! -e scripts && -f package.json && -f pnpm-workspace.yaml && -f pnpm-lock.yaml &&
           -f assets/package.json && -L deps ]] || { echo "not a scratch workspace copy"; exit 1; }
        echo "updated $6" | tee -a package.json >> pnpm-lock.yaml
        if [[ -e '#{refuse}'/"$6" ]]; then cat '#{refuse}'/"$6"; exit 1; fi ;;
      "pnpm -r update --latest --ignore-scripts "*)
        names="${cmd#pnpm -r update --latest --ignore-scripts }"
        echo "updated $names" >> package.json
        echo "updated $names" >> assets/package.json
        echo "updated $names" >> pnpm-lock.yaml ;;
      "mix compile --warnings-as-errors")
        cp mix.lock '#{seen}'
        if [[ -e '#{base}/fail-compile' ]]; then echo "compile failed"; exit 1; fi ;;
      "bun scripts/hex-cooldown.ts "*)
        # Run outside the work tree, whose placeholder package.json bun
        # would fail to parse.
        cp "$1" '#{base}/hex-cooldown.ts' && cd '#{base}' &&
          exec '#{System.find_executable("bun")}' hex-cooldown.ts "${@:2}" ;;
      "bun scripts/rebase-bump.ts "*) exec '#{System.find_executable("bun")}' "$@" ;;
      "bun scripts/age-excludes.ts prune")
        if [[ -e '#{base}/fail-age-excludes.ts' ]]; then echo "$1 failed"; exit 1; fi
        if [[ -e '#{base}/excludes-stale' ]]; then echo "pruned" >> pnpm-workspace.yaml; fi ;;
      "bun scripts/advisory-fixes.ts" | "bun scripts/toolchain.ts bump" | "bun scripts/setup-toolchain.ts")
        if [[ -e '#{base}/fail-'"${1#scripts/}" ]]; then echo "$1 failed"; exit 1; fi
        if [[ "$1" == scripts/toolchain.ts && -e '#{base}/toolchain-behind' ]]; then
          echo "bun 9.9.9" >> .tool-versions
          echo "bumped" >> .github/actions/toolchain/action.yml
        fi ;;
    esac
    """)

    File.chmod!(Path.join(stubs, "stub"), 0o755)
    for tool <- ~w(mix pnpm bun bunx curl), do: File.ln_s!("stub", Path.join(stubs, tool))

    # hex.pm's records of the releases the requirements exclude, all
    # published long ago.
    File.mkdir_p!(hex_api)

    for {name, version} <- [{"bandit", "1.12.5"}, {"plug", "2.1.0"}, {"jason", "1.4.5"}] do
      File.write!(Path.join(hex_api, name <> ".json"), releases(version, @old))
    end
  end

  def commit(ctx, args), do: hooked(ctx, ["commit", "-q" | args])

  @doc "Runs git with the repo's hooks and the stubs on PATH."
  def hooked(ctx, args) do
    path = ctx.stubs <> ":" <> System.fetch_env!("PATH")

    System.cmd("git", args,
      cd: ctx.work,
      env: [{"PATH", path} | hook_env()],
      stderr_to_stdout: true
    )
  end

  def releases(version, inserted_at),
    do: Jason.encode!(%{"releases" => [%{"version" => version, "inserted_at" => inserted_at}]})

  def committed(ctx, file), do: git(ctx.work, ["show", "HEAD:#{file}"]) <> "\n"

  def changed_files(ctx) do
    ctx.work
    |> git(["diff", "--name-only", "HEAD~1", "HEAD", "--" | @dep_files ++ ["code.txt"]])
    |> String.split("\n", trim: true)
  end

  def run(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  def no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])
end
