# Multi-tab convergence

Multiple browser tabs pointed at the same meerkat URL converge to
a single canonical state via Phoenix.PubSub. Useful when the
reviewer wants two views on the same review (split a wide monitor
between commit-message + a specific file's diff) or when a hot
reload causes the LV's WebSocket to reconnect.

## Server-as-truth

`Meerkat.ReviewServer` (one GenServer per `review_id`) owns the
canonical `%ReviewState{}`. Mutations to persisted review data flow
through it via `add_*_comment`, `remove_comment`, `set_approved`,
`set_extension_hidden`, `set_show_generated`, `set_learn_from_this`,
`open_form`, and `close_form`. LiveViews never write canonical state
directly. The `ReviewState.view` map holds shared page-view state; it
is not persisted.

Persisted mutations go through `ReviewServer.update/2`:

1. Runs the state transformer.
2. Attempts to persist the new state to
   `<gitdir>/meerkat-precommit/in-progress/<review_id>.json` via
   `Meerkat.Persistence.save/3`.
3. Broadcasts `{:state_changed, %ReviewState{}}` on the topic
   `"review:#{review_id}"`.

View changes go through `ReviewServer.update_view/2`: it applies a
change function to `state.view` and broadcasts
`{:state_changed, %ReviewState{}}` without saving to disk. A BEAM
restart resets the shared view.

## Subscriber side

`MeerkatWeb.ReviewLive.mount/3` calls
`Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(rid))`
when `connected?(socket)`. Every connected tab receives the
broadcast.

`ReviewServer` stamps each broadcast state's `rev` with a node-wide
monotonically increasing integer. `handle_info({:state_changed, state},
socket)` ignores a broadcast whose `rev` is lower than the tab's current
state; otherwise it assigns `state`, `open_forms` and every view field
from `state.view`. An earlier broadcast can arrive after the tab has
assigned the newer state returned by a later event, so this prevents a
rollback. The LV re-renders; LiveSvelte propagates the new props to
DiffViewer / InlineComment / CommentForm. DiffViewer reconciles inline
form rows by key, keeping forms mounted and re-placing rows after a
table re-render.

So: tab A adds a comment → ReviewServer broadcasts → tab B's LV
sees `state_changed` → tab B re-renders with the new comment
visible.

## Open-form propagation

Open-form state is shared through persisted
`ReviewState.open_forms`. Every tab renders every open form, including
forms opened by other tabs. If tab 1 opens A and tab 2 opens B, both
A and B remain open in both tabs.
Each form's localStorage draft holds, as JSON, the prose, suggestion
code, finding type and learn flag values that differ from how the form
opened. It is updated on every change, removed when the form returns
to its opening values, and cleared on submit or cancel. This applies
to add and edit forms. A draft saved as plain prose before this change
still loads. A `storage` listener mirrors changes to other tabs
already showing the form; opening or reloading the form restores the
draft.

Each form carries a `form_key` derived from its surface, anchor and
edit target. Submit and cancel act only on the form with that key.
When another tab closes a form while its submit is in flight, the
submit saves nothing. The server replies with an error, but the close
has already reached the submitting tab, so the form is gone before
the reply arrives and no error is shown.
If another tab closes any form with Cancel, that form's shared
localStorage draft is cleared, so unsaved changes in the submitting
tab are lost.
The error reply only prevents that tab from taking the success path
that would clear the draft itself.
Removing a comment also closes any open form editing it in every tab,
so saving that form cannot bring the comment back.

## Cross-tab sync contract

The owner’s requirement is: “all tabs should stay in sync completely,
or we should block multiple tabs … anything in between sucks”.

Every tab connected to a review shares the server-held `ReviewState.view`.
It includes toolbar settings (split/unified, wrap, font size and tab
size), the settings and version popovers, the files panel, filter text,
show-only file, file-collapse state, rendered-markdown toggles, hunk
expansions, tip dismissal and the error banner. Changes are broadcast
to every tab, and a later-opened tab receives the current view. The
view is not persisted; a BEAM restart, including a DevWatcher hot
reload or ReviewServer crash, resets it. A failed snapshot save puts
the error in `view.flash_error` in the broadcast state, so every tab
shows the banner.

Toolbar settings are also saved in `meerkat:settings` in localStorage
per browser. On mount, `settings.load` writes those values into the
shared view, changing what every tab shows. A tip dismissal is
remembered per browser in `meerkat:hint-dismissed`; if set on mount,
HintDismiss hides the tip and pushes `hint.dismiss`. The server then
sets `hint_dismissed` and hides the tip in every tab, and sends
`hint:set-dismissed` back to the sending tab so its Settings hook
writes the browser flag.

Hunk-expand clicks go to the server and are appended, in order, to
`view.hunk_expansions[file_name]`. Every tab's DiffViewer replays that
list. Expansions remain in the list when a file is collapsed and
re-expanded.

Each form's `draftKey` in localStorage holds a JSON draft of the prose,
suggestion code, finding type and learn flag values that differ from
how the form opened. This applies to add and edit forms. Drafts are
written on every change, removed when the form returns to its opening
values, and cleared on submit or cancel. Plain-prose drafts saved
before this change still load. A `storage` listener mirrors changes
into other tabs already showing the form; a tab opening or reloading
the form restores the draft. A received draft is marked as already
stored before it is applied, preventing a stale write-back from
overwriting newer typing or echoing endlessly between tabs. Keys use
`meerkat:draft:<review_id>:` followed by the form's key (surface,
anchor and edit target). Inline keys are
`meerkat:draft:<review_id>:inline:<file_index>:<side>:<start_line>-<end_line>`,
with `:edit:<comment_id>` appended for an edit form.

