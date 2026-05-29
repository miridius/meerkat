# Meerkat

A small local diff reviewer. Open a browser, comment on the diff, block or
pass it back to the agent that produced the change.

Works against any local diff — staged, a single commit, an arbitrary
range, a GitHub PR.

```bash
meerkat                              # review staged diff
meerkat --commit-msg path/to/MSG     # staged diff + commit message (commit-msg hook)
meerkat HEAD                         # a single commit (= HEAD~1...HEAD)
meerkat main...my-branch             # three-dot: merge-base(main, my-branch)..my-branch
meerkat main..my-branch              # two-dot:   main..my-branch directly
meerkat --pr 123                     # fetch and review a GitHub PR via `gh`
```

No external server, no queue, no database. Each invocation spawns a
short-lived Phoenix server on a random local port, opens the browser to
it, waits for your decision, and exits.

## Status

**Experimental — buggy, rough, and changing often.** This is a personal
tool under active development. Expect breakage and frequent breaking
changes; use it at your own risk.

Known issues:

- Syntax highlighting sometimes breaks.
- The suggestion-mode editor's UX is poor.
- Only `--commit-msg` mode is exercised day to day. The other entry
  points (`HEAD`, two/three-dot ranges, `--pr`) are very likely broken.

## Install

macOS. Requires [Elixir](https://elixir-lang.org) 1.18+, Erlang/OTP 28+,
and [`bun`](https://bun.sh) (for the asset build).

```bash
git clone https://github.com/miridius/meerkat
cd meerkat
bash scripts/install.sh
```

This builds a Mix release and installs a launcher at
`~/.local/bin/meerkat` — make sure that's on your `PATH`. Re-run
`scripts/install.sh` to update.

For development, `bin/meerkat-beam` runs meerkat straight from the
checkout and hot-restarts on source edits — see `CLAUDE.md`.

## As a git `commit-msg` hook

`git commit` opens the review UI, blocks until you approve or send
feedback. **Send Feedback** → exit 1, commit blocked, your comments
render on stderr as first-party instructions the calling agent can act
on. **Approve** → exit 0, commit proceeds.

```bash
# In each repo where you want the hook:
echo '#!/bin/sh' > .git/hooks/commit-msg
echo 'exec meerkat --commit-msg "$1"' >> .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg
```

## Reviewing a GitHub PR

```bash
meerkat --pr 123
```

Fetches the PR head and its base into `refs/meerkat-pr/<N>/{head,base}`,
computes the three-dot diff, opens the UI. Optionally post the review
back to the PR as a GitHub PENDING review via the **Post to GitHub**
button — line-level comments become inline review comments, file-level
and global comments concatenate into the review body, and `gh api`
handles the POST from the repo's `gh` remote. Finalise (approve /
request changes / comment) from github.com.

## Review UI

- Click a line number to comment, click-and-drag across line numbers for
  a range. Comments anchor to the clicked side only (old vs new).
- Five Conventional-Comments types with traffic-light colours:
  **revert** (red), **issue** (orange, default), **suggestion**
  (yellow), **question** (green), **thought** (muted).
- Markdown in comment bodies. Backticks, code fences, bullets, links all
  render in place (earmark + html_sanitize_ex on the server).
- **"Please learn from this"** checkbox on every comment. Tells the
  calling agent to turn the comment into a durable learning rather than
  just a one-off fix.
- **Approve with feedback**. The Approve button accepts comments — label
  flips to "Approve with feedback" when any are pending.
- **Multi-tab consistency**. State lives in `Meerkat.ReviewServer`, a
  GenServer keyed by review_id. `Phoenix.PubSub` broadcasts every
  change to every connected tab — open the same review URL in two
  tabs, comment in one, see it in the other.
- **Crash-survivable comments**. The review state is persisted
  atomically to `<gitdir>/meerkat-precommit/in-progress/<id>.json`
  after every mutation. If meerkat is killed mid-review, the next
  invocation replays the saved comments.
- **PlantUML inline render** for `.puml` files (when the `plantuml` CLI
  is on PATH).
- **Suggestion-mode CodeMirror editor** with syntax highlighting per
  file extension.
- **File filter** — substring narrowing, hide-by-extension, "only this
  file" mode.

## Architecture

Phoenix LiveView + LiveSvelte on the BEAM. The CLI parses args, starts
an OTP supervisor, binds the Phoenix endpoint on a random port, and
blocks on a `Meerkat.Decision` GenServer. The LiveView reflects state
held in `Meerkat.ReviewServer` (one per review_id, single-writer);
mutations go through PubSub broadcasts. The diff body is rendered by
`@git-diff-view/svelte` mounted via LiveSvelte; comment forms live in
the same LV/Svelte boundary.

See `CLAUDE.md` for the development workflow.

## Quality gates

```bash
mix test                             # ExUnit (unit + LiveView)
bun run test:e2e                     # Playwright suite — drives a real meerkat binary
mix format --check-formatted         # Elixir formatting
mix compile --warnings-as-errors     # strict compile
```

The Playwright suite in `tests/e2e/` is the behavioural-parity gate —
30 specs covering the full review UI lifecycle, plus 2 multi-tab
consistency tests that prove the BEAM port's central state model.

## License

[MIT](LICENSE).
