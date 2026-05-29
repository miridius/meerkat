<script lang="ts">
  // Shared comment form for all four surfaces: global / file /
  // commit-msg / inline. Plain finding-types render one textarea;
  // Suggestion swaps to a split layout — prose textarea on top,
  // CodeMirror code-host below. The composed body on submit is
  // `prose\n\n\`\`\`<lang>\n<code>\n\`\`\`` so GitHub renders the
  // suggestion as a fenced code block.

  import { onDestroy } from "svelte";
  import { createCmEditor } from "../ts/cmEditor";
  import { preloadLanguages } from "../ts/cmLang";
  import type { EditorView } from "@codemirror/view";

  type FindingType = "issue" | "suggestion" | "question" | "follow_up" | "revert";

  type LiveBridge = {
    pushEvent: (event: string, payload: unknown, cb?: (reply: unknown) => void) => void;
  };

  let {
    submitLabel = "Add Comment",
    submitEvent = "comment.submit",
    cancelEvent = "comment_form.hide",
    extraPayload = {},
    initialBody = "",
    initialFindingType = "issue",
    initialLearnFromThis = false,
    initialCode = "",
    language = "plaintext",
    draftKey,
    live,
  }: {
    submitLabel?: string;
    submitEvent?: string;
    cancelEvent?: string;
    extraPayload?: Record<string, unknown>;
    initialBody?: string;
    initialFindingType?: FindingType;
    initialLearnFromThis?: boolean;
    initialCode?: string;
    language?: string;
    draftKey?: string;
    live: LiveBridge;
  } = $props();

  // Hydrate from localStorage if a draft key was passed AND there's
  // something saved. Edit mode (initialBody non-empty) wins over the
  // draft so reopening a saved comment doesn't lose its content.
  function loadDraft(): string {
    if (!draftKey || initialBody) return initialBody;
    return safeLocalStorageGet(draftKey) ?? "";
  }

  // localStorage can throw on quota / private mode. Wrap with a
  // single warn-once so a real fault leaves a breadcrumb in
  // devtools rather than vanishing.
  let storageWarned = false;

  function storageFault(scope: string, err: unknown): void {
    if (storageWarned) return;
    storageWarned = true;
    console.warn(`CommentForm: localStorage ${scope} failed (drafts disabled this session):`, err);
  }

  function safeLocalStorageGet(key: string): string | null {
    try {
      return window.localStorage.getItem(key);
    } catch (err) {
      storageFault("get", err);
      return null;
    }
  }

  function safeLocalStorageSet(key: string, value: string): void {
    try {
      window.localStorage.setItem(key, value);
    } catch (err) {
      storageFault("set", err);
    }
  }

  function safeLocalStorageRemove(key: string): void {
    try {
      window.localStorage.removeItem(key);
    } catch (err) {
      storageFault("remove", err);
    }
  }

  // Suggestion body shape: `<prose>\n\n```<lang>\n<code>\n````. Split
  // on edit so the prose textarea and CodeMirror editor each see
  // their own half.
  function splitSuggestionBody(body: string): { prose: string; code: string } {
    // Match `<prose>\n\n```<lang>?\n<code>\n```$` at end of body.
    // The prose half is GREEDY so a prose paragraph containing an
    // earlier ``` line doesn't bisect the body on the first fence —
    // the regex backtracks until it finds the trailing fence at EOL.
    const m = body.match(/^([\s\S]*)\n*```[^\n]*\n([\s\S]*?)\n```\s*$/);
    if (!m) return { prose: body, code: "" };
    return { prose: m[1].replace(/\n+$/, ""), code: m[2] };
  }

  // Parse the initial body once for edit mode; both `prose` and
  // `code` seed from the same split (the previous shape called
  // splitSuggestionBody three times for the same input).
  const editSplit =
    initialFindingType === "suggestion" && initialBody
      ? splitSuggestionBody(initialBody)
      : null;

  let prose = $state(editSplit ? editSplit.prose : loadDraft());
  // Suggestion-mode code seed: caller's `initialCode` for fresh
  // forms; the parsed code half for edit mode. Plain prose forms
  // ignore this.
  let code = $state(editSplit ? editSplit.code : initialCode || "");
  let findingType = $state<FindingType>(initialFindingType);
  let learnFromThis = $state(initialLearnFromThis);
  let submitInFlight = $state(false);
  let submitError = $state<string | null>(null);

  // Persist draft on every keystroke. Cleared on submit-ack /
  // cancel so a re-open of the same anchor starts blank.
  $effect(() => {
    if (!draftKey) return;
    if (prose.trim().length === 0) {
      safeLocalStorageRemove(draftKey);
    } else {
      safeLocalStorageSet(draftKey, prose);
    }
  });

  function clearDraft() {
    if (!draftKey) return;
    safeLocalStorageRemove(draftKey);
  }

  let codeHost: HTMLDivElement | null = $state(null);
  let cmView: EditorView | null = null;

  // Preload language packs we know about so the CodeMirror mount
  // gets syntax highlighting for the file the comment anchors on.
  // Fire-and-forget — the editor renders without it if the load is
  // still in flight.
  $effect(() => {
    if (findingType === "suggestion") {
      void preloadLanguages([language]);
    }
  });

  // Mount / tear down the CodeMirror editor when entering / leaving
  // suggestion mode. The editor is destroyed and re-created on each
  // re-entry; the form is short-lived enough that the cost is
  // immaterial.
  $effect(() => {
    if (findingType !== "suggestion" || !codeHost) {
      cmView?.destroy();
      cmView = null;
      return;
    }

    if (cmView) return;
    cmView = createCmEditor(codeHost, {
      doc: code,
      language,
      onChange: (v) => (code = v),
      onSubmit: () => submit(),
      onCancel: () => cancel(),
    });
  });

  onDestroy(() => {
    cmView?.destroy();
    cmView = null;
  });

  // Compose the submit body. Plain modes pass through `prose`
  // verbatim. Suggestion mode wraps `code` in a fenced block so the
  // rendered comment carries a `<pre><code>` GitHub recognises as a
  // suggestion.
  function composedBody(): string {
    if (findingType !== "suggestion") return prose;
    // Empty code → emit just prose. A suggestion can stand alone
    // as prose feedback ("we should probably ...") without a
    // concrete code rewrite.
    if (code.trim().length === 0) return prose;
    const fence = "```" + (language || "");
    return `${prose}\n\n${fence}\n${code}\n\`\`\``;
  }

  const submitEnabled = $derived(
    findingType === "revert" || prose.trim().length > 0 || code.trim().length > 0,
  );

  function submit() {
    if (!submitEnabled || submitInFlight) return;
    submitInFlight = true;
    submitError = null;
    live.pushEvent(
      submitEvent,
      {
        ...extraPayload,
        body: composedBody(),
        finding_type: findingType,
        learn_from_this: learnFromThis,
      },
      (reply: unknown) => {
        submitInFlight = false;
        // LV reply shape: { status: "ok" } on success, anything else
        // = treat as error. The server's existing handlers don't
        // return reply payloads today; absence of an explicit "ok"
        // is treated as success (server only acks events it
        // actively rejects), so the draft is cleared on every
        // round-trip that didn't fail.
        if (isReplyError(reply)) {
          const msg = extractReplyMessage(reply);
          submitError = msg ?? "Server rejected the comment — try again.";
          console.warn("CommentForm: submit rejected by server", reply);
          return;
        }
        clearDraft();
      },
    );
  }

  function isReplyError(reply: unknown): boolean {
    return (
      typeof reply === "object" &&
      reply !== null &&
      "status" in reply &&
      (reply as { status: unknown }).status !== "ok"
    );
  }

  function extractReplyMessage(reply: unknown): string | null {
    if (
      typeof reply === "object" &&
      reply !== null &&
      "message" in reply &&
      typeof (reply as { message: unknown }).message === "string"
    ) {
      return (reply as { message: string }).message;
    }
    return null;
  }

  function cancel() {
    clearDraft();
    live.pushEvent(cancelEvent, {});
  }

  // Cmd/Ctrl+Enter submits, Escape cancels. CodeMirror (suggestion
  // mode) wires the same shortcuts via createCmEditor's onSubmit/onCancel
  // hooks; this handler covers the plain textarea path.
  function handleKey(e: KeyboardEvent) {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      submit();
    } else if (e.key === "Escape") {
      e.preventDefault();
      cancel();
    }
  }

  const findingTypes: { type: FindingType; label: string }[] = [
    { type: "issue", label: "Issue" },
    { type: "suggestion", label: "Suggestion" },
    { type: "question", label: "Question" },
    { type: "follow_up", label: "Follow-up" },
    { type: "revert", label: "Revert" },
  ];
