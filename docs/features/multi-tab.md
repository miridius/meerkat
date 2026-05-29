# Multi-tab convergence

Multiple browser tabs pointed at the same meerkat URL converge to
a single canonical state via Phoenix.PubSub. Useful when the
reviewer wants two views on the same review (split a wide monitor
between commit-message + a specific file's diff) or when a hot
reload causes the LV's WebSocket to reconnect.

## Server-as-truth

`Meerkat.ReviewServer` (one GenServer per `review_id`) owns the
canonical `%ReviewState{}`. Every mutation flows through it via
`add_*_comment`, `remove_comment`, `set_approved`,
`set_extension_hidden`, `set_show_generated`, `set_learn_from_this`,
and `set_open_form`. LiveViews never write state directly.

After every mutation, `ReviewServer.update/2`:

1. Runs the state transformer.
2. Persists the new state to
   `<gitdir>/meerkat-precommit/in-progress/<review_id>.json` via
   `Meerkat.Persistence.save/3`.
3. Broadcasts `{:state_changed, %ReviewState{}}` on the topic
   `"review:#{review_id}"`.

## Subscriber side

`MeerkatWeb.ReviewLive.mount/3` calls
`Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(rid))`
when `connected?(socket)`. Every connected tab receives the
broadcast.

`handle_info({:state_changed, state}, socket)` re-assigns both
`state` and `open_form` (the latter is derived from
`state.open_form`). The LV re-renders; LiveSvelte propagates the
new props to DiffViewer / InlineComment / CommentForm; the diff
viewer's `$effect` re-injects rows.

So: tab A adds a comment → ReviewServer broadcasts → tab B's LV
sees `state_changed` → tab B re-renders with the new comment
visible.

## Open-form propagation

A subtle case: when tab A opens an inline comment form, tab B
also sees the form open (same anchor, same prefilled body). This
is intentional — `open_form` lives on persisted state so the
form survives a BEAM restart. The byproduct is multi-tab
co-editing: typing in one tab's form updates the localStorage
draft (shared via the `draftKey`), but the textarea content
doesn't push live across tabs (LV's open_form carries metadata,
not body text).

If the reviewer opens form A in tab 1, then form B in tab 2, only
form B is open globally — form A in tab 1 disappears. This is the
write-through update at work.

## Tab close

Unless `--no-open` is passed, the browser tab is opened once at
review start (via `Meerkat.Browser.open/1` from `Meerkat.CLI`).
If the user closes it before submitting a decision, meerkat does
not reopen it — the BEAM keeps waiting on the same URL, which is
still printed on stderr at startup. The user can navigate back
manually (or open a new tab on the same port) and the LiveView
reconnects to the same `ReviewServer` with persisted state intact.

## Failure modes

- `Persistence.save/3` failure → in-memory state stays correct,
  broadcast still fires, on-disk state lags. The next mutation
  re-tries the save. A warning lands on stderr.
- Subscriber disconnect (WebSocket drop) → Phoenix client auto-
  reconnects; on mount, `ReviewServer.get_state/1` returns the
  latest. No state lost; the reconnect window is invisible to
  the user.
- ReviewServer crash → DynamicSupervisor restarts it; init loads
  from `Persistence`. Comments persist; in-flight in-memory data
  between save calls is lost (acceptable trade-off — every mutation
  saves before broadcasting).
