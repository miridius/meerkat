# Overview

Meerkat is a local pre-commit and pull-request review tool. It
renders the diff being committed (or fetched from GitHub) in a
browser, lets the human reviewer leave inline / file / global /
commit-message comments, and feeds the comments back to the agent
that ran `git commit` (or to a GitHub PENDING review).

## Where it runs

- **Pre-commit hook** in any repo. The user installs a hook shim
  that invokes `meerkat --commit-msg .git/COMMIT_EDITMSG`. Meerkat
  blocks the commit until the human approves or rejects.
- **Ad-hoc**: `meerkat <ref>` to review a single commit,
  `meerkat A..B` / `A...B` for a range, `meerkat --pr <N>` for a
  GitHub PR.

Each invocation parses args and first refuses to review while the
agent owes answers to the last round's questions (see
[pending-answers.md](pending-answers.md)). It then derives a review
target and decides whether to auto-approve (see
[decision-flow.md](decision-flow.md) for the auto-approve fast
path). Otherwise, from the invocation's perspective, a localhost
HTTP port is bound, the URL is opened in the browser, and it blocks
until the human makes a decision. It prints feedback to stderr and
exits with a code the caller (the git hook) uses to allow or block
the commit. Under the launchers, the review server is detached from
the invocation that started it and outlives it; a later invocation
of the same review attaches to that server (see
[decision-flow.md#when-the-caller-exits](decision-flow.md#when-the-caller-exits)).

## Top-level affordances

When the UI does open, the reviewer sees, top-to-bottom:

1. **Diff toolbar** — sticky at the top. Files panel toggle, PR
   pill (links to GitHub when `state.pr` is populated), the title
   (PR title / commit subject / branch), `base ← head` branch chip
   with the repo path on its tooltip, then on the right the diff's
   line counts (see [Line counts](#line-counts)), connection pill,
   Split / Unified, Wrap, `⚙` settings popover (font size + tab size).
   For staged changes, the toolbar shows the current branch and its
   open PR. During a rebase, HEAD is detached, so the toolbar shows
   the branch being rebased and looks up its PR by name. This lookup
   finds only PRs whose head branch is in the same repository. For a
   branch whose PR comes from a fork, the branch appears without a PR
   pill, and no warning is printed. A rebased branch named like a PR
   number (`28`, `#28`, `+28`) also gets no PR pill. If HEAD has no
   branch—because it is detached outside a rebase or the rebase began
   from a detached HEAD—neither branch nor PR appears, and no warning
   is printed.
2. **Flash error banner** (only when a handler set `flash_error`,
   e.g. a stale-OID approve or a `gh api` failure).
3. **Pending answers** banner (only if a prior review had question
   comments that Claude has since answered — see
   [pending-answers.md](pending-answers.md)).
4. **Commit message** section (only in `--commit-msg` and
   single-ref modes — see [commit-message.md](commit-message.md)).
5. **Global comments** section (collapsed to a single ghost button
   while empty — see [non-inline-comments.md](non-inline-comments.md)).
6. **Tip** paragraph (one-time dismissible) explaining line-num
   gutter clicks.
7. **Review body** — file-filter sidebar on the left, file-list
   diffs on the right (see [file-filter.md](file-filter.md)).
   Each file header shows that file's line counts on the right, just
   left of its buttons.
   In every review mode, a binary file shows a notice in place of its
   diff, and meerkat never reads its content.
   In Split view, buttons that reveal hidden context lines around
   and between hunks appear only in the right-hand (new-side)
   gutter, with each hunk header (`@@ -17,7 +17,7 @@`) beside them
   on the right; Unified view keeps them in its single gutter.
8. **Decision footer**, sticky at the bottom — Cancel, Post to
   GitHub (only when `state.pr` is set and not precommit mode),
   Send Feedback, Approve, plus a "N comments" running counter
   (see [decision-flow.md](decision-flow.md)).

## Line counts

Like GitHub, the toolbar and each file header show `+x -y`: the
number of added lines in green and removed lines in red, without
GitHub's diffstat squares. Counts are taken from the diff meerkat
shows, so in staged reviews a line whose only change is whitespace
is not counted. A binary file shows no counts.

When every file is shown expanded, the toolbar shows one total for
the whole diff, `+120 -30`. When the file filter hides a file or a
file is collapsed, it shows the total of the expanded files the
filter shows, then the whole diff's total: `showing +40 -10 of +120 -30`.

## What state lives where

- The `Meerkat.ReviewServer` GenServer per `review_id` is the
  single writer of all mutable review state (comments, approved
  set, hidden extensions, show-generated toggle). Multiple browser
  tabs converge via `Phoenix.PubSub` broadcasts on every change —
  see [multi-tab.md](multi-tab.md).
- The `Meerkat.Persistence` module atomically rewrites a JSON
  snapshot under `<per-worktree-gitdir>/meerkat-precommit/in-progress/<review_id>.json`
  after every mutation. A killed BEAM / closed tab restores from
  this file on the next launch with the same target.
- The static review payload (files + commit message + PR metadata)
  is derived once from git via `Meerkat.ReviewState.from_target/2`
  on mount, never mutated mid-review.
