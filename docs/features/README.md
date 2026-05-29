# Meerkat feature specs

Every user-facing affordance meerkat is supposed to have, written
down so we can verify the product matches the spec — not the other
way around. When the implementation drifts from the spec, the spec
wins until we update it.

## Process for changes

Any new feature, fix, or UX tweak follows the same loop:

1. **Update the relevant `docs/features/*.md` file first.** Edit the
   affordance list, behaviour rules, edge cases. If the change
   doesn't fit any existing file cleanly, add a new one.
2. **Plannotator-review the spec change.** Treat the markdown
   update as a reviewable artefact in its own right — annotate,
   resolve, agree on the contract before any code lands.
3. **Implement** the code change to match the (now-updated) spec.
4. **Run the QA subagent** (see `.claude/agents/meerkat-qa.md`). It
   reads `docs/features/*.md`, generates a test plan, executes
   against a live meerkat instance, and reports deviations.
   Address every deviation before the PR lands.

Tests in `test/` and `tests/e2e/` are the **mechanical** contract.
The feature docs are the **human-readable** contract. The QA agent
bridges the two by exercising the docs against the running app.

## Files

- [overview.md](overview.md) — what meerkat is, where it runs, top-level affordances.
- [cli.md](cli.md) — command-line flags, target modes, exit codes, env vars.
- [installation.md](installation.md) — dev launcher vs prod release; auto-install on merge to main.
- [dev-mode.md](dev-mode.md) — DevWatcher, shepherd loop, hot reload, deterministic port.
- [decision-flow.md](decision-flow.md) — Approve / Send Feedback / Cancel, auto-approve fast path, default-deny on crash, terminal-decision persistence cleanup.
- [inline-comments.md](inline-comments.md) — drag-select, form anchoring, edit / remove, learn toggle, suggestion mode, visual line marker, persistence across BEAM restart.
- [non-inline-comments.md](non-inline-comments.md) — global / file / commit-msg surfaces; shared CommentForm + GitHub PENDING flatten.
- [commit-message.md](commit-message.md) — gutter rendering, block detection, click-to-comment.
- [file-filter.md](file-filter.md) — sidebar, hide-extension, only-this-file, substring filter, generated-file toggle.
- [approved-collapse.md](approved-collapse.md) — approved files collapse; click header to re-expand.
- [pending-answers.md](pending-answers.md) — pinned banner, schema, lifecycle.
- [multi-tab.md](multi-tab.md) — PubSub state convergence, tab close behavior.

## Pending / not-yet-written

- Styling / layout / dark-theme accessibility affordances
  (covered partially in inline / non-inline / overview, no
  standalone styling spec yet).
