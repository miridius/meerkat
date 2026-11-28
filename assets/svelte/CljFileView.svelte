<script lang="ts">
  import type { DiffHighlighter } from "@git-diff-view/shiki";
  import { hastToHtml } from "shiki";
  import { type View, type ViewDetail, VIEW_EVENT, closeView, escStepsBack, jumpTo, stepBack } from "../ts/cljJump";
  import { CljPointer } from "../ts/cljPointer.svelte";
  import { DIFF_THEME, sharedHighlighter } from "../ts/diffHighlighter";
  import { languageFor } from "../ts/languageFor";
  import CljPointerLayer from "./CljPointerLayer.svelte";

  // Go to definition's file view (docs/features/clojure-go-to-definition.md):
  // a read-only panel over the diff showing a file outside it, as
  // reviewed, highlighted as the diff is, at the definition's line.
  // Hover and go to definition work in it.

  let {
    font_size_px = 13,
    tab_size = 2,
    live,
  }: {
    font_size_px?: number;
    tab_size?: number;
    live: { pushEvent: (event: string, payload: unknown) => void };
  } = $props();

  // Request ids, unique to this view: only it asks for files.
  let lastId = 0;
  let request = 0;
  let open = $state<View | null>(null);
  // The open file's text, once the server sends it.
  let text = $state<string | null>(null);
  let shownWhere: string | null = null;
  let highlighter = $state<DiffHighlighter | null>(null);
  let body: HTMLDivElement | undefined = $state();

  // A jump within the open file keeps its path, so its highlighting stays.
  const where = $derived(open?.where ?? null);
  const lines = $derived(text === null ? [] : text.replace(/\n$/, "").split("\n"));

  // Each line's highlighted HTML, from the diff highlighter's AST: a
  // <pre><code> of one <span class="line"> per line.
  const lineHtml = $derived.by(() => {
    if (text === null || !highlighter || where === null) return null;
    const ast = highlighter.getAST(text, where, languageFor(where));
    const code = (ast?.children[0] as { children?: unknown[] } | undefined)?.children?.[0] as
      | { children: { type: string }[] }
      | undefined;
    if (!code) return null;
    return code.children.filter((n) => n.type === "element").map((n) => hastToHtml(n as never));
  });

  const pointer = new CljPointer(
    live,
    () => ({ where: open?.where ?? "" }),
    () => open?.side ?? "new",
    (jump, side) => {
      if (open) jumpTo(jump, side, live, { view: { ...open, scrollTop: body?.scrollTop ?? 0 } });
    },
  );

  $effect(() => {
    sharedHighlighter.then((h) => {
      highlighter = h;
    });
    const onView = (e: Event) => {
      const detail = (e as CustomEvent<ViewDetail>).detail;
      open = detail;
      if (!detail) return;
      if (detail.where === shownWhere && text !== null) {
        show(detail);
        return;
      }
      text = null;
      shownWhere = null;
      lastId += 1;
      request = lastId;
      live.pushEvent("clj.view", { id: lastId, where: detail.where });
    };
    const onText = (e: Event) => {
      const { id, view } = (e as CustomEvent<{ id: number; view: { where: string; text: string } | null }>).detail;
      if (id !== request || !open) return;
      // The file is gone: back to where the jump started.
      if (!view) {
        if (!stepBack()) open = null;
        return;
      }
      text = view.text;
      shownWhere = view.where;
      const shown = open;
      requestAnimationFrame(() => show(shown));
    };
    // Esc steps back from the latest jump, in the view or the diff. It
    // listens first, to see the page before Esc closes anything.
    const onKey = (e: KeyboardEvent) => {
      if (!escStepsBack(e)) return;
      e.preventDefault();
      stepBack();
    };
    // A click outside the view, and the popups it opens, closes it.
    const onPointer = (e: PointerEvent) => {
      const target = e.target as Element | null;
      if (open && !target?.closest(".clj-file-view, .clj-hover-popup")) closeView();
    };
    window.addEventListener(VIEW_EVENT, onView);
    window.addEventListener("phx:clj:view", onText);
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("pointerdown", onPointer, true);
    return () => {
      window.removeEventListener(VIEW_EVENT, onView);
      window.removeEventListener("phx:clj:view", onText);
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("pointerdown", onPointer, true);
    };
  });

  $effect(() => {
    if (body) return pointer.listen(body);
  });

  // Scrolls the view where `view` says: where it was, or to its line,
  // flashed.
  function show(view: View | null) {
    if (view?.scrollTop === undefined) {
      if (view) reveal(view.line);
    } else if (body) body.scrollTop = view.scrollTop;
  }

  // Scrolls line `n` to the middle of the view and flashes it.
  function reveal(n: number) {
    const row = body?.querySelector<HTMLElement>(`[data-clj-line="${n}"]`);
    if (!row) return;
    row.scrollIntoView({ block: "center" });
    row.animate(
      [
        { boxShadow: "inset 0 0 0 100vmax rgba(88, 166, 255, 0.35)", offset: 0 },
        { boxShadow: "inset 0 0 0 100vmax rgba(88, 166, 255, 0.35)", offset: 0.6, easing: "ease-out" },
      ],
      1600,
    );
  }
