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
   Split / Unified, Wrap, `⚙` settings popover (font size, tab size,
   rulers). The popover settings, Split / Unified and Wrap are saved
   in `settings.json` in meerkat's config dir,
   `$XDG_CONFIG_HOME/meerkat`, or `~/.config/meerkat` when
   `XDG_CONFIG_HOME` is unset, empty or relative, and are shared by
   every review. A change applies at once in every open tab of the
   same review; tabs of other running reviews pick it up when they
   next load or reconnect. A change saves only the setting it
   changed, so changes to different settings in one review keep
   both; two reviews saving at the same instant can lose one. A file
   that cannot be read or parsed prints a warning and leaves the
   defaults in force until the next change replaces it; a value that
   is not valid keeps its default, except that a whole-number font
   size is clamped into 9 to 28.
   When the toolbar's content does not fit on one row, at any window
   width, it gives up room one step at a time, only as far as it
   needs: the version chip shows only its count of updates, or
   nothing when there are none, and its drop-down names the version;
   `☰ Files` becomes `☰`; the connection pill becomes its
   dot; the counts drop `showing` and write `/` for `of`; Split /
   Unified and Wrap move into the `⚙` popover; then the title, the
   base branch and the head branch truncate with an ellipsis, in that
   order, each down to its first few characters before the next
   starts, and each keeping its full text on its tooltip. Only when
   all that is not enough does the toolbar wrap onto a second row.
   At the version chip's step, opening its drop-down marks the
   updates seen, so the chip turns invisible but keeps its place,
   and the drop-down stays where it opened until it closes, by a
   click where the chip was, a click elsewhere, or Esc; the toolbar
   then fits again, with no chip if it still needs that step. A dev
   build's chip, with no updates or drop-down, is gone at that step
   too. When the drop-down closes, focus in the chip or the
   drop-down goes to the chip, or, when the chip is gone, to the next
   toolbar control. The drop-down opens within the window at any width. Branch names show
   in full until their step truncates them. The connection pill's
   label, and the version on a chip that shows only its count, stay
   readable to screen readers. While the page loads, the
   toolbar keeps to one row: the title and branches give up room
   first, so the connection pill stays in view when the rest fits,
   and what still does not fit is cut off.
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
   - **Rulers**: a checkbox shows or hides them all, and a text field
     takes their columns separated by commas or spaces, `80, 110` by
     default. Only whole numbers from 1 to 999 are accepted; other
     input marks the field invalid, and stays in it, while the last
     valid list stays in force, until another tab saves columns or
     the page reconnects; the field then shows the saved list. An
     empty list draws no rulers. The setting drives both the diff and
     the suggestion editor (see
     [inline-comments.md](inline-comments.md)).
   - In the diff, each ruler is a vertical line after its column on
     code lines, counting tabs at the Tab setting. A ruler shows only
     when its column fits in the visible width of the code column,
     judged for each side separately in Split view, with Wrap on or
     off; otherwise it is not drawn. A wrapped line's continuation
     rows show it too.
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
   Each hunk shows the lines `git diff` gives it, and its header,
   shown when lines are hidden above it, gives git's line ranges.
   The exception is a hunk meerkat splits where a run both removes
   and adds lines, but different numbers of each, to pair them for
   intra-line highlighting.
   In Split view, buttons that reveal hidden context lines around
   and between hunks appear only in the right-hand (new-side)
   gutter, with each hunk header (`@@ -17,7 +17,7 @@`) beside them
   on the right; Unified view keeps them in its single gutter.
   Moved code is tinted. A moved block is at least 2 identical
   consecutive lines of 3 or more characters, removed in one place and
   added in another, with any shorter or blank lines among or after
   them. It takes in changed blank lines directly before or after it
   that a longer block hasn't taken, and counts once it spans 3 lines
   on either side and its lines hold 20 or more letters and digits,
   git's threshold for moved code. Each moved line shows an arrow in
   place of its `+` / `−` mark: `→` on the new side, `←` on the old
   side. Each arrow is a button, titled with where the code moved,
   that jumps to the block's counterpart, first showing its file's diff
   if that file is collapsed, filtered out or rendered. Arrows show in
   both views with Wrap on or off, cover no code, and stay out of
   copied code.
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
filter shows, then the whole diff's total: `showing +40 -10 of +120 -30`,
or `+40 -10 / +120 -30` when the toolbar is short of room.

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
- `Meerkat.Settings` keeps the toolbar settings in `settings.json`
  in meerkat's config dir and broadcasts each change on the
  `meerkat:settings` PubSub topic to the review's other tabs.
- The static review payload (files + commit message + PR metadata)
  is derived once from git via `Meerkat.ReviewState.from_target/2`
  on mount, never mutated mid-review.
