<script lang="ts">
  import type { DiffHighlighter } from "@git-diff-view/shiki";
  import type { CljPointer } from "../ts/cljPointer.svelte";
  import CljHoverPopup from "./CljHoverPopup.svelte";

  // What a CljPointer shows: the hover popup, Cmd's underline under a
  // symbol that resolves, and the `No definition found` note.

  let {
    pointer,
    highlighter,
    theme,
    font_size_px,
  }: {
    pointer: CljPointer;
    highlighter: DiffHighlighter | null;
    theme: "light" | "dark";
    font_size_px: number;
  } = $props();

  // On <body>, so no scroller clips them.
  function portal(node: HTMLElement) {
    document.body.appendChild(node);
    return { destroy: () => node.remove() };
  }
</script>

{#if pointer.shown}
  {#key pointer.shown}
    <CljHoverPopup
      hover={pointer.shown.hover}
      anchor={pointer.shown.anchor}
      {highlighter}
      {theme}
      {font_size_px}
      onpointerenter={() => pointer.keepOpen()}
      onpointerleave={() => pointer.closeSoon()}
      ongoto={() => pointer.goToShown()}
    />
  {/key}
{/if}

{#if pointer.link}
  {#each pointer.link.boxes as box}
    <div
      class="clj-link"
      data-test="clj-link"
      use:portal
      style:top="{box.top}px"
      style:left="{box.left}px"
      style:width="{box.width}px"
      style:height="{box.height}px"
    ></div>
  {/each}
{/if}

{#if pointer.note}
  <div
    class="clj-note"
    role="status"
    data-test="clj-no-definition"
    use:portal
    style:top="{pointer.note.y + 8}px"
    style:left="{pointer.note.x}px"
  >
    No definition found
  </div>
{/if}

<style>
  .clj-link {
    position: fixed;
    z-index: 109;
    pointer-events: none;
    border-bottom: 1px solid currentColor;
    color: var(--accent);
  }
  .clj-note {
    position: fixed;
    z-index: 110;
    pointer-events: none;
    padding: 3px 8px;
    border: 1px solid var(--border-strong);
    border-radius: 4px;
    background: var(--panel);
    color: var(--muted);
    font-size: 12px;
  }
</style>