Browser-held tab state uses localStorage keys of the form
`meerkat:view:<review_id>:<name>`. It includes scroll position and an
in-progress drag selection in the DiffViewer line-number gutter or
the commit-message gutter. Other tabs follow changes via the
`storage` event, and a tab reads the current value when it opens.
Scroll is saved as the file section at the top of the viewport and the
fraction scrolled into it, so different window widths show the same
place. This replaces the old per-tab sessionStorage scroll stash, so
a reload after a live restart restores the shared position. On
decision, the `phx:drafts:wipe` listener removes these view keys as
well as the `meerkat:draft:<review_id>:` keys. A tab does not save
scroll events until its initial shared-position restore finishes; with
no shared position, it saves them immediately. Browser scroll
restoration is disabled, so this code is the only restore. Drag state
is cleared on `pagehide` when its tab closes or reloads, but a crash or
kill without that event can leave the highlight until another drag or
a decision wipes the tab state. Unlike drag state, scroll state
outlives the tab.

The version chip's seen badge refreshes on a `storage` event, so
opening the changelog in any tab clears the badge in every tab.

Keyboard focus, text cursor, native text selection, hover and each
tab's connection indicator are not synced; they are per-window.
Comment-submit in-flight state lasts one round trip, and the form
closes in every tab when it ends. Sharing that state could leave other
tabs' submit buttons disabled if the submitting tab closed mid-flight.

## Decision convergence

When a decision is made in any tab—by a button click or an
auto-approved timeout—`Meerkat.Decision` broadcasts
`{:meerkat_decision, decision}` on `Decision.decision_topic()`
(`"meerkat:decision"`). Every connected `ReviewLive` subscribes to
this topic and assigns `:done` when it receives the decision, so all
open tabs switch to the done view and cannot be edited after the
decision. A tab mounted after the decision also opens in the done
view via `Decision.current/0`.

Drafts in `localStorage` are shared across tabs on the same origin.
Every connected tab receives the decision broadcast and pushes
`drafts:wipe`; the `phx:drafts:wipe` window listener removes all
`meerkat:draft:<review_id>:` and `meerkat:view:<review_id>:` keys.
This prevents stale drafts or tab state from resurfacing for the same
review on a later invocation on that origin, even when no tab made the
decision, as with an auto-approved timeout.

The CLI deletes the in-progress snapshot as soon as a decision is
made, whether or not an invocation is attached, and deletes it again
after delivery to catch a save already in flight. The next invocation
for the same `review_id` starts with no comments, including one that
replaces a review holding an undelivered decision after the commit
message changes.

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

- `Persistence.save/3` failure → the in-memory state stays correct
  and a warning goes to stderr. `ReviewServer.update/2` puts the
  "Comments aren't being saved to disk" message in
  `view.flash_error` and broadcasts it with `:state_changed`, so every
  tab shows the banner; no separate `:persistence_failed` message is
  broadcast. The next mutation retries the save.
- Subscriber disconnect (WebSocket drop) → Phoenix client auto-
  reconnects; on mount, `ReviewServer.get_state/1` returns the
  latest. No state lost; the reconnect window is invisible to
  the user.
- ReviewServer crash → DynamicSupervisor restarts it; init loads the
  persisted snapshot from `Persistence`. Persisted comments are
  restored, but unsaved in-memory data can be lost. The shared view
  is lost too because it is never saved.
