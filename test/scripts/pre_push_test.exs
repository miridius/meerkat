defmodule Meerkat.PrePushHookTest do
  # Pushes through the repo's real lefthook.yml, .lefthook/pre-push/pre-push.sh
  # and scripts/no-private-refs.sh to a local bare remote. Only outdated.sh is
  # replaced, by a stub that records each run and exits with a chosen status.
  use ExUnit.Case, async: false

  import Meerkat.TestHelpers, only: [git: 2, stage: 3, hook_env: 0]

  @root File.cwd!()

  # Assembled from pieces: this file is itself scanned before every push.
  @private_path "/Us" <> "ers/alice/notes"

  setup do
    Meerkat.TestHelpers.isolate_git_config()
    base = Meerkat.TestHelpers.make_tmp_repo("meerkat-pre-push")
    on_exit(fn -> File.rm_rf!(base) end)
    File.rm_rf!(Path.join(base, ".git"))

    work = Path.join(base, "work")
    remote = Path.join(base, "remote.git")
    marker = Path.join(base, "outdated-ran")
    outdated_status = Path.join(base, "outdated-status")

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

    for file <- ~w(lefthook.yml .lefthook/pre-push/pre-push.sh scripts/no-private-refs.sh) do
      File.cp!(Path.join(@root, file), Path.join(work, file))
    end

    File.write!(Path.join([work, "scripts", "outdated.sh"]), """
    #!/usr/bin/env bash
    touch '#{marker}'
    exit "$(cat '#{outdated_status}' 2>/dev/null || echo 0)"
    """)

    Meerkat.TestHelpers.install_lefthook(work)

    commit(work, "README.md", "hello\n", "base")
    no_hooks(work, ["push", "-q", "origin", "main"])

    {:ok,
     work: work, marker: marker, outdated_status: outdated_status, private_refs: private_refs}
  end

  test "a push of new commits runs the checks", %{work: work, marker: marker} do
    commit(work, "a.txt", "a\n", "add a")

    assert {_, 0} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert File.exists?(marker)
  end

  test "a failing check blocks the push", ctx do
    File.write!(ctx.outdated_status, "1")
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {_, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
  end

  test "a private reference on a branch other than the checked-out one blocks its push", ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "leaky"])
    commit(ctx.work, "notes.txt", "see #{@private_path}\n", "add notes")
    no_hooks(ctx.work, ["switch", "-q", "main"])

    assert {out, code} = push(ctx.work, ["origin", "leaky"])
    assert code != 0
    assert out =~ "local absolute path"
    assert File.exists?(ctx.marker), "outdated.sh still runs when the other check fails"
  end

  test "a private reference only in a commit message blocks the push and names the commit",
       %{work: work} do
    commit(work, "a.txt", "a\n", "copied from #{@private_path}")
    sha = git(work, ["rev-parse", "HEAD"])

    assert {out, code} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "local absolute path in a commit, tag or ref name being pushed"
    assert out =~ "commit-#{sha}:"
  end

  test "a pattern from the untracked private-refs file blocks the push", %{work: work} do
    commit(work, "notes.txt", "copied from the acme-internal wiki\n", "add notes")

    assert {out, code} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 3 of"
    assert out =~ "in a tracked file"
  end

  test "an empty private-refs file lets a clean push through", ctx do
    File.write!(ctx.private_refs, "")
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
  end

  test "a private pattern still blocks a match that ends in an allowed address", ctx do
    File.write!(ctx.private_refs, "acme-internal[^ ]*\n")
    commit(ctx.work, "a.txt", "acme-internal:ops@example.com\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 1 of"
  end

  test "a private-refs file with CRLF line endings still matches", ctx do
    File.write!(ctx.private_refs, "# private names\r\nacme-internal\r\n")
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 2 of"
  end

  test "a private-refs file with a byte-order mark still matches", ctx do
    File.write!(ctx.private_refs, <<0xEF, 0xBB, 0xBF>> <> "acme-internal\n")
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 1 of"
  end

  test "the last private pattern counts without a trailing newline", ctx do
    File.write!(ctx.private_refs, "acme-internal")
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 1 of"
  end

  test "a carriage return inside a private pattern refuses the push", ctx do
    File.write!(ctx.private_refs, "acme-internal\rzzz\r")
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "control character"
  end

  test "a missing private-refs file refuses the push", ctx do
    File.rm!(ctx.private_refs)
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "info/private-refs is missing"
  end

  test "an invalid regex in the private-refs file refuses the push and names its line", ctx do
    File.write!(ctx.private_refs, "# note\n\nacme(\n")
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "line 3 of"
    assert out =~ "a pattern is broken"
  end

  # git grep's ERE reads `\d` as a plain `d`, so the scan would silently
  # miss `acme1x`.
  test "a backslash escape in the private-refs file refuses the push", ctx do
    File.write!(ctx.private_refs, "acme\\dx\n")
    commit(ctx.work, "a.txt", "acme1x\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "line 1 of"
    assert out =~ "backslash escape"
  end

  test "a private pattern with trailing whitespace refuses the push", ctx do
    File.write!(ctx.private_refs, "acme-internal \n")
    commit(ctx.work, "a.txt", "acme-internal\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "whitespace"
  end

  test "an email address blocks the push unless it is a placeholder or no-reply one", ctx do
    commit(
      ctx.work,
      "a.txt",
      "mail test@example.com\n",
      "Co-Authored-By: C <noreply@anthropic.com>"
    )

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])

    commit(ctx.work, "b.txt", "mail bob@" <> "acme.io\n", "add b")
    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "email address in a tracked file"
  end

  test "an email address beside an allowed one on the same line blocks the push", ctx do
    # A placeholder domain as a prefix is not a placeholder address.
    spoof = "x@" <> "example.com.evil.io"
    line = "mail bob@" <> "acme.io or test@example.com or " <> spoof
    commit(ctx.work, "a.txt", line <> "\n", line)

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "email address in a tracked file"
    assert out =~ "email address in a commit, tag or ref name"
    assert out =~ "bob@"
    assert out =~ spoof
  end

  test "text whose domain label starts with a hyphen is not an email address", ctx do
    # Bytes of a binary file once read this way and refused a push.
    commit(ctx.work, "a.txt", "8\x94r@-2.kt\x80\n", "add a")

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
  end

  test "a commit author's email address blocks the push", ctx do
    stage(ctx.work, "a.txt", "a\n")

    no_hooks(ctx.work, [
      "-c",
      "user.email=dev@" <> "acme.io",
      "commit",
      "-qm",
      "add a"
    ])

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "email address in a commit, tag or ref name"
  end

  test "an allowed address passes in any case and at the start of a line", ctx do
    commit(ctx.work, "a.txt", "mail Test@Example.COM\n" <> "noreply@github.com\n", "add a")

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
  end

  test "a private reference added and removed again within the push blocks it", ctx do
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")
    sha = git(ctx.work, ["rev-parse", "HEAD"])
    commit(ctx.work, "a.txt", "see the docs\n", "reword a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "diff-#{sha}:"
    refute out =~ "in a tracked file"
  end

  test "a binary file's private content added and removed within the push blocks it", ctx do
    commit(ctx.work, "x.dat", <<0xFF, 0xFE, 0>> <> "see acme-internal docs\n", "add x")
    no_hooks(ctx.work, ["rm", "-q", "x.dat"])
    no_hooks(ctx.work, ["commit", "-qm", "remove x"])

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ ~r/diff-\w+:\d+: acme-internal/
  end

  # Bytes that are not valid UTF-8 must not hide a match on their line.
  test "a private reference in a tracked binary file blocks the push", ctx do
    commit(ctx.work, "x.dat", <<0xFF, 0xFE, 0>> <> "see acme-internal docs\n", "add x")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "in a tracked file"
  end

  test "a private pattern with a quantified non-ASCII letter still matches", ctx do
    File.write!(ctx.private_refs, "acmeä?corp\n")
    commit(ctx.work, "a.txt", "see acmecorp docs\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 1 of"
  end

  test "a tracked file is searched in a UTF-8 locale too", ctx do
    File.write!(ctx.private_refs, "acmeä?corp\n")
    commit(ctx.work, "a.txt", "see acmecorp docs\n", "add a")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    commit(ctx.work, "b.txt", "b\n", "add b")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "in a tracked file"
  end

  test "two binary files a merge resolves are not read as one", ctx do
    commit(ctx.work, "x.dat", <<0xFF, 0>> <> "base\n", "add x")
    commit(ctx.work, "y.dat", <<0xFF, 0>> <> "base\n", "add y")
    no_hooks(ctx.work, ["switch", "-q", "-c", "side"])
    commit(ctx.work, "x.dat", <<0xFF, 0>> <> "side\n", "side x")
    commit(ctx.work, "y.dat", <<0xFF, 0>> <> "side\n", "side y")
    no_hooks(ctx.work, ["switch", "-q", "main"])
    commit(ctx.work, "x.dat", <<0xFF, 0>> <> "main\n", "main x")
    commit(ctx.work, "y.dat", <<0xFF, 0>> <> "main\n", "main y")
    no_hooks(ctx.work, ["merge", "-q", "-s", "ours", "--no-commit", "side"])
    stage(ctx.work, "x.dat", <<0xFF, 0>> <> "acme-")
    stage(ctx.work, "y.dat", "internal" <> <<0xFF, 0>>)
    no_hooks(ctx.work, ["commit", "-qm", "merge side"])

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
  end

  test "a non-ASCII private name beside a byte that is not valid UTF-8 matches", ctx do
    File.write!(ctx.private_refs, "M[üu]ller\n")
    commit(ctx.work, "a.txt", "author: Müller " <> <<0xFF>> <> "\n", "add a")
    commit(ctx.work, "a.txt", "clean\n", "reword a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ ~r/diff-\w+:\d+:Müller/
  end

  # Only BSD regexes have a word boundary without a backslash, which is
  # how a pattern can match empty text beside a word but not on its own.
  @tag if(match?({:unix, :darwin}, :os.type()), do: [], else: [skip: "BSD regex only"])
  test "a pattern matching empty text only beside a word refuses the push", ctx do
    File.write!(ctx.private_refs, "(acme-internal)?[[:<:]]\n")
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "matches empty text in"
  end

  test "a private pattern that matches empty text refuses the push", ctx do
    File.write!(ctx.private_refs, "(acme-internal)?\n")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "line 1 of .git/info/private-refs matches empty text, so"
  end

  # pack-objects sends the original object, not a local replacement.
  test "a replace ref does not hide a pushed commit's content", ctx do
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")
    leaky = git(ctx.work, ["rev-parse", "HEAD"])
    clean = git(ctx.work, ["commit-tree", "-p", "HEAD~1", "-m", "add a", "HEAD~1^{tree}"])
    no_hooks(ctx.work, ["replace", leaky, clean])
    commit(ctx.work, "a.txt", "see the docs\n", "reword a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ ~r/diff-#{leaky}:\d+: acme-internal/
  end

  test "removing a private reference that is already public is not blocked", ctx do
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")
    commit(ctx.work, "acme-internal.txt", "x\n", "add a named file")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    commit(ctx.work, "a.txt", "see the docs\n", "remove the reference")
    no_hooks(ctx.work, ["rm", "-q", "acme-internal.txt"])
    no_hooks(ctx.work, ["commit", "-qm", "remove the named file"])

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/main"])
  end

  # A diff's context line can start with spaces and `+` of its own.
  test "an already-public line beside an edit is not read as added", ctx do
    commit(ctx.work, "a.md", "line1\n  + acme-internal item\n", "add a")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    commit(ctx.work, "a.md", "LINE1\n  + acme-internal item\n", "edit beside it")
    commit(ctx.work, "a.md", "LINE1\n", "remove it")

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/main"])
  end

  test "editing an already-public file whose name matches is not blocked", ctx do
    commit(ctx.work, "acme-internal.txt", "x\n", "add a named file")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    commit(ctx.work, "acme-internal.txt", "y\n", "edit it")
    no_hooks(ctx.work, ["rm", "-q", "acme-internal.txt"])
    no_hooks(ctx.work, ["commit", "-qm", "remove it"])

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/main"])
  end

  # A merge's resolution can keep a line that one parent already has.
  test "an already-public line a merge keeps from one parent is not read as added", ctx do
    commit(ctx.work, "a.txt", "a\nb\n", "add a")
    no_hooks(ctx.work, ["switch", "-q", "-c", "side"])
    commit(ctx.work, "a.txt", "a\nside\nb\n", "side a")
    no_hooks(ctx.work, ["switch", "-q", "main"])
    commit(ctx.work, "a.txt", "a\nacme-internal\nb\n", "main a")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    no_hooks(ctx.work, ["switch", "-q", "side"])
    no_hooks(ctx.work, ["merge", "-q", "-s", "ours", "--no-commit", "main"])
    stage(ctx.work, "a.txt", "a\nside\nacme-internal\nb\n")
    no_hooks(ctx.work, ["commit", "-qm", "merge main"])
    commit(ctx.work, "a.txt", "a\nside\nb\n", "drop the line")

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
  end

  test "a private reference in an extra commit header blocks the push", ctx do
    tree = git(ctx.work, ["rev-parse", "HEAD^{tree}"])
    parent = git(ctx.work, ["rev-parse", "HEAD"])
    object = Path.join(Path.dirname(ctx.work), "commit.txt")

    File.write!(object, """
    tree #{tree}
    parent #{parent}
    author t <t@t.t> 1700000000 +0000
    committer t <t@t.t> 1700000000 +0000
    x-note acme-internal

    odd commit
    """)

    sha = git(ctx.work, ["hash-object", "-t", "commit", "-w", object])

    assert {out, code} = push(ctx.work, ["origin", "#{sha}:refs/heads/odd"])
    assert code != 0
    assert out =~ "commit-#{sha}:"
  end

  test "a private reference in the message of a commit below the tip blocks the push", ctx do
    commit(ctx.work, "a.txt", "a\n", "see acme-internal docs")
    sha = git(ctx.work, ["rev-parse", "HEAD"])
    commit(ctx.work, "b.txt", "b\n", "add b")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 3 of"
    assert out =~ "commit-#{sha}:"
  end

  test "a private reference in an annotated tag's message blocks the push", ctx do
    no_hooks(ctx.work, ["tag", "-a", "v1", "-m", "release for acme-internal"])

    assert {out, code} = push(ctx.work, ["origin", "v1"])
    assert code != 0
    assert out =~ "private pattern on line 3 of"
    assert out =~ "tag-"
  end

  test "a private reference in the name of the branch pushed to blocks the push", ctx do
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/acme-internal-fix"])
    assert code != 0
    assert out =~ "ref-names:1:"
  end

  # Being on another remote does not make a commit public on this one.
  test "a commit already on another remote is still checked when pushed to origin", ctx do
    other = Path.join(Path.dirname(ctx.work), "other.git")
    git(Path.dirname(ctx.work), ["init", "-q", "--bare", other])
    no_hooks(ctx.work, ["remote", "add", "other", other])
    commit(ctx.work, "a.txt", "a\n", "see acme-internal docs")
    no_hooks(ctx.work, ["push", "-q", "other", "HEAD:refs/heads/feature"])

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 3 of"
  end

  test "a private pattern starting with a dash is a pattern, not an option", ctx do
    File.write!(ctx.private_refs, "-internal-x\n")
    commit(ctx.work, "a.txt", "acme-internal-x\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 1 of"
    assert out =~ "in a tracked file"
  end

  test "a merge's own resolution is checked even when a later commit removes it", ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "side"])
    commit(ctx.work, "b.txt", "b\n", "add b")
    no_hooks(ctx.work, ["switch", "-q", "main"])
    commit(ctx.work, "c.txt", "c\n", "add c")
    no_hooks(ctx.work, ["merge", "-q", "--no-commit", "side"])
    stage(ctx.work, "c.txt", "c, see acme-internal docs\n")
    no_hooks(ctx.work, ["commit", "-qm", "merge side"])
    commit(ctx.work, "c.txt", "c\n", "reword c")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 3 of"
  end

  # t.txt takes each hunk from one parent, so `--cc` shows only x.dat
  # while `--name-only` lists both: the path must come from the header.
  test "a merge's own binary resolution is checked even when a later commit removes it", ctx do
    stage(ctx.work, "t.txt", "1\n2\n3\n4\n5\n")
    commit(ctx.work, "x.dat", <<0xFF, 0>> <> "base\n", "add x")
    no_hooks(ctx.work, ["switch", "-q", "-c", "side"])
    stage(ctx.work, "t.txt", "one\n2\n3\n4\n5\n")
    commit(ctx.work, "x.dat", <<0xFF, 0>> <> "side\n", "side x")
    no_hooks(ctx.work, ["switch", "-q", "main"])
    stage(ctx.work, "t.txt", "1\n2\n3\n4\nfive\n")
    commit(ctx.work, "x.dat", <<0xFF, 0>> <> "main\n", "main x")
    no_hooks(ctx.work, ["merge", "-q", "-s", "ours", "--no-commit", "side"])
    stage(ctx.work, "t.txt", "one\n2\n3\n4\nfive\n")
    stage(ctx.work, "x.dat", <<0xFF, 0>> <> "see acme-internal docs\n")
    no_hooks(ctx.work, ["commit", "-qm", "merge side"])
    commit(ctx.work, "x.dat", <<0xFF, 0>> <> "done\n", "reword x")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ ~r/diff-\w+:\d+: acme-internal/
  end

  # Builds a merge whose own resolution of the binary file `name` is
  # `content`, or deletes it when `content` is nil.
  defp binary_merge(work, name, content) do
    commit(work, name, <<0xFF, 0>> <> "base\n", "add binary")
    no_hooks(work, ["switch", "-q", "-c", "side"])
    commit(work, name, <<0xFF, 0>> <> "side\n", "side binary")
    no_hooks(work, ["switch", "-q", "main"])
    commit(work, name, <<0xFF, 0>> <> "main\n", "main binary")
    no_hooks(work, ["merge", "-q", "-s", "ours", "--no-commit", "side"])

    if content,
      do: stage(work, name, content),
      else: no_hooks(work, ["rm", "-q", name])

    no_hooks(work, ["commit", "-qm", "merge side"])
  end

  test "a merge's binary file with a non-ASCII name is read", ctx do
    binary_merge(ctx.work, "é.dat", <<0xFF, 0>> <> "see acme-internal docs\n")
    no_hooks(ctx.work, ["rm", "-q", "é.dat"])
    no_hooks(ctx.work, ["commit", "-qm", "remove it"])

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ ~r/diff-\w+:\d+: acme-internal/
  end

  test "a merge's binary file whose path git quotes refuses the push", ctx do
    binary_merge(ctx.work, "x\"y.dat", <<0xFF, 0>> <> "clean\n")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "cannot read binary file"
  end

  test "a merge that deletes a binary file is not refused", ctx do
    binary_merge(ctx.work, "x.dat", nil)

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
  end

  test "a root commit's added lines are read without their marker", ctx do
    File.write!(ctx.private_refs, "^acme-internal\n")
    no_hooks(ctx.work, ["switch", "-q", "--orphan", "fresh"])
    commit(ctx.work, "a.txt", "acme-internal\n", "root")
    commit(ctx.work, "a.txt", "clean\n", "reword a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/fresh"])
    assert code != 0
    assert out =~ ~r/diff-\w+:\d+:acme-internal/
  end

  test "a private name in the path of a new empty file blocks the push", ctx do
    commit(ctx.work, "acme-internal-notes.md", "", "add notes")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "paths-"
  end

  test "a start-anchored private pattern matches added lines and short ref names", ctx do
    File.write!(ctx.private_refs, "^acme-internal\n")
    commit(ctx.work, "a.txt", "acme-internal: token\n", "add a")
    commit(ctx.work, "a.txt", "token\n", "reword a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/acme-internal-fix"])
    assert code != 0
    assert out =~ "diff-"
    assert out =~ "ref-names:2:"
  end

  # A new remote has no tracking branches, and being on another remote
  # does not make a commit public on it.
  test "a first push to a new remote checks history another remote has", ctx do
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")
    commit(ctx.work, "a.txt", "see the docs\n", "reword a")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])

    fresh = Path.join(Path.dirname(ctx.work), "fresh.git")
    git(Path.dirname(ctx.work), ["init", "-q", "--bare", fresh])
    no_hooks(ctx.work, ["remote", "add", "fresh", fresh])

    assert {out, code} = push(ctx.work, ["fresh", "HEAD:refs/heads/main"])
    assert code != 0
    assert out =~ ~r/diff-\w+:\d+: acme-internal/
  end

  # The remote is asked what it has, so history it already holds is not
  # rescanned even without tracking branches for it.
  test "a push to a URL skips history the remote already has", ctx do
    stage(ctx.work, "a.txt", "a\n")
    no_hooks(ctx.work, ["-c", "user.email=dev@" <> "acme.io", "commit", "-qm", "add a"])
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    no_hooks(ctx.work, ["update-ref", "-d", "refs/remotes/origin/main"])
    commit(ctx.work, "b.txt", "b\n", "add b")
    url = git(ctx.work, ["remote", "get-url", "origin"])

    assert {_, 0} = push(ctx.work, [url, "HEAD:refs/heads/main"])
  end

  # The remote's new tip hides the public history below it until a fetch.
  # The many hits and pull-request refs each fill a pipe, so a reader that
  # stopped at its first match would kill the writer and lose the hint.
  test "a refusal while the remote is ahead says to fetch first", ctx do
    lines = String.duplicate("see acme-internal docs\n", 3000)
    commit(ctx.work, "a.txt", lines, "add a")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    # Below the hits, so the pull-request refs do not make them public.
    sha = git(ctx.work, ["rev-parse", "HEAD~1"])

    no_hooks(ctx.work, [
      "push",
      "-q",
      "origin" | Enum.map(1..3000, &"#{sha}:refs/pull/#{&1}/head")
    ])

    remote_ahead(ctx.work)
    commit(ctx.work, "b.txt", "b\n", "add b")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "Run `git fetch` and push again first."
  end

  # A fetch cannot clear a match in the name of the branch pushed to.
  test "a refusal while the remote is ahead says nothing of fetching for a ref name", ctx do
    remote_ahead(ctx.work)
    commit(ctx.work, "b.txt", "b\n", "add b")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/acme-internal-fix"])
    assert code != 0
    assert out =~ "ref-names:1:"
    refute out =~ "git fetch"
  end

  # Git passes the push URL, which can differ from the fetch URL.
  test "the server pushed to is asked, not the one fetched from", ctx do
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    fresh = Path.join(Path.dirname(ctx.work), "fresh.git")
    git(Path.dirname(ctx.work), ["init", "-q", "--bare", fresh])
    no_hooks(ctx.work, ["config", "remote.origin.pushurl", fresh])
    commit(ctx.work, "a.txt", "see the docs\n", "reword a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/main"])
    assert code != 0
    assert out =~ ~r/diff-\w+:\d+: acme-internal/
  end

  test "run by hand, history on a remote-tracking branch is skipped", ctx do
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")
    no_hooks(ctx.work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    commit(ctx.work, "a.txt", "see the docs\n", "reword a")

    assert {_, 0} =
             System.cmd("bash", ["scripts/no-private-refs.sh", "HEAD"],
               cd: ctx.work,
               env: hook_env(),
               stderr_to_stdout: true
             )
  end

  test "run by hand from a subdirectory, the whole tree is searched", ctx do
    File.mkdir_p!(Path.join(ctx.work, "sub"))
    stage(ctx.work, "sub/x.txt", "x\n")
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")

    assert {out, code} =
             System.cmd("bash", ["../scripts/no-private-refs.sh", "HEAD"],
               cd: Path.join(ctx.work, "sub"),
               env: hook_env(),
               stderr_to_stdout: true
             )

    assert code != 0
    assert out =~ "in a tracked file"
  end

  # Colour codes would hide an allowed address's line end from ALLOWED.
  test "colour forced on in git config does not break the allowed addresses", ctx do
    no_hooks(ctx.work, ["config", "color.ui", "always"])
    commit(ctx.work, "a.txt", "mail test@example.com\n", "add a")

    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
  end

  # A fetch does not bring in a host's pull-request refs.
  test "an unfetched ref outside branches and tags does not say to fetch", ctx do
    base = Path.dirname(ctx.work)
    other = Path.join(base, "other")

    git(base, ["clone", "-q", "-b", "main", git(ctx.work, ["remote", "get-url", "origin"]), other])

    no_hooks(other, [
      "-c",
      "user.email=t@t.t",
      "-c",
      "user.name=t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "pr"
    ])

    no_hooks(other, ["push", "-q", "origin", "HEAD:refs/pull/1/head"])
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    refute out =~ "git fetch"
  end

  test "a remote that cannot be asked what it has refuses the push", ctx do
    missing = Path.join(Path.dirname(ctx.work), "missing.git")

    assert {out, code} =
             System.cmd(
               "bash",
               ["scripts/no-private-refs.sh", "--remote", missing, "HEAD"],
               cd: ctx.work,
               env: hook_env(),
               stderr_to_stdout: true
             )

    assert code != 0
    assert out =~ "cannot ask the remote what it already has"
  end

  test "an empty remote refuses the push rather than trusting tracking branches", ctx do
    assert {out, code} =
             System.cmd("bash", ["scripts/no-private-refs.sh", "--remote", "", "HEAD"],
               cd: ctx.work,
               env: hook_env(),
               stderr_to_stdout: true
             )

    assert code != 0
    assert out =~ "no remote to ask what it already has"
  end

  # macOS iconv exits 1 when a write fails, the status some implementations
  # give after -c drops a byte.
  test "an iconv that fails with status 1 refuses the push", ctx do
    bin = Path.join(Path.dirname(ctx.work), "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "iconv"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin, "iconv"), 0o755)
    commit(ctx.work, "a.txt", "a\n", "add a")

    assert {out, code} =
             System.cmd("bash", ["scripts/no-private-refs.sh", "HEAD"],
               cd: ctx.work,
               env: [{"PATH", bin <> ":" <> System.get_env("PATH")} | hook_env()],
               stderr_to_stdout: true
             )

    assert code != 0
    assert out =~ "cannot convert"
  end

  # macOS iconv drops a cut-off character at the end of its input together
  # with the bytes after it when fewer follow than it announces: up to four
  # newlines after 0xFC, which announces five more bytes.
  test "a commit message ending in a cut-off character is not refused", ctx do
    tree = git(ctx.work, ["rev-parse", "HEAD^{tree}"])
    parent = git(ctx.work, ["rev-parse", "HEAD"])
    object = Path.join(Path.dirname(ctx.work), "commit.txt")

    for tail <- [<<0xF0>>, <<0xFC>>] do
      File.write!(object, """
      tree #{tree}
      parent #{parent}
      author t <t@t.t> 1700000000 +0000
      committer t <t@t.t> 1700000000 +0000

      thanks #{tail}\
      """)

      sha = git(ctx.work, ["hash-object", "-t", "commit", "-w", object])

      assert {_, 0} =
               System.cmd("bash", ["scripts/no-private-refs.sh", sha],
                 cd: ctx.work,
                 env: hook_env(),
                 stderr_to_stdout: true
               )
    end
  end

  # Only the UTF-8 pass matches the name. The fake iconv cuts the copy
  # holding it short inside the name, which ends a message with no final
  # newline, dropping the newlines the script adds after it.
  test "a UTF-8 copy cut short inside its last line refuses the push", ctx do
    File.write!(ctx.private_refs, "M[üu]ller\n")
    base = Path.dirname(ctx.work)
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "iconv"), """
    #!/bin/sh
    perl -0777 -pe 's/(M\\xc3\\xbcl)ler\\n*\\z/$1/'
    exit 1
    """)

    File.chmod!(Path.join(bin, "iconv"), 0o755)
    message = Path.join(base, "message.txt")
    File.write!(message, "thanks Müller")
    sha = git(ctx.work, ["commit-tree", "-p", "HEAD", "-F", message, "HEAD^{tree}"])
    {raw, 0} = System.cmd("git", ["cat-file", "commit", sha], cd: ctx.work, env: hook_env())
    refute String.ends_with?(raw, "\n")

    assert {out, code} =
             System.cmd("bash", ["scripts/no-private-refs.sh", sha],
               cd: ctx.work,
               env: [{"PATH", bin <> ":" <> System.get_env("PATH")} | hook_env()],
               stderr_to_stdout: true
             )

    assert code != 0
    assert out =~ "cannot convert"
  end

  test "a push to a URL rather than a named remote is checked", ctx do
    commit(ctx.work, "a.txt", "see acme-internal docs\n", "add a")
    url = git(ctx.work, ["remote", "get-url", "origin"])

    assert {out, code} = push(ctx.work, [url, "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 3 of"
  end

  test "an escaped backslash in a private pattern matches a literal one", ctx do
    File.write!(ctx.private_refs, "acme\\\\dev\n")
    commit(ctx.work, "a.txt", "C:\\acme\\dev\n", "add a")

    assert {out, code} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    assert out =~ "private pattern on line 1 of"
  end

  # lefthook skips a pre-push *command* when `git diff HEAD @{push}` is
  # empty, which is true of a force-push that changes only history.
  test "a force-push that only rewrites history runs the checks", ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "feature"])
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["-u", "origin", "feature"])
    File.rm!(ctx.marker)

    no_hooks(ctx.work, ["commit", "-q", "--amend", "-m", "reworded"])

    assert {_, 0} = push(ctx.work, ["--force", "origin", "feature"])
    assert File.exists?(ctx.marker)
  end

  test "a force-push that only rewrites a commit message to hold a private reference is refused",
       ctx do
    no_hooks(ctx.work, ["switch", "-q", "-c", "feature"])
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["-u", "origin", "feature"])

    no_hooks(ctx.work, ["commit", "-q", "--amend", "-m", "copied from #{@private_path}"])

    assert {out, code} = push(ctx.work, ["--force", "origin", "feature"])
    assert code != 0
    assert out =~ "local absolute path in a commit, tag or ref name"
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

  test "a push that deletes one branch and updates another runs the checks", ctx do
    commit(ctx.work, "a.txt", "a\n", "add a")
    assert {_, 0} = push(ctx.work, ["origin", "HEAD:refs/heads/feature"])
    File.rm!(ctx.marker)
    File.write!(ctx.outdated_status, "1")
    commit(ctx.work, "b.txt", "b\n", "add b")

    assert {_, code} = push(ctx.work, ["origin", ":feature", "HEAD:refs/heads/other"])
    assert code != 0
    assert File.exists?(ctx.marker)
  end

  test "a checkout without its own lefthook refuses the push", %{work: work, marker: marker} do
    File.rm_rf!(Path.join(work, "node_modules"))
    commit(work, "a.txt", "a\n", "add a")

    assert {_, code} = push(work, ["origin", "HEAD:refs/heads/feature"])
    assert code != 0
    refute File.exists?(marker)
  end

  # A UTF-8 locale, as in an interactive shell, so the tests of bytes
  # that are not valid UTF-8 catch a script that uses the caller's
  # locale, whatever locale the tests run under.
  defp push(work, args) do
    System.cmd("git", ["push" | args],
      cd: work,
      env: [{"LC_ALL", "C.UTF-8"} | hook_env()],
      stderr_to_stdout: true
    )
  end

  # Puts a commit on the remote's main that `work` lacks, from another clone.
  defp remote_ahead(work) do
    base = Path.dirname(work)
    other = Path.join(base, "other")

    git(base, ["clone", "-q", "-b", "main", git(work, ["remote", "get-url", "origin"]), other])

    git(other, [
      "-c",
      "user.email=t@t.t",
      "-c",
      "user.name=t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "ahead"
    ])

    no_hooks(other, ["push", "-q", "origin", "HEAD:refs/heads/main"])
  end

  # Only pushes go through the hooks; other commands would fire lefthook's
  # post-checkout install, whose script this fixture leaves out.
  defp no_hooks(work, args), do: git(work, ["-c", "core.hooksPath=/dev/null" | args])

  defp commit(work, name, content, message) do
    stage(work, name, content)
    no_hooks(work, ["commit", "-qm", message])
  end
end
