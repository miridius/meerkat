<script lang="ts">
  import type { DiffHighlighter } from "@git-diff-view/shiki";
  import { hastToHtml } from "shiki";
  import { type CljHover, dedentDoc, shownSource } from "../ts/cljHover";

  // The Clojure hover popup (docs/features/clojure-hover.md): a var's
  // name, signature, docstring and source, the source highlighted the
  // way the diff highlights code.

  let {
    hover,
    rect,
    highlighter,
    theme,
    font_size_px,
    onpointerenter,
    onpointerleave,
  }: {
    hover: CljHover;
    rect: DOMRect;
    highlighter: DiffHighlighter | null;
    theme: "light" | "dark";
    font_size_px: number;
    onpointerenter: () => void;
    onpointerleave: () => void;
  } = $props();

  let expanded = $state(false);
  const source = $derived(shownSource(hover.source, expanded));

  // The diff highlighter's own AST, so the colours follow the diff's
  // theme through the same CSS variables.
  const sourceHtml = $derived.by(() => {
    const ast = highlighter?.getAST(source.text, "hover.clj", "clojure");
    return ast ? hastToHtml(ast) : null;
  });

  // On <body>, so the diff's horizontal scroller doesn't clip it, and
  // in page coordinates, so it scrolls with the line it describes.
  function portal(node: HTMLElement) {
    document.body.appendChild(node);
    return { destroy: () => node.remove() };
  }

  // Below the symbol, or above it when only above has room.
  const GAP = 4;
  let height = $state(0);
  const top = $derived.by(() => {
    const below = window.innerHeight - rect.bottom;
    const above = height > below - GAP && rect.top > below;
    return (above ? rect.top - height - GAP : rect.bottom + GAP) + window.scrollY;
  });
</script>

<div
  class="clj-hover-popup"
  role="tooltip"
  data-test="clj-hover"
  use:portal
  bind:offsetHeight={height}
  style:left="{rect.left + window.scrollX}px"
  style:top="{top}px"
  {onpointerenter}
  {onpointerleave}
>
  <header>
    <code class="clj-hover-name">{hover.name}</code>
    {#if hover.macro}<span class="clj-hover-tag">macro</span>{/if}
    <span class="clj-hover-where">{hover.where}:{hover.line}</span>
  </header>
  {#if hover.arglists.length > 0}
    <pre class="clj-hover-arglists">{hover.arglists.join("\n")}</pre>
  {/if}
  {#if hover.doc}
    <p class="clj-hover-doc">{dedentDoc(hover.doc)}</p>
  {/if}
  <div
    class="diff-tailwindcss-wrapper clj-hover-source"
    data-theme={theme}
    style:font-size="{font_size_px}px"
  >
    <div class="diff-line-syntax-raw">
      {#if sourceHtml}
        {@html sourceHtml}
      {:else}
        <pre>{source.text}</pre>
      {/if}
    </div>
  </div>
  {#if source.collapsed}
    <button type="button" class="clj-hover-expand" onclick={() => (expanded = true)}>
      Show all {source.total} lines
    </button>
  {/if}
</div>

<style>
  .clj-hover-popup {
    position: absolute;
    /* Over the sticky decision footer. */
    z-index: 110;
    max-width: min(90ch, calc(100vw - 32px));
    max-height: 60vh;
    overflow: auto;
    padding: 8px 10px;
    border: 1px solid var(--border-strong);
    border-radius: 6px;
    background: #161b22;
    color: var(--text);
    box-shadow: 0 8px 24px rgba(1, 4, 9, 0.6);
    font-size: 12px;
  }
  header {
    display: flex;
    align-items: baseline;
    gap: 8px;
  }
  .clj-hover-name {
    font-weight: 600;
  }
  .clj-hover-tag,
  .clj-hover-where {
    color: var(--muted);
  }
  .clj-hover-where {
    margin-left: auto;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  }
  .clj-hover-arglists {
    margin: 6px 0 0;
    color: var(--muted);
    white-space: pre-wrap;
  }
  .clj-hover-doc {
    margin: 6px 0 0;
    white-space: pre-wrap;
  }
  .clj-hover-source {
    margin-top: 8px;
    padding: 6px 8px;
    border-radius: 4px;
    background: var(--diff-plain-content--);
  }
  .clj-hover-source :global(pre) {
    margin: 0;
    background: none;
    white-space: pre;
    /* The family @git-diff-view sets inline on the diff table. */
    font-family: Menlo, Consolas, monospace;
  }
  .clj-hover-expand {
    margin-top: 6px;
  }
</style>
