<script lang="ts">
  import type { DiffHighlighter } from "@git-diff-view/shiki";
  import { hastToHtml } from "shiki";
  import { type CljHover, dedentDoc, POPUP_GAP, popupLeft, popupSide } from "../ts/cljHover";

  // The Clojure hover popup (docs/features/clojure-hover.md): two tabs,
  // a var's signature and docstring under its name, and its source,
  // highlighted the way the diff highlights code, under where it lives.

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

  let tab = $state<"doc" | "source">("doc");

  // The diff highlighter's own AST, so the colours follow the diff's
  // theme through the same CSS variables.
  const sourceHtml = $derived.by(() => {
    const ast = highlighter?.getAST(hover.source, "hover.clj", "clojure");
    return ast ? hastToHtml(ast) : null;
  });

  // On <body>, so the diff's horizontal scroller doesn't clip it, and
  // in page coordinates, so it scrolls with the line it describes.
  function portal(node: HTMLElement) {
    document.body.appendChild(node);
    return { destroy: () => node.remove() };
  }

  // The side is chosen at open and the popup fits the room there, so a
  // taller or wider tab scrolls rather than leaving the window. Above,
  // its bottom stays at the symbol. Once the reviewer resizes it, which
  // sets an inline size, it stays put.
  const place = $derived(popupSide(rect.top, rect.bottom, window.innerHeight));
  let popup: HTMLDivElement;
  let height = $state(0);
  let width = $state(0);
  let top = $state(0);
  let left = $state(0);
  $effect(() => {
    if (popup.style.height || popup.style.width) return;
    const y = place.above ? rect.top - Math.min(height, place.cap) - POPUP_GAP : rect.bottom + POPUP_GAP;
    top = y + window.scrollY;
    left = popupLeft(rect.left, width, document.documentElement.clientWidth) + window.scrollX;
  });
</script>

<div
  class="clj-hover-popup"
  role="tooltip"
  data-test="clj-hover"
  use:portal
  bind:this={popup}
  bind:offsetHeight={height}
  bind:offsetWidth={width}
  style:left="{left}px"
  style:top="{top}px"
  style:--clj-hover-cap="{place.cap}px"
  {onpointerenter}
  {onpointerleave}
>
  <div class="clj-hover-tabs" role="tablist">
    <button
      type="button"
      role="tab"
      class="clj-hover-tab"
      class:active={tab === "doc"}
      aria-selected={tab === "doc"}
      onclick={() => (tab = "doc")}
    >
      <code class="clj-hover-name">{hover.name}</code>
      {#if hover.macro}<span class="clj-hover-tag">macro</span>{/if}
    </button>
    <button
      type="button"
      role="tab"
      class="clj-hover-tab clj-hover-where"
      class:active={tab === "source"}
      aria-selected={tab === "source"}
      onclick={() => (tab = "source")}
    >
      {hover.where}:{hover.line}
    </button>
  </div>
  <div class="clj-hover-panel" role="tabpanel">
    {#if tab === "doc"}
      {#if hover.arglists.length > 0}
        <pre class="clj-hover-arglists">{hover.arglists.join("\n")}</pre>
      {/if}
      {#if hover.doc}
        <p class="clj-hover-doc">{dedentDoc(hover.doc)}</p>
      {:else}
        <p class="clj-hover-doc clj-hover-none">No docstring</p>
      {/if}
    {:else}
      <div
        class="diff-tailwindcss-wrapper clj-hover-source"
        data-theme={theme}
        style:font-size="{font_size_px}px"
      >
        <div class="diff-line-syntax-raw">
          {#if sourceHtml}
            {@html sourceHtml}
          {:else}
            <pre>{hover.source}</pre>
          {/if}
        </div>
      </div>
    {/if}
  </div>
</div>

<style>
  .clj-hover-popup {
    position: absolute;
    /* Over the sticky decision footer. */
    z-index: 110;
    display: flex;
    flex-direction: column;
    max-width: min(90ch, calc(100vw - 32px));
    max-height: var(--clj-hover-cap, 60vh);
    /* Resizable from its bottom-right corner; the panel scrolls. */
    resize: both;
    overflow: hidden;
    border: 1px solid var(--border-strong);
    border-radius: 6px;
    background: #161b22;
    color: var(--text);
    box-shadow: 0 8px 24px rgba(1, 4, 9, 0.6);
    font-size: 12px;
  }
  /* Once resized the browser sets an inline size: let it grow to the
     window rather than the opening cap. No other inline style names a
     height. */
  .clj-hover-popup[style*="height"],
  .clj-hover-popup[style*="width"] {
    max-width: calc(100vw - 16px);
    max-height: calc(100vh - 16px);
  }
  .clj-hover-tabs {
    display: flex;
    gap: 6px;
    padding: 6px 8px;
    border-bottom: 1px solid var(--border);
  }
  .clj-hover-tab {
    display: flex;
    align-items: baseline;
    gap: 8px;
    padding: 2px 8px;
    white-space: nowrap;
  }
  .clj-hover-name {
    font-weight: 600;
  }
  .clj-hover-tag,
  .clj-hover-none {
    color: var(--muted);
  }
  .clj-hover-tab.active .clj-hover-tag {
    color: inherit;
  }
  .clj-hover-where {
    margin-left: auto;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  }
  .clj-hover-panel {
    flex: 1;
    min-height: 0;
    overflow: auto;
    padding: 6px 10px 8px;
  }
  .clj-hover-arglists {
    margin: 0 0 6px;
    color: var(--muted);
    white-space: pre-wrap;
  }
  .clj-hover-doc {
    margin: 0;
    white-space: pre-wrap;
  }
  .clj-hover-source {
    width: fit-content;
    min-width: 100%;
    box-sizing: border-box;
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
</style>
