<script lang="ts">
  // Single inline-comment row — finding-type badge, line anchor,
  // body, and Edit / Remove affordances that pushEvent back into
  // the LiveView for the GenServer-side mutation. The suggestion-
  // mode CodeMirror editor lives in the page-level form, not here.

  type FindingType = "issue" | "suggestion" | "question" | "follow_up" | "revert";

  type InlineCommentT = {
    id: string;
    file_index: number;
    start_line: number;
    end_line: number;
    side: "old" | "new" | string;
    body: string;
    body_html?: string;
    finding_type: FindingType | string;
    created_at: string;
    learn_from_this?: boolean | null;
  };

  type LiveBridge = {
    pushEvent: (event: string, payload: unknown, cb?: (reply: unknown) => void) => void;
  };

  let { comment, live }: { comment: InlineCommentT; live: LiveBridge } = $props();

  const lineLabel = $derived(
    comment.start_line === comment.end_line
      ? `L${comment.start_line}`
      : `L${comment.start_line}–${comment.end_line}`,
  );

  function edit() {
    live.pushEvent("comment_form.edit", { surface: "inline", id: comment.id });
  }

  function remove() {
    live.pushEvent("comment.remove", { surface: "inline", id: comment.id });
  }

  function toggleLearn(e: Event) {
    const target = e.currentTarget as HTMLInputElement;
    live.pushEvent("comment.toggle_learn", {
      surface: "inline",
      id: comment.id,
      learn: target.checked ? "true" : "false",
    });
  }
</script>

<li class="inline-comment note-{comment.finding_type}">
  <header>
    <span class="finding-badge">
      {comment.finding_type === "thought" || comment.finding_type === "follow_up"
        ? "follow-up"
        : comment.finding_type}
    </span>
    <span class="line-anchor">{lineLabel} ({comment.side === "old" ? "old" : "new"})</span>
    <label class="learn-toggle" title="Include this comment in the agent's learning corpus">
      <input
        type="checkbox"
        checked={!!comment.learn_from_this}
        onchange={toggleLearn}
      />
      <span>learn from this</span>
    </label>
    <div class="actions">
      <button type="button" class="action" onclick={edit}>Edit</button>
      <button type="button" class="action" onclick={remove}>Remove</button>
    </div>
  </header>
  <!-- body_html is server-rendered via Meerkat.Markdown.to_safe_html
       in review_live.ex (with_body_html/1). Suggestion-mode fences
       become syntax-highlighted <pre><code class="language-xxx"> blocks. -->
  <div class="comment-body markdown">{@html comment.body_html ?? comment.body}</div>
</li>

<style>
  .inline-comment {
    padding: 0.6rem 0.85rem;
    border-bottom: 1px solid #30363d;
    background: #0d1117;
    color: #e6edf3;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    font-size: 0.9rem;
    line-height: 1.45;
  }
  .inline-comment:last-child { border-bottom: none; }
  .comment-body {
    color: #e6edf3;
  }
  header {
    display: flex;
    gap: 0.5rem;
    align-items: baseline;
    margin-bottom: 0.25rem;
  }
  .learn-toggle {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.75rem;
    color: #8b949e;
    cursor: pointer;
    user-select: none;
  }
  .learn-toggle input[type="checkbox"] {
    margin: 0;
  }
  .actions {
    margin-left: auto;
    display: flex;
    gap: 0.4rem;
  }
  .action {
    background: transparent;
    color: #8b949e;
    border: 1px solid #30363d;
    border-radius: 3px;
    padding: 1px 8px;
    font-size: 0.75rem;
    cursor: pointer;
  }
  .action:hover {
    color: #c9d1d9;
    border-color: #58a6ff;
  }
  .finding-badge {
    padding: 0 0.4rem;
    border-radius: 3px;
    font-size: 0.7rem;
    text-transform: uppercase;
    font-weight: 600;
  }
  .note-issue .finding-badge { background: #ff7b00; color: #0d1117; }
  .note-suggestion .finding-badge { background: #f0c419; color: #0d1117; }
  .note-question .finding-badge { background: #3fb950; color: #0d1117; }
  .note-follow_up .finding-badge,
  .note-thought .finding-badge { background: #8b949e; color: #0d1117; }
  .note-revert .finding-badge { background: #ff3b30; color: white; }
  .line-anchor { color: #8b949e; font-size: 0.75rem; }
</style>