</script>

{#if open}
  <div class="clj-file-view" role="dialog" aria-label={open.where} data-test="clj-file-view">
    <header>
      <code class="where">{open.where}</code>
      <span class="hint">Read-only</span>
      <button type="button" class="close" aria-label="Close file view" title="Close" onclick={closeView}>×</button>
    </header>
    <div
      class="body diff-tailwindcss-wrapper"
      class:clj-linking={pointer.link !== null}
      data-theme={DIFF_THEME}
      role="presentation"
      bind:this={body}
      style:font-size="{font_size_px}px"
      style:tab-size={tab_size}
      onpointermove={(e) => pointer.move(e, false)}
      onpointerleave={() => pointer.leave()}
    >
      {#if text === null}
        <p class="loading">Loading…</p>
      {:else}
        {#each lines as line, i}
          <!-- No whitespace between the spans: the row keeps it. -->
          <div class="row" data-clj-line={i + 1}><span class="num">{i + 1}</span><span class="code diff-line-syntax-raw"
              >{#if lineHtml?.[i] !== undefined}{@html lineHtml[i]}{:else}{line}{/if}</span
            ></div>
        {/each}
      {/if}
    </div>
  </div>
  <CljPointerLayer {pointer} {highlighter} theme={DIFF_THEME} {font_size_px} />
{/if}

<style>
  .clj-file-view {
    position: fixed;
    inset: 48px 24px 24px;
    /* Over the diff and its sticky footer, under the hover popup. */
    z-index: 108;
    display: flex;
    flex-direction: column;
    border: 1px solid var(--border-strong);
    border-radius: 6px;
    background: #0d1117;
    box-shadow: 0 8px 24px rgba(1, 4, 9, 0.6);
  }
  header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 10px;
    border-bottom: 1px solid var(--border);
    background: var(--panel);
  }
  .where {
    font-weight: 600;
  }
  .hint {
    color: var(--muted);
    font-size: 12px;
  }
  .close {
    margin-left: auto;
    padding: 0 8px;
    font-size: 16px;
    line-height: 1.4;
  }
  .body {
    flex: 1;
    min-height: 0;
    overflow: auto;
    padding: 6px 0;
    font-family: Menlo, Consolas, monospace;
  }
  .row {
    display: flex;
    white-space: pre;
  }
  .num {
    flex: none;
    width: 5ch;
    padding-right: 1.5ch;
    text-align: right;
    color: var(--muted);
    user-select: none;
  }
  .code {
    flex: 1;
  }
  .code :global(.line) {
    white-space: pre;
  }
  .body.clj-linking .code {
    cursor: pointer;
  }
  .loading {
    margin: 8px 12px;
    color: var(--muted);
  }
</style>