</script>

<div class="comment-form note-{findingType}">
  {#if findingType === "suggestion"}
    <textarea
      class="prose"
      bind:value={prose}
      onkeydown={handleKey}
      placeholder="Optional prose explanation (rendered above the suggestion)"
      rows="2"
    ></textarea>
    <div class="code-host" bind:this={codeHost}></div>
  {:else}
    <textarea
      bind:value={prose}
      onkeydown={handleKey}
      placeholder={findingType === "revert"
        ? "Restore from HEAD. Optional explanation below."
        : "Write your comment in Markdown…"}
      rows="4"
    ></textarea>
  {/if}

  <div class="finding-type-row">
    {#each findingTypes as ft}
      <button
        type="button"
        class="finding-chip"
        class:active={findingType === ft.type}
        onclick={() => (findingType = ft.type)}
      >{ft.label}</button>
    {/each}
  </div>

  <label class="learn-from-this">
    <input type="checkbox" bind:checked={learnFromThis} />
    Please learn from this
  </label>

  <div class="actions">
    <button
      type="button"
      class="btn-submit"
      disabled={!submitEnabled || submitInFlight}
      onclick={submit}
    >
      {findingType === "revert" && prose.trim().length === 0
        ? "Ask to restore from HEAD"
        : submitLabel}
    </button>
    <button type="button" class="btn-cancel" onclick={cancel}>Cancel</button>
  </div>

  {#if submitError}
    <p class="submit-error" role="alert" data-test="submit-error">{submitError}</p>
  {/if}
</div>

<style>
  .comment-form {
    padding: 0.75rem;
    border: 1px solid #30363d;
    border-radius: 6px;
    background: #161b22;
    color: #c9d1d9;
  }
  textarea {
    width: 100%;
    min-height: 4lh;
    background: #0d1117;
    color: #c9d1d9;
    border: 1px solid #30363d;
    border-radius: 4px;
    padding: 0.5rem;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.85rem;
    resize: vertical;
  }
  textarea.prose {
    min-height: 2lh;
    margin-bottom: 0.5rem;
  }
  .code-host {
    min-height: 6lh;
    border: 1px solid #30363d;
    border-radius: 4px;
    overflow: hidden;
    user-select: text;
  }
  /* CodeMirror's contenteditable surface inherits user-select from
     the page; force-enable selection so users can copy code out of
     the suggestion editor. */
  :global(.comment-form .cm-editor),
  :global(.comment-form .cm-content),
  :global(.comment-form .cm-line) {
    user-select: text;
  }
  .finding-type-row {
    display: flex;
    gap: 0.25rem;
    margin: 0.5rem 0;
    flex-wrap: wrap;
  }
  .finding-chip {
    padding: 0.2rem 0.6rem;
    background: transparent;
    color: #c9d1d9;
    border: 1px solid #30363d;
    border-radius: 4px;
    font-size: 0.75rem;
    cursor: pointer;
  }
  .finding-chip.active {
    background: #1f6feb;
    color: white;
    border-color: #1f6feb;
  }
  .learn-from-this {
    display: flex;
    gap: 0.4rem;
    align-items: center;
    font-size: 0.8rem;
    margin: 0.5rem 0;
    color: #8b949e;
  }
  .actions {
    display: flex;
    gap: 0.5rem;
    justify-content: flex-end;
  }
  .btn-submit {
    padding: 0.35rem 0.75rem;
    background: #1f6feb;
    color: white;
    border: none;
    border-radius: 4px;
    cursor: pointer;
  }
  .btn-submit:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
  .btn-cancel {
    padding: 0.35rem 0.75rem;
    background: transparent;
    color: #c9d1d9;
    border: 1px solid #30363d;
    border-radius: 4px;
    cursor: pointer;
  }
  .submit-error {
    margin: 0.5rem 0 0;
    padding: 0.4rem 0.6rem;
    background: rgba(248, 81, 73, 0.12);
    border: 1px solid rgba(248, 81, 73, 0.5);
    border-radius: 4px;
    color: #ffa198;
    font-size: 0.8rem;
  }
</style>
