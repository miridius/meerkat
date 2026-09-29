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
`open_form`, and `close_form`. LiveViews never write state directly.

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

`handle_info({:state_changed, state}, socket)` re-assigns `state`
and `open_forms` (from `state.open_forms`). The LV re-renders;
LiveSvelte propagates the new props to DiffViewer / InlineComment /
CommentForm. DiffViewer reconciles inline form rows by key, keeping
forms mounted and re-placing rows after a table re-render.

So: tab A adds a comment → ReviewServer broadcasts → tab B's LV
sees `state_changed` → tab B re-renders with the new comment
visible.

## Open-form propagation

Open-form state is shared through persisted
`ReviewState.open_forms`. Every tab renders every open form, including
forms opened by other tabs. If tab 1 opens A and tab 2 opens B, both
A and B remain open in both tabs. Each add form's prose is held in
its localStorage draft; open-form state carries metadata, not live
textarea content.

Each form carries a `form_key` derived from its surface, anchor and
edit target. Submit and cancel act only on the form with that key.
A submit for a key that is no longer open (for example, closed in
another tab while the submit was in flight) saves nothing and shows
an error on the form, which keeps its draft. Removing a comment also
closes any form editing it, in every tab.

## Tab close

Unless `--no-open` is passed, the browser tab is opened at review
start. A later invocation that reattaches to a review with no tab
connected opens it again, unless `--no-open` was passed. An
invocation collecting a decision already made opens no tab.

If the user closes the tab before submitting a decision, meerkat
does not reopen it for the invocation that is already waiting — the
server keeps waiting on the same URL, printed on stderr. The user
can navigate back manually (or open a new tab on the same port) and
the LiveView reconnects to the same `ReviewServer` with state intact.

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
