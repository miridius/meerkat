defmodule Meerkat.PrePushHookTest do
  # Pushes through the repo's real lefthook.yml, .lefthook/pre-push/pre-push.ts
  # and scripts/no-private-refs.ts to a local bare remote: one test per seam
  # between git, lefthook and the hook. Only outdated.sh and verified-push.sh
  # are replaced, by stubs that record each run and exit with a chosen
  # status. The hook's and the scan's own logic is tested by
  # scripts/pre-push.test.ts and scripts/no-private-refs.test.ts;
  # test/scripts/verified_push_test.exs covers verified-push.sh.
  use Meerkat.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @root File.cwd!()

  # Assembled from pieces: this file is itself scanned before every push.
  @private_path "/Us" <> "ers/alice/notes"

  # Built once, then copied for each test.
  setup_all do
    template = Meerkat.TestHelpers.fixture_template("meerkat-pre-push-template", &build_fixture/1)
    {:ok, template: template}
  end

  setup %{template: template} do
    base = Meerkat.TestHelpers.copy_fixture(template, "meerkat-pre-push")

    {:ok,
     work: Path.join(base, "work"),
     marker: Path.join(base, "outdated-ran"),
     outdated_status: Path.join(base, "outdated-status"),
     verified_args: Path.join(base, "verified-push-args")}
  end

  defp build_fixture(base) do
    work = Path.join(base, "work")
    remote = Path.join(base, "remote.git")
    marker = Path.join(base, "outdated-ran")
    outdated_status = Path.join(base, "outdated-status")
    verified_args = Path.join(base, "verified-push-args")

    File.mkdir_p!(Path.join(work, "scripts"))
    File.mkdir_p!(Path.join(work, ".lefthook/pre-push"))
    git(base, ["init", "-q", "--bare", remote])
    git(work, ["init", "-q", "--initial-branch=main"])
    git(work, ["config", "user.email", "t@t.t"])
    git(work, ["config", "user.name", "t"])
    git(work, ["remote", "add", "origin", remote])

    private_refs = Path.join(work, ".git/info/private-refs")
    File.mkdir_p!(Path.dirname(private_refs))
    File.write!(private_refs, "# private names\n\n(^|[^a-z])acme-internal([^a-z]|$)\n")

    for file <- ~w(lefthook.yml .lefthook/pre-push/pre-push.ts scripts/no-private-refs.ts) do
      File.cp!(Path.join(@root, file), Path.join(work, file))
    end

    File.write!(Path.join([work, "scripts", "outdated.sh"]), """
    #!/usr/bin/env bash
    touch '#{marker}'
    exit "$(cat '#{outdated_status}' 2>/dev/null || echo 0)"
    """)

    File.write!(Path.join([work, "scripts", "verified-push.sh"]), """
    #!/usr/bin/env bash
    echo "$*" > '#{verified_args}'
    """)

    Meerkat.TestHelpers.install_lefthook(work)

    commit(work, "README.md", "hello\n", "base")
    no_hooks(work, ["push", "-q", "origin", "main"])
  end

  test "a push hands each new tip to the checks", ctx do
    commit(ctx.work, "a.txt", "a\n", "add a")
    first = git(ctx.work, ["rev-parse", "HEAD"])
    commit(ctx.work, "b.txt", "b\n", "add b")
    second = git(ctx.work, ["rev-parse", "HEAD"])

    assert {_, 0} =
             push(ctx.work, ["origin", "#{first}:refs/heads/one", "HEAD:refs/heads/two"])

    assert File.exists?(ctx.marker)
    tips = ctx.verified_args |> File.read!() |> String.split()
    assert Enum.sort(tips) == Enum.sort([first, second])
  end

  # lefthook skips a pre-push *command* when `git diff HEAD @{push}` is
  # empty, which is true of a force-push that changes only history. The
  # scan reads the push's refs and the URL pushed to from git.
  test "a force-push that only rewrites a commit message to hold a private reference is refused",
       ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "feature"])
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["-u", "origin", "feature"])
    File.rm!(ctx.marker)

    no_hooks(ctx.work, ["commit", "-q", "--amend", "-m", "copied from #{@private_path}"])
    sha = git(ctx.work, ["rev-parse", "HEAD"])

    assert {out, code} = push(ctx.work, ["--force", "origin", "feature"])
    assert code != 0
    assert out =~ "local absolute path in a commit, tag or ref name being pushed"
    assert out =~ "commit-#{sha}:"
    assert File.exists?(ctx.marker), "outdated.sh still runs when the other check fails"
  end

  test "deleting a remote branch skips the checks", ctx do
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    File.rm!(ctx.marker)
    File.write!(ctx.outdated_status, "1")

    assert {out, 0} = push(ctx.work, ["origin", "--delete", "feature"])
    assert out =~ "only deleting remote refs; skipping checks."
    refute File.exists?(ctx.marker)
  end

  test "a checkout without its own lefthook refuses the push", %{work: work, marker: marker} do
    File.rm_rf!(Path.join(work, "node_modules"))
    commit(work, "a.txt", "a\n", "add a")

    assert {_, code} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    refute File.exists?(marker)
  end

  # A UTF-8 locale, as in an interactive shell.
  defp push(work, args) do
    System.cmd("git", ["push" | args],
      cd: work,
      env: [{"LC_ALL", "C.UTF-8"} | hook_env()],
      stderr_to_stdout: true
    )
  end

  # Only pushes go through the hooks; other commands would fire lefthook's
  # post-checkout install, whose script this fixture leaves out.
  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])

  defp commit(work, name, content, message) do
    stage(work, name, content)
    no_hooks(work, ["commit", "-qm", message])
  end
end
