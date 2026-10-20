<script context="module" lang="ts">
  import type { DiffHighlighter } from "@git-diff-view/shiki";
  import { getDiffViewHighlighter, highlighterReady } from "@git-diff-view/shiki";

  // Eagerly create ONE shiki engine with the languages we expect to
  // hit in a typical review. shiki warns at 10 instances and a
  // per-component `<script>` block would create one per DiffViewer
  // mount; `<script context="module">` runs exactly once per module
  // load, so every DiffViewer reuses the same singleton. Languages
  // outside this list (or shiki bundles like `puml`) fall back to
  // lowlight automatically.
  const PRELOAD_LANGS = [
    "typescript",
    "tsx",
    "javascript",
    "jsx",
    "json",
    "html",
    "css",
    "markdown",
    "bash",
    "python",
    "go",
    "ruby",
    "rust",
    "c",
    "cpp",
    "java",
    "kotlin",
    "swift",
    "yaml",
    "sql",
    "xml",
    "elixir",
    "erlang",
    "clojure",
    "lisp",
    "diff",
  ];

  // @git-diff-view skips syntax highlighting entirely for files longer
  // than maxLineToIgnoreSyntax (a per-highlighter guard against shiki
  // tokenize cost on huge files). The default is 2000 lines, which real
  // hand-written files exceed — a 2.3k-line test file rendered with no
  // highlighting at all. Raise it to a bound that still protects
  // against generated monsters but never bites on code a human wrote.
  const MAX_SYNTAX_LINES = 20_000;

  // Importing @git-diff-view/shiki also builds its default engine, which
  // lacks languages above such as clojure and elixir, and whichever
  // engine finishes last is the one it highlights with. Once both are
  // built, asking for ours again selects it.
  const sharedHighlighter: Promise<DiffHighlighter | null> = Promise.all([
    highlighterReady,
    getDiffViewHighlighter(PRELOAD_LANGS as never[]),
  ])
    .then(() => getDiffViewHighlighter(PRELOAD_LANGS as never[]))
    .then((h) => {
      // Guarded separately from the engine-init catch below: a setter
      // failure (adapter shape drift on a dependency bump) must not
      // null out the whole highlighter — files under the library's
      // 2000-line default would still highlight fine.
      try {
        h.setMaxLineToIgnoreSyntax(MAX_SYNTAX_LINES);
      } catch (e) {
        console.warn(
          "DiffViewer: setMaxLineToIgnoreSyntax failed; files over the library's 2000-line default will render unhighlighted",
          e,
        );
      }
      return h as DiffHighlighter;
    })
    .catch((e) => {
      console.warn("DiffViewer: shiki highlighter init failed; falling back to lowlight", e);
      return null;
    });

  function getCachedHighlighter(lang: string): Promise<DiffHighlighter | null> {
    if (!lang || lang === "plaintext" || lang === "text") return Promise.resolve(null);
    return sharedHighlighter;
  }

  // The diff's theme, which the Clojure hover popup's source follows.
  const DIFF_THEME = "dark";

  // Clojure hover request ids, unique across every DiffViewer on the
  // page, since each one hears every answer.
  let lastHoverId = 0;

  // A code cell font's `2em` and `1ch` in px, by font, for the rulers.
  const fontWidthCache = new Map<string, { offset: number; ch: number }>();
</script>

<script lang="ts">
  import { DiffFile, DiffView, DiffModeEnum } from "@git-diff-view/svelte";
  import "@git-diff-view/svelte/styles/diff-view.css";
  import { mount, unmount } from "svelte";
  import InlineComment from "./InlineComment.svelte";
  import CommentForm from "./CommentForm.svelte";
  import PlantUmlPreview from "./PlantUmlPreview.svelte";
  import CljHoverPopup from "./CljHoverPopup.svelte";
  import { type CljHover, HOVER_DELAY_MS, type HoverAnchor, keepsPopup, rescrolled, spotAt } from "../ts/cljHover";
  import { textAbove } from "../ts/cmIndent";
  import { languageFor } from "../ts/languageFor";
  import { fittingColumns, rulerBackground } from "../ts/rulers";
  import { unifiedDiff } from "../ts/unifiedDiff";

  // Renders ONE file's diff body via `@git-diff-view`, the read-only
  // inline comment list, and the pointer-drag selection logic that
  // opens an inline comment form anchored at the clicked / dragged
  // line range.

  type MovedBlock = {
    side: "old" | "new";
    line_start: number;
    line_end: number;
    pair_id: number;
    to_file: string;
    to_side: "old" | "new";
    to_line_start: number;
    to_line_end: number;
  };

  type FileDiff = {
    file_name: string;
    old_file_name?: string | null;
    old_content: string;
    new_content: string;
    hunks: string[];
    status?: string | null;
    read_errors?: string[] | null;
    is_binary?: boolean;
    moved_lines?: MovedBlock[] | null;
  };

  type FindingType = "issue" | "suggestion" | "question" | "follow_up" | "revert";

  type InlineCommentT = {
    id: string;
    file_index: number;
    start_line: number;
    end_line: number;
    side: "old" | "new" | string;
    body: string;
    finding_type: FindingType | string;
    created_at: string;
    correct_instructions?: boolean | null;
    lint_rule?: boolean | null;
  };

  type LiveBridge = {
    pushEvent: (event: string, payload: unknown, cb?: (reply: unknown) => void) => void;
  };

  type InlineFormDescriptor = {
    key: string;
    anchor: {
      file_index: number;
      start_line: number;
      end_line: number;
      side: "old" | "new" | string;
    };
    props: Record<string, unknown>;
  };

  let {
    file,
    file_index,
    mode = "split",
    wrap_lines = false,
    font_size_px = 13,
    tab_size = 2,
    ruler_columns = [],
    comments = [],
    inline_forms = [],
    plantuml_available = false,
    clj_hover = false,
    live,
  }: {
    file: FileDiff;
    file_index: number;
    mode?: "split" | "unified";
    wrap_lines?: boolean;
    font_size_px?: number;
    tab_size?: number;
    ruler_columns?: number[];
    comments?: InlineCommentT[];
    inline_forms?: InlineFormDescriptor[];
    plantuml_available?: boolean;
    clj_hover?: boolean;
    live: LiveBridge;
  } = $props();

  // True for `.puml` / `.plantuml` files — drives the inline
  // diagram preview rendered below the diff body.
  const isPlantUml = $derived(
    /\.(puml|plantuml)$/i.test(file.file_name ?? ""),
  );

  // Force unified mode for pure-added / pure-deleted files. Split
  // mode wastes the empty side of the diff (a freshly-added file
  // has no "old" content, so half the horizontal real estate goes
  // to a column of blanks). Status is `added` / `modified` /
  // `deleted` / `renamed`; renamed/modified keep split.
  const isOneSided = $derived(file.status === "added" || file.status === "deleted");

  // Use DiffModeEnum.SplitGitLab instead of DiffModeEnum.Split: it's
  // the only @git-diff-view mode that draws hunk expand buttons in
  // the new-side (right-hand) gutter. It also draws them in the
  // old-side gutter, with the hunk header text beside them; the CSS
  // below hides that old-side copy.
  const diffViewMode = $derived(
    isOneSided
      ? DiffModeEnum.Unified
      : mode === "unified"
        ? DiffModeEnum.Unified
        : DiffModeEnum.SplitGitLab,
  );

  // @git-diff-view's `renderExtendLine` snippet for unified mode
  // only fires on collapsed/hidden lines — it can't anchor extends
  // below visible diff rows. We render comments via DOM injection
  // instead (see `renderInlineComments` below + the `$effect` that
  // drives it): a custom `<tr class="meerkat-comment-row">` is
  // inserted right after the anchor row, hosting the InlineComment
  // component.
  type CommentGroup = { side: "old" | "new"; line: number; comments: InlineCommentT[] };
  const commentGroups: () => CommentGroup[] = () => {
    const map = new Map<string, CommentGroup>();
    for (const c of comments) {
      const side = c.side === "old" ? "old" : "new";
      const key = `${side}:${c.end_line}`;
      const existing = map.get(key);
      if (existing) existing.comments.push(c);
      else map.set(key, { side, line: c.end_line, comments: [c] });
    }
    return Array.from(map.values());
  };

  let diffInstance = $state<DiffFile | null>(null);
  let renderError = $state<string | null>(null);
  let diffContainer: HTMLDivElement | null = $state(null);
  let highlighter = $state<DiffHighlighter | null>(null);

  // Per-language Shiki highlighter — pulled from the module-level
  // cache so every DiffViewer instance shares one engine per lang.
  // Languages shiki doesn't bundle resolve to `null` quietly and
  // the diff falls through to the lowlight engine.
  const fileLanguage = $derived(languageFor(file.file_name));

  $effect(() => {
    const lang = fileLanguage;
    if (file.is_binary || !lang || lang === "plaintext" || lang === "text") {
      highlighter = null;
      return;
    }
    let cancelled = false;
    getCachedHighlighter(lang).then((h) => {
      if (!cancelled) highlighter = h;
    });
    return () => {
      cancelled = true;
    };
  });

  $effect(() => {
    if (file.is_binary) {
      diffInstance = null;
      renderError = null;
      return;
    }
    const oldName = file.old_file_name ?? file.file_name;
    try {
      const instance = DiffFile.createInstance({
        oldFile: { fileName: oldName, fileLang: fileLanguage, content: file.old_content },
        newFile: { fileName: file.file_name, fileLang: fileLanguage, content: file.new_content },
        hunks: [unifiedDiff(oldName, file.file_name, file.hunks)],
      });
      instance.init();
      instance.buildSplitDiffLines();
      instance.buildUnifiedDiffLines();
      diffInstance = instance;
      renderError = null;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error("DiffViewer: createInstance failed for", file.file_name, err);
      renderError = msg;
      diffInstance = null;
    }
  });

  // --- Pointer drag-select for line ranges ---

  type DragHit = { line: number; side: "old" | "new" };

  let dragStart = $state<DragHit | null>(null);
  let dragCurrent = $state<DragHit | null>(null);

  // Hit-test a DOM target down to a line number + side. Returns null
  // for non-line-number targets — including code-content cells, so
  // clicks/drags on actual code remain available for native text
  // selection (copy/paste). Only the line-number gutter triggers a
  // comment-range drag.
  function extractLineTarget(target: HTMLElement): DragHit | null {
    if (!target.closest("tr.diff-line")) return null;

    // Restrict to the line-number cell. In split mode the td carries
    // `.diff-line-old-num` / `.diff-line-new-num`; in unified mode
    // the single line-num td contains spans with `data-line-new-num`
    // or `data-line-old-num`. Anything else (code-content cell, +/−
    // marker, diff body) → null so native selection works.
    const numTd = target.closest(
      "td.diff-line-old-num, td.diff-line-new-num, td.diff-line-num",
    );
    if (!numTd) return null;

    // Unified mode: the inner span carries the side-specific attr.
    const unifiedSpan = numTd.querySelector("[data-line-new-num], [data-line-old-num]");
    if (unifiedSpan && numTd.classList.contains("diff-line-num")) {
      // We need the SPECIFIC span the user pointed at — unified rows
      // have BOTH old-num and new-num spans side-by-side. Walk up
      // from the actual target.
      const hitSpan = target.closest("[data-line-new-num], [data-line-old-num]");
      const span = hitSpan ?? unifiedSpan;
      const newAttr = span.getAttribute("data-line-new-num");
      if (newAttr) {
        const n = parseInt(newAttr, 10);
        if (n) return { line: n, side: "new" };
      }
      const oldAttr = span.getAttribute("data-line-old-num");
      if (oldAttr) {
        const n = parseInt(oldAttr, 10);
        if (n) return { line: n, side: "old" };
      }
    }

    // Split mode: side from the td class, line from inner span.
    let side: "old" | "new";
    if (numTd.classList.contains("diff-line-old-num")) side = "old";
    else if (numTd.classList.contains("diff-line-new-num")) side = "new";
    else return null;
    const span = numTd.querySelector("span[data-line-num]");
    const numAttr = span?.getAttribute("data-line-num");
    const line = numAttr ? parseInt(numAttr, 10) : 0;
    return line ? { line, side } : null;
  }

  // Visual indicator: mark every diff-line row covered by a
  // comment range. Also injects a custom `<tr class="meerkat-comment-row">`
  // right after the anchor row to host one InlineComment per comment.
  // Re-runs whenever the comments prop, the diff instance, the view
  // mode or line wrapping changes (the last two swap the diff table);
  // tolerates @git-diff-view's internal re-renders by re-applying.
  let mountedInlineComments: Array<{ component: ReturnType<typeof mount>; host: HTMLElement }> = [];
  let injectedCommentRows: HTMLTableRowElement[] = [];
  type MountedInlineForm = { component: ReturnType<typeof mount>; row: HTMLTableRowElement };
  let mountedInlineForms = new Map<string, MountedInlineForm>();

  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    void comments.length;
    void diffViewMode;
    void wrap_lines;
    return afterTwoFrames(() => {
      applyCommentMarkers();
      renderInlineComments();
    });
  });

  // Runs `fn` two animation frames from now, so @git-diff-view's
  // syntax / extend rendering settles before it walks the rows. Returns
  // a canceller, for an effect to return as its cleanup.
  function afterTwoFrames(fn: () => void): () => void {
    let second = 0;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(fn);
    });
    return () => {
      cancelAnimationFrame(first);
      cancelAnimationFrame(second);
    };
  }

  // Hunk-expand: re-render injected rows and re-place the moved-line
  // tint when @git-diff-view changes the diff body's row structure.
  // Strictly scoped to mutations on tbody whose added/removed nodes are
  // tr.diff-line — anything else (CodeMirror's DOM churn inside the
  // form, our own row injects, attribute / text changes from syntax
  // highlighting) is ignored.
  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    let scheduled = false;
    const obs = new MutationObserver((mutations) => {
      const hunkExpand = mutations.some((m) => {
        if (m.type !== "childList") return false;
        const target = m.target as Element;
        if (target.tagName !== "TBODY") return false;
        const isDiffLine = (n: Node) =>
          n instanceof Element &&
          n.tagName === "TR" &&
          n.classList.contains("diff-line") &&
          !n.classList.contains("meerkat-comment-row") &&
          !n.classList.contains("meerkat-form-row");
        return (
          Array.from(m.addedNodes).some(isDiffLine) ||
          Array.from(m.removedNodes).some(isDiffLine)
        );
      });
      if (!hunkExpand || scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        cancelMovedFlash();
        const rowsBySideLine = buildAnchorIndex();
        applyCommentMarkers(rowsBySideLine);
        renderInlineComments();
        renderInlineForms($state.snapshot(inline_forms) as InlineFormDescriptor[]);
        // The library reuses row elements for other lines, so the moved
        // tint and arrows must be placed again by line number.
        applyMovedHighlights(file.moved_lines ?? [], rowsBySideLine);
        drawRulers();
      });
    });
    obs.observe(diffContainer, { childList: true, subtree: true });
    return () => obs.disconnect();
  });

  // Rulers: each side's code cells get, as a CSS variable, a background
  // drawing the rulers whose column fits in the visible width of that
  // side's code column; the rest are not drawn. Redrawn when the
  // setting, the table (view mode, wrap, font size) or the width changes.
  const RULER_COLOR = "color-mix(in srgb, var(--muted) 35%, transparent)";
  const RULER_SIDES = [
    ["--meerkat-rulers-old", "td.diff-line-old-content"],
    ["--meerkat-rulers-new", "td.diff-line-new-content"],
    ["--meerkat-rulers-unified", "td.diff-line-content"],
  ] as const;

  function drawRulers() {
    if (!diffContainer) return;
    for (const [variable, selector] of RULER_SIDES) {
      const td = diffContainer.querySelector<HTMLTableCellElement>(selector);
      const view = td?.closest("table")?.parentElement;
      if (!td || !view || ruler_columns.length === 0) {
        diffContainer.style.removeProperty(variable);
        continue;
      }
      // With wrap off the cell is as wide as the longest line, so the
      // visible part ends at the edge of the side's scroll view.
      // Measured as if scrolled to the start, so the answer doesn't
      // change with the scroll.
      const cell = td.getBoundingClientRect();
      const viewRight = view.getBoundingClientRect().left + view.clientLeft + view.clientWidth;
      // Text stops at the cell's right padding, so a ruler there marks
      // a column no line reaches.
      const textRight = cell.width - Number.parseFloat(getComputedStyle(td).paddingRight);
      const visible = Math.min(textRight, viewRight - (cell.left + view.scrollLeft));
      // The code starts 2em into the cell, after the +/- marker.
      const { offset, ch } = fontWidths(td);
      const columns = fittingColumns(ruler_columns, visible, offset, ch);
      diffContainer.style.setProperty(variable, rulerBackground(columns, "2em", RULER_COLOR));
    }
  }

  // `2em` and `1ch` in `cell`'s font, in px. The `ch` probe forces a
  // layout of the diff table, slow on a long diff, so the widths are kept
  // per font.
  function fontWidths(cell: HTMLElement): { offset: number; ch: number } {
    const style = getComputedStyle(cell);
    const font = [style.fontStyle, style.fontWeight, style.fontSize, style.fontFamily, style.letterSpacing].join("|");
    let widths = fontWidthCache.get(font);
    if (!widths) {
      widths = { offset: 2 * Number.parseFloat(style.fontSize), ch: probeWidth(cell, "100ch") / 100 };
      fontWidthCache.set(font, widths);
    }
    return widths;
  }

  // The width, in px, of a CSS length in `cell`'s font.
  function probeWidth(cell: HTMLElement, length: string): number {
    const probe = document.createElement("span");
    probe.style.cssText = `position: absolute; visibility: hidden; width: ${length}`;
    cell.append(probe);
    const width = probe.getBoundingClientRect().width;
    probe.remove();
    return width;
  }

  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    void $state.snapshot(ruler_columns);
    void diffViewMode;
    void wrap_lines;
    void font_size_px;
    const cancel = afterTwoFrames(drawRulers);
    const resize = new ResizeObserver(() => drawRulers());
    resize.observe(diffContainer);
    return () => {
      cancel();
      resize.disconnect();
    };
  });

  // Inject one inline-comment FORM per open form on this file, each
  // at its own anchor row. LiveSvelte applies prop changes as in-place
  // JSON patches by list index, so the effect snapshots the whole list:
  // that reads every nested field, and a different form taking an
  // existing slot re-runs it just as a form opening or closing does.
  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    const descs = $state.snapshot(inline_forms) as InlineFormDescriptor[];
    // A split/unified or wrap toggle re-renders the table without our
    // rows.
    void diffViewMode;
    void wrap_lines;
    return afterTwoFrames(() => renderInlineForms(descs));
  });

  // Reconcile the mounted forms against `descs` by key: forms that
  // stay open keep their component (and its typed text), closed ones
  // unmount, new ones mount. Each form row sits after its anchor row,
  // below that line's comments and the forms listed before it.
  function renderInlineForms(descs: InlineFormDescriptor[]) {
    if (!diffContainer) return;
    removeMirrorRows();
    const wanted = new Set(descs.map((d) => d.key));
    for (const [key, m] of mountedInlineForms) {
      if (wanted.has(key)) continue;
      unmountInlineForm(m);
      mountedInlineForms.delete(key);
    }
    // Belt-and-braces: any orphan form row gets swept.
    const tracked = new Set(Array.from(mountedInlineForms.values(), (m) => m.row));
    diffContainer.querySelectorAll("tr.meerkat-form-row").forEach((tr) => {
      if (!tracked.has(tr as HTMLTableRowElement)) tr.parentNode?.removeChild(tr);
    });

    const placed = new Set<Element>();
    for (const desc of descs) {
      const side = desc.anchor.side === "old" ? "old" : "new";
      const rows = anchorRowsFor(side, desc.anchor.end_line);
      if (rows.length === 0) {
        expandToShowHiddenAnchor();
        continue;
      }
      const anchor = rows[rows.length - 1];
      let after: Element = anchor;
      while (
        after.nextElementSibling &&
        (after.nextElementSibling.classList.contains("meerkat-comment-row") ||
          placed.has(after.nextElementSibling))
      ) {
        after = after.nextElementSibling;
      }

      const buildRow = () => {
        const tr = buildSideAwareRow(anchor, side, "meerkat-form-row", "meerkat-form-cell");
        tr.setAttribute("data-meerkat-form-anchor", String(desc.anchor.end_line));
        tr.setAttribute("data-meerkat-form-side", side);
        // The footer's open-form links scroll to the form by key.
        tr.setAttribute("data-meerkat-form-key", desc.key);
        after.parentNode?.insertBefore(tr, after.nextSibling);
        return tr;
      };
      const formCell = (tr: HTMLTableRowElement) =>
        tr.querySelector("td.meerkat-form-cell") as HTMLTableCellElement;

      let m = mountedInlineForms.get(desc.key);
      if (!m) {
        const tr = buildRow();
        const component = mount(CommentForm, {
          target: formCell(tr),
          // A getter, so the open form follows ruler setting changes.
          props: {
            ...desc.props,
            // Only Clojure's indentation reads the text above.
            textAbove:
              fileLanguage === "clojure"
                ? textAbove(
                    (side === "old" ? file.old_content : file.new_content) ?? "",
                    desc.anchor.start_line,
                  )
                : undefined,
            live,
            get rulerColumns() {
              return ruler_columns;
            },
          },
        });
        m = { component, row: tr };
        mountedInlineForms.set(desc.key, m);
      } else if (m.row.parentNode !== anchor.parentNode) {
        // The diff table was replaced (split/unified or wrap toggle),
        // so the row's columns may no longer fit. Rebuild it
        // for the new table and carry the mounted form across intact.
        const tr = buildRow();
        formCell(tr).append(...formCell(m.row).childNodes);
        m.row.remove();
        m.row = tr;
      } else if (after.nextSibling !== m.row) {
        after.parentNode?.insertBefore(m.row, after.nextSibling);
      }
      placed.add(m.row);
    }
    mirrorInjectedRows();
  }

  // With Wrap off, Split view draws each side in its own table, so a row
  // injected into one side's table would push only that side's lines
  // down. Give each injected row a blank mirror row in the other side's
  // table, as tall as the row, so the sides stay in line as they do with
  // Wrap on, where the row's other half is a spacer cell. At a line with
  // rows on both sides, the old side's rows come first.
  let mirrorHeights: ResizeObserver | null = null;

  function removeMirrorRows() {
    mirrorHeights?.disconnect();
    mirrorHeights = null;
    diffContainer?.querySelectorAll("tr.meerkat-mirror-row").forEach((tr) => {
      tr.remove();
    });
  }

  function mirrorInjectedRows() {
    removeMirrorRows();
    const oldBody = diffContainer?.querySelector("table.old-diff-table > tbody");
    const newBody = diffContainer?.querySelector("table.new-diff-table > tbody");
    if (!oldBody || !newBody) return;
    const mirrors = new Map<Element, HTMLTableRowElement>();
    // Old side first: its mirrors go straight after the new side's
    // anchor; the new side's mirrors go after everything at the old
    // side's anchor.
    for (const [body, other] of [
      [oldBody, newBody],
      [newBody, oldBody],
    ] as const) {
      const rows = body.querySelectorAll(":scope > tr.meerkat-comment-row, :scope > tr.meerkat-form-row");
      for (const row of rows) {
        let anchor = row.previousElementSibling;
        while (anchor && isInjectedRow(anchor)) anchor = anchor.previousElementSibling;
        const line = anchor?.getAttribute("data-line");
        // The two tables give the same split line the same `data-line`.
        let after = line ? other.querySelector(`:scope > tr[data-line="${line}"]`) : null;
        if (!after) continue;
        const skip = body === oldBody ? isMirrorRow : isInjectedRow;
        while (after.nextElementSibling && skip(after.nextElementSibling)) after = after.nextElementSibling;
        const mirror = document.createElement("tr");
        mirror.className = "meerkat-mirror-row";
        const cell = document.createElement("td");
        cell.setAttribute("colspan", "2");
        cell.className = "meerkat-mirror-cell";
        mirror.appendChild(cell);
        after.after(mirror);
        mirrors.set(row, mirror);
      }
    }
    if (mirrors.size === 0) return;
    // The observer reports each row's size when it starts watching and on
    // every change, so the mirrors take their heights without forcing a
    // layout of the diff table.
    mirrorHeights = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const mirror = mirrors.get(entry.target);
        if (mirror) mirror.style.height = `${entry.borderBoxSize[0].blockSize}px`;
      }
    });
    for (const row of mirrors.keys()) mirrorHeights.observe(row);
  }

  function isMirrorRow(el: Element): boolean {
    return el.classList.contains("meerkat-mirror-row");
  }

  // A comment, form or mirror row: anything we put in the diff table.
  function isInjectedRow(el: Element): boolean {
    return (
      isMirrorRow(el) ||
      el.classList.contains("meerkat-comment-row") ||
      el.classList.contains("meerkat-form-row")
    );
  }

  // A form or comment can be anchored on a context line the reviewer
  // expanded, which renders collapsed again after a reload or a view
  // toggle. It must stay visible (an open form blocks the decision
  // buttons), so expand the whole file once per diff instance and view
  // mode; the hunk-expand observer then places it.
  const expandedForHiddenAnchor = new WeakMap<DiffFile, Set<string>>();
  function expandToShowHiddenAnchor() {
    if (!diffInstance) return;
    const expandMode = diffViewMode === DiffModeEnum.Unified ? "unified" : "split";
    const done = expandedForHiddenAnchor.get(diffInstance) ?? new Set<string>();
    if (done.has(expandMode)) return;
    done.add(expandMode);
    expandedForHiddenAnchor.set(diffInstance, done);
    diffInstance.onAllExpand(expandMode);
  }

  function unmountInlineForm(m: MountedInlineForm) {
    try {
      unmount(m.component);
    } catch {
      /* already gone */
    }
    m.row.parentNode?.removeChild(m.row);
  }

  // Takes a `"side:line" -> rows` map rather than calling
  // `anchorRowsFor(side, n)` per line per comment, each firing two
  // querySelectorAll: a 50-line comment range would make 100 queries.
  function applyCommentMarkers(rowsBySideLine = buildAnchorIndex()) {
    if (!diffContainer) return;
    diffContainer.querySelectorAll("tr.diff-line.has-inline-comment").forEach((row) => {
      row.classList.remove("has-inline-comment");
    });
    for (const c of comments) {
      const wantSide = c.side === "old" ? "old" : "new";
      for (let n = c.start_line; n <= c.end_line; n++) {
        const rows = rowsBySideLine.get(`${wantSide}:${n}`);
        rows?.forEach((row) => {
          row.classList.add("has-inline-comment");
        });
      }
    }
  }

  // Maps every line-number anchor under diffContainer to its
  // `tr.diff-line`s, as `"old:N" | "new:N" -> rows[]`; our injected
  // comment and form rows are not `tr.diff-line`. Queries the
  // container once per anchor kind: a per-row query with a descendant
  // combinator cost Chromium ~1s on a 3000-row diff.
  function buildAnchorIndex(): Map<string, HTMLTableRowElement[]> {
    const index = new Map<string, HTMLTableRowElement[]>();
    if (!diffContainer) return index;
    const container = diffContainer;
    const add = (side: "old" | "new", selector: string, attr: string) => {
      container.querySelectorAll<HTMLElement>(selector).forEach((el) => {
        const row = el.closest<HTMLTableRowElement>("tr.diff-line");
        if (row) push(index, side, el.getAttribute(attr), row);
      });
    };
    // A unified row carries both sides; in split mode each <td> has
    // one side, in a generic `td.diff-line-{side}-num span[data-line-num]`.
    add("new", "[data-line-new-num]", "data-line-new-num");
    add("old", "[data-line-old-num]", "data-line-old-num");
    add("new", "td.diff-line-new-num span[data-line-num]", "data-line-num");
    add("old", "td.diff-line-old-num span[data-line-num]", "data-line-num");
    return index;
  }

  function push(
    index: Map<string, HTMLTableRowElement[]>,
    side: "old" | "new",
    line: string | null,
    row: HTMLTableRowElement,
  ): void {
    if (!line) return;
    const key = `${side}:${line}`;
    const existing = index.get(key);
    if (existing) {
      if (!existing.includes(row)) existing.push(row);
    } else {
      index.set(key, [row]);
    }
  }

  // Resolve every tr.diff-line that anchors line `n` on `side`,
  // skipping our own injected comment rows so we never re-anchor a
  // comment to a comment.
  function anchorRowsFor(side: "old" | "new", n: number): HTMLTableRowElement[] {
    if (!diffContainer) return [];
    const rows: HTMLTableRowElement[] = [];
    const sel =
      side === "new" ? `[data-line-new-num="${n}"]` : `[data-line-old-num="${n}"]`;
    diffContainer.querySelectorAll(sel).forEach((el) => {
      const row = (el as HTMLElement).closest("tr.diff-line") as HTMLTableRowElement | null;
      if (row && !row.classList.contains("meerkat-comment-row")) rows.push(row);
    });
    // Split mode: line-num spans use the generic data-line-num attr;
    // disambiguate by the enclosing td's class.
    diffContainer
      .querySelectorAll(`td.diff-line-${side}-num span[data-line-num="${n}"]`)
      .forEach((el) => {
        const row = (el as HTMLElement).closest("tr.diff-line") as HTMLTableRowElement | null;
        if (row && !row.classList.contains("meerkat-comment-row") && !rows.includes(row))
          rows.push(row);
      });
    return rows;
  }

  // Tear down old mounts + inject one `<tr.meerkat-comment-row>` per
  // (side, line) group, after the last anchor row for that line. Each
  // row hosts InlineComment instances inside a `<td colspan>` so the
  // host row keeps the diff table's column structure.
  function renderInlineComments() {
    if (!diffContainer) return;
    removeMirrorRows();
    // Tear down previously mounted components AND their host rows.
    // Belt-and-braces also queries the live DOM for any orphan rows
    // we've stamped — `mountedInlineComments` only tracks li hosts,
    // not the parent tr, and stale comment rows can survive a
    // @git-diff-view internal re-render that drops our refs.
    for (const m of mountedInlineComments) {
      try {
        unmount(m.component);
      } catch {
        /* component already unmounted */
      }
    }
    mountedInlineComments = [];
    for (const tr of injectedCommentRows) {
      tr.parentNode?.removeChild(tr);
    }
    injectedCommentRows = [];
    // Final sweep: any stamped row not in our list (e.g. cloned by
    // @git-diff-view's virtualisation) goes too. They carry a stable
    // attribute we set on creation.
    diffContainer.querySelectorAll("tr.meerkat-comment-row").forEach((tr) => {
      tr.parentNode?.removeChild(tr);
    });

    for (const group of commentGroups()) {
      const rows = anchorRowsFor(group.side, group.line);
      if (rows.length === 0) {
        expandToShowHiddenAnchor();
        continue;
      }
      const anchor = rows[rows.length - 1];

      const tr = buildSideAwareRow(anchor, group.side, "meerkat-comment-row", "meerkat-comment-cell");
      tr.setAttribute("data-meerkat-anchor-line", String(group.line));
      tr.setAttribute("data-meerkat-anchor-side", group.side);
      const contentTd = tr.querySelector("td.meerkat-comment-cell") as HTMLTableCellElement;
      const list = document.createElement("ul");
      list.className = "extend-comments";
      contentTd.appendChild(list);
      anchor.parentNode?.insertBefore(tr, anchor.nextSibling);
      injectedCommentRows.push(tr);

      for (const comment of group.comments) {
        const liHost = document.createElement("li");
        liHost.className = "inline-comment-host";
        list.appendChild(liHost);
        const cmp = mount(InlineComment, {
          target: liHost,
          props: { comment, live },
        });
        mountedInlineComments.push({ component: cmp, host: liHost });
      }
    }
    mirrorInjectedRows();
  }

  // Build a <tr> that mirrors the anchor row's column structure but
  // hosts our injected content on the correct side.
  //
  // Split mode (4 cells: old-num | old-content | new-num | new-content):
  //   - new-side comment → empty spacer covering old half + content
  //     cell covering new half.
  //   - old-side comment → content cell on old half + empty spacer
  //     on new half.
  //
  // Unified mode (2 cells: line-num | content): single content cell
  // colspan=2.
  function buildSideAwareRow(
    anchor: HTMLTableRowElement,
    side: "old" | "new",
    rowClass: string,
    cellClass: string,
  ): HTMLTableRowElement {
    const tr = document.createElement("tr");
    tr.className = rowClass;
    // Total column span — not just children.length, because @git-diff-view
    // collapses one side of an added/deleted line into a single placeholder
    // td with colspan=2 (so a row with `+` on the new side has 3 children
    // but 4 columns total).
    const cellCount = Array.from(anchor.children).reduce((sum, c) => {
      const cs = parseInt(c.getAttribute("colspan") || "1", 10);
      return sum + (Number.isFinite(cs) && cs > 0 ? cs : 1);
    }, 0) || 2;

    if (cellCount >= 4) {
      // Split mode: two halves.
      const oldSpacer = document.createElement("td");
      oldSpacer.setAttribute("colspan", "2");
      oldSpacer.className = `${cellClass}-spacer`;
      const newSpacer = document.createElement("td");
      newSpacer.setAttribute("colspan", "2");
      newSpacer.className = `${cellClass}-spacer`;
      const content = document.createElement("td");
      content.setAttribute("colspan", "2");
      content.className = cellClass;
      if (side === "new") {
        tr.appendChild(oldSpacer);
        tr.appendChild(content);
      } else {
        tr.appendChild(content);
        tr.appendChild(newSpacer);
      }
    } else {
      // Unified mode: single column.
      const content = document.createElement("td");
      content.setAttribute("colspan", String(cellCount));
      content.className = cellClass;
      tr.appendChild(content);
    }
    return tr;
  }

  function handlePointerDown(e: PointerEvent) {
    if (e.button !== 0) return;
    const hit = extractLineTarget(e.target as HTMLElement);
    if (!hit) return;
    dragStart = hit;
    dragCurrent = hit;
    try {
      (e.currentTarget as HTMLElement)?.setPointerCapture?.(e.pointerId);
    } catch {
      /* older browsers — capture is best-effort */
    }
    e.preventDefault();
  }

  function handlePointerMove(e: PointerEvent) {
    if (clj_hover) restartHoverTimer(e.clientX, e.clientY);
    if (!dragStart) return;
    const el = document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null;
    if (!el) return;
    const hit = extractLineTarget(el);
    if (!hit || hit.side !== dragStart.side) return;
    dragCurrent = hit;
  }

  function finishDrag() {
    if (!dragStart || !dragCurrent) {
      dragStart = null;
      dragCurrent = null;
      return;
    }
    const start = Math.min(dragStart.line, dragCurrent.line);
    const end = Math.max(dragStart.line, dragCurrent.line);
    const side = dragStart.side;
    dragStart = null;
    dragCurrent = null;
    live.pushEvent("comment_form.show_at_line", {
      file_index,
      start_line: start,
      end_line: end,
      side,
    });
  }

  function handlePointerUp(_e: PointerEvent) {
    finishDrag();
  }

  function handlePointerCancel(_e: PointerEvent) {
    dragStart = null;
    dragCurrent = null;
  }

  // Re-apply drag-select classes whenever drag state changes. First remove
  // `.drag-selecting` and `.drag-selecting-side` everywhere, then add
  // `.drag-selecting` to each line-number cell in the drag range on the
  // dragged side. In unified view (one `td.diff-line-num` with both numbers),
  // also mark the whole row; in split view, mark that side's number cell and
  // adjacent content cell with `.drag-selecting-side`. All highlights clear
  // when `dragStart` returns to `null`.
  $effect(() => {
    if (!diffContainer) return;
    for (const el of diffContainer.querySelectorAll(".drag-selecting, .drag-selecting-side")) {
      el.classList.remove("drag-selecting", "drag-selecting-side");
    }
    if (!dragStart || !dragCurrent) return;

    const lo = Math.min(dragStart.line, dragCurrent.line);
    const hi = Math.max(dragStart.line, dragCurrent.line);
    const side = dragStart.side;
    const numSel =
      side === "old"
        ? "td.diff-line-old-num, td.diff-line-num [data-line-old-num]"
        : "td.diff-line-new-num, td.diff-line-num [data-line-new-num]";
    const numAttr = side === "old" ? "data-line-old-num" : "data-line-new-num";

    for (const hit of diffContainer.querySelectorAll(numSel)) {
      const ln = readLineNum(hit as HTMLElement, numAttr);
      if (ln == null || ln < lo || ln > hi) continue;
      // The unified-mode selector matches a descendant span inside
      // the line-num td; we want the highlight on the td itself so
      // the CSS background/colour rules fire on the entire gutter
      // cell, not just the inner number text.
      const td = (hit as HTMLElement).closest("td");
      if (!td) continue;
      td.classList.add("drag-selecting");
      // In unified view, a row represents one line, so shade the whole row.
      // In split view, line wrap puts both sides in one row (old number and
      // content, then new number and content), so shading the row would also
      // shade the other side. With wrapping off, each side has its own table.
      // Shade only this side's number cell and the content cell after it.
      if (td.classList.contains("diff-line-num")) {
        td.closest("tr.diff-line")?.classList.add("drag-selecting");
      } else {
        td.classList.add("drag-selecting-side");
        td.nextElementSibling?.classList.add("drag-selecting-side");
      }
    }
  });

  // --- Clojure hover (docs/features/clojure-hover.md) ---
  //
  // A pointer resting on a code character asks the server what var it
  // names; the answer to the latest request opens the popup there.
  // Resting where no var answers, or leaving both the diff and the
  // popup, closes it.

  const HOVER_CLOSE_MS = 300;
  let hoverTimer = 0;
  let hoverCloseTimer = 0;
  // `row` names the side and line hovered.
  let hoverRequest: { id: number; anchor: HoverAnchor; row: string } | null = null;
  let shownHover = $state<{ hover: CljHover; anchor: HoverAnchor; row: string } | null>(null);

  function restartHoverTimer(x: number, y: number) {
    clearTimeout(hoverTimer);
    clearTimeout(hoverCloseTimer);
    hoverTimer = window.setTimeout(() => requestHover(x, y), HOVER_DELAY_MS);
  }

  function requestHover(x: number, y: number) {
    const spot = dragStart ? null : spotAt(x, y);
    if (!spot) {
      hoverRequest = null;
      shownHover = null;
      return;
    }
    lastHoverId += 1;
    hoverRequest = {
      id: lastHoverId,
      anchor: { rect: spot.rect, scrollX: window.scrollX, scrollY: window.scrollY },
      row: `${spot.side}:${spot.line}`,
    };
    live.pushEvent("clj.hover", {
      id: lastHoverId,
      file_index,
      side: spot.side,
      line: spot.line,
      col: spot.col,
    });
  }

  function closeHoverSoon() {
    clearTimeout(hoverTimer);
    clearTimeout(hoverCloseTimer);
    hoverCloseTimer = window.setTimeout(() => {
      hoverRequest = null;
      shownHover = null;
    }, HOVER_CLOSE_MS);
  }

  function keepHoverOpen() {
    clearTimeout(hoverTimer);
    clearTimeout(hoverCloseTimer);
  }

  $effect(() => {
    if (!clj_hover) return;
    const onAnswer = (e: Event) => {
      const { id, hover } = (e as CustomEvent<{ id: number; hover: CljHover | null }>).detail;
      if (id !== hoverRequest?.id) return;
      const { anchor, row } = hoverRequest;
      if (keepsPopup(shownHover, row, hover)) return;
      // The page may have scrolled while the answer was on its way; the
      // popup picks its side by where the symbol is now.
      shownHover = hover ? { hover, anchor: rescrolled(anchor, window.scrollX, window.scrollY), row } : null;
    };
    window.addEventListener("phx:clj:hover", onAnswer);
    return () => {
      window.removeEventListener("phx:clj:hover", onAnswer);
      clearTimeout(hoverTimer);
      clearTimeout(hoverCloseTimer);
    };
  });

  function readLineNum(el: HTMLElement, attr: string): number | null {
    // Split mode: the line-num td itself carries the visible number
    // as its text content. Unified mode: a child span carries it as
    // a data-attr.
    const inner = el.matches(`[${attr}]`) ? el : el.querySelector(`[${attr}]`);
    const v = inner ? (inner as HTMLElement).getAttribute(attr) : el.textContent;
    const n = Number((v ?? "").trim());
    return Number.isFinite(n) ? n : null;
  }

  // Moved-line highlighting + jump arrows. Each block of moved lines
  // gets a coloured background (4 colors cycled by pairId) on the
  // covered rows, and an arrow in place of each line's +/− mark: → on
  // the new side, ← on the old. Each arrow is a button titled with
  // where the code moved. A click dispatches a document-level
  // `meerkat-move-jump` event the DiffViewers listen for, so the target
  // lines scroll into view and flash. When no viewer has them on the
  // page, it asks the server to show the counterpart's file, and app.js
  // dispatches the event again once that file renders.
  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    const blocks = file.moved_lines ?? [];
    // A split/unified toggle, or a wrap toggle in split view, replaces
    // the rows, dropping the moved tint and arrows.
    void diffViewMode;
    void wrap_lines;
    return afterTwoFrames(() => applyMovedHighlights(blocks));
  });

  function clearMovedHighlights() {
    if (!diffContainer) return;
    diffContainer.querySelectorAll(".moved-line").forEach((el) => {
      el.classList.remove("moved-line", "moved-pair-0", "moved-pair-1", "moved-pair-2", "moved-pair-3");
    });
    diffContainer.querySelectorAll(".moved-arrow").forEach((el) => {
      el.remove();
    });
    diffContainer.querySelectorAll(".moved-mark").forEach((el) => {
      el.classList.remove("moved-mark");
    });
  }

  function applyMovedHighlights(blocks: MovedBlock[], index?: Map<string, HTMLTableRowElement[]>) {
    if (!diffContainer) return;
    clearMovedHighlights();
    if (blocks.length === 0) return;
    const rowsBySideLine = index ?? buildAnchorIndex();

    for (const block of blocks) {
      const pairClass = `moved-pair-${block.pair_id % 4}`;
      const side = block.side === "old" ? "old" : "new";
      for (let ln = block.line_start; ln <= block.line_end; ln++) {
        rowsBySideLine.get(`${side}:${ln}`)?.forEach((row) => {
          row.classList.add("moved-line", pairClass);
          const td = row.querySelector(`td.diff-line-${side}-content, td.diff-line-content`);
          if (!td) return;
          td.classList.add("moved-line", pairClass);
          // The arrow covers the library's +/− mark rather than
          // replacing it: @git-diff-view reuses the row for other lines.
          const mark = td.querySelector(".diff-line-content-operator");
          if (!mark) return;
          mark.classList.add("moved-mark");
          mark.append(movedArrow(block, pairClass));
        });
      }
    }
  }

  function movedArrow(block: MovedBlock, pairClass: string): HTMLButtonElement {
    const arrow = document.createElement("button");
    arrow.type = "button";
    arrow.className = `moved-arrow ${pairClass}`;
    arrow.textContent = block.side === "old" ? "←" : "→";
    const lines =
      block.to_line_start === block.to_line_end
        ? `line ${block.to_line_start}`
        : `lines ${block.to_line_start}-${block.to_line_end}`;
    arrow.title = `Moved ${block.side === "old" ? "to" : "from"} ${block.to_file} ${lines}`;
    arrow.setAttribute("aria-label", arrow.title);
    arrow.addEventListener("click", (e) => {
      e.stopPropagation();
      const detail = {
        fileName: block.to_file,
        side: block.to_side,
        lineStart: block.to_line_start,
        lineEnd: block.to_line_end,
      };
      // A counterpart already on the page takes the jump at once.
      if (!document.dispatchEvent(new CustomEvent("meerkat-move-jump", { detail, cancelable: true }))) return;
      live.pushEvent("moved.jump", {
        file_name: block.to_file,
        side: block.to_side,
        line_start: block.to_line_start,
        line_end: block.to_line_end,
      });
    });
    return arrow;
  }

  // Held for 60% of the flash, then eased out.
  const MOVED_FLASH_SHADOW = "inset 0 0 0 100vmax rgba(88, 166, 255, 0.35)";
  const MOVED_FLASH_KEYFRAMES: Keyframe[] = [
    { boxShadow: MOVED_FLASH_SHADOW, offset: 0 },
    { boxShadow: MOVED_FLASH_SHADOW, offset: 0.6, easing: "ease-out" },
  ];
  // The running flash. A hunk expand reuses its cells for other lines,
  // so the expand cancels it.
  let movedFlash: Animation[] = [];

  function cancelMovedFlash() {
    movedFlash.forEach((a) => {
      a.cancel();
    });
    movedFlash = [];
  }

  // Listen for jump events to a moved block's counterpart. If the
  // event's fileName matches THIS file and its lines are rendered,
  // scroll them into view, flash a temporary highlight so the reviewer
  // can spot them, and cancel the event to tell its sender it landed.
  $effect(() => {
    if (!diffContainer) return;
    const handler = (e: Event) => {
      const ev = e as CustomEvent<{ fileName: string; side: "old" | "new"; lineStart: number; lineEnd: number }>;
      if (!ev.detail || ev.detail.fileName !== file.file_name) return;
      // live_svelte unmounts a removed viewer only at the next
      // `phx:page-loading-stop`, so a collapsed file's old viewer still
      // listens, over rows no longer on the page.
      if (!diffContainer?.isConnected) return;
      const rows = anchorRowsFor(ev.detail.side, ev.detail.lineStart);
      if (rows.length === 0) return;
      ev.preventDefault();
      const row = rows[0];
      row.scrollIntoView({ block: "center", behavior: "smooth" });
      // Flash the target side's cells for 1.6s, as an inset shadow over
      // their opaque backgrounds, which hide the row's own. A click
      // during a flash starts it again.
      const side = ev.detail.side;
      cancelMovedFlash();
      for (let ln = ev.detail.lineStart; ln <= ev.detail.lineEnd; ln++) {
        anchorRowsFor(side, ln).forEach((r) => {
          r.querySelectorAll(
            `td.diff-line-${side}-num, td.diff-line-${side}-content, td.diff-line-num, td.diff-line-content`,
          ).forEach((td) => {
            movedFlash.push(td.animate(MOVED_FLASH_KEYFRAMES, 1600));
          });
        });
      }
    };
    document.addEventListener("meerkat-move-jump", handler);
    return () => document.removeEventListener("meerkat-move-jump", handler);
  });

  // Clean up any DOM-injected InlineComponent mounts when the
  // DiffViewer itself is torn down (file filter / nav).
  $effect(() => {
    return () => {
      for (const m of mountedInlineComments) {
        try {
          unmount(m.component);
        } catch {
          /* already gone */
        }
      }
      mountedInlineComments = [];
      for (const tr of injectedCommentRows) tr.parentNode?.removeChild(tr);
      injectedCommentRows = [];
      for (const m of mountedInlineForms.values()) unmountInlineForm(m);
      mountedInlineForms.clear();
      removeMirrorRows();
    };
  });
</script>


{#if (file.read_errors?.length ?? 0) > 0}
  <div class="read-errors" role="alert" data-test="read-errors">
    <strong>Could not fully read this file's diff:</strong>
    <ul>
      {#each file.read_errors ?? [] as err}
        <li>{err}</li>
      {/each}
    </ul>
    The diff body below may be incomplete or misleading — do not approve until resolved.
  </div>
{/if}

{#if renderError}
  <div class="render-error" role="alert" data-test="render-error">
    <strong>Failed to render diff for {file.file_name}:</strong> {renderError}
  </div>
{/if}

{#if file.is_binary}
  <div class="binary-notice" role="note" data-test="binary-notice">
    <strong>Binary file — content not displayed.</strong>
    Git treats this file as binary (by content or attributes). Review its contents outside Meerkat before approving.
  </div>
{:else if diffInstance}
  <div
    class="diff-content"
    class:no-wrap={!wrap_lines}
    role="presentation"
    bind:this={diffContainer}
    onpointerdown={handlePointerDown}
    onpointermove={handlePointerMove}
    onpointerup={handlePointerUp}
    onpointercancel={handlePointerCancel}
    onpointerleave={clj_hover ? closeHoverSoon : undefined}
    style:tab-size={tab_size}
    style:--tab-size={tab_size}
  >
    <DiffView
      diffFile={diffInstance}
      {diffViewMode}
      diffViewWrap={wrap_lines}
      diffViewHighlight={true}
      diffViewFontSize={font_size_px}
      diffViewTheme={DIFF_THEME}
      diffViewAddWidget={false}
      registerHighlighter={highlighter ?? undefined}
    />
  </div>
  {#if shownHover}
    {#key shownHover}
      <CljHoverPopup
        hover={shownHover.hover}
        anchor={shownHover.anchor}
        {highlighter}
        theme={DIFF_THEME}
        {font_size_px}
        onpointerenter={keepHoverOpen}
        onpointerleave={closeHoverSoon}
      />
    {/key}
  {/if}
{/if}

{#if !file.is_binary && isPlantUml}
  <PlantUmlPreview
    oldSource={file.old_content ?? ""}
    newSource={file.new_content ?? ""}
    status={(file.status ?? "modified") as "added" | "modified" | "deleted" | "renamed"}
    available={plantuml_available}
  />
{/if}

<style>
  .binary-notice {
    padding: 16px;
    border: 1px solid #30363d;
    border-radius: 0 0 6px 6px;
    background: #161b22;
  }

  .diff-content {
    border: 1px solid #30363d;
    border-radius: 0 0 6px 6px;
    background: #0d1117;
    /* horizontal scroll for long unwrapped lines; vertical scroll
       handled by the page body */
    overflow-x: auto;
  }
  /* Rulers, set per side by `drawRulers`. */
  :global(.diff-content td.diff-line-old-content) {
    background-image: var(--meerkat-rulers-old, none);
  }
  :global(.diff-content td.diff-line-new-content) {
    background-image: var(--meerkat-rulers-new, none);
  }
  :global(.diff-content td.diff-line-content) {
    background-image: var(--meerkat-rulers-unified, none);
  }
  /* Line-number gutter cells: drag-select-only zone. Disabling user
     selection here prevents the drag from looking like a text
     highlight while still leaving the code content fully selectable
     for copy/paste. */
  :global(.diff-content td.diff-line-old-num),
  :global(.diff-content td.diff-line-new-num),
  :global(.diff-content td.diff-line-num) {
    user-select: none;
    cursor: pointer;
  }
  /* The library pads Unified's gutter only 5px on the left, which puts
     the inline-comment bar (below) against the numbers. Pad it 10px, as
     Split is, and widen the column by the extra 5px: the <col> sets it
     for Wrap's fixed table layout, the padding for the auto one. */
  :global(.diff-content td.diff-line-num) {
    padding-left: 10px;
  }
  :global(.diff-content col.unified-diff-table-num-col) {
    width: calc(var(--diff-aside-width--) * 2 + 13px);
  }
  /* The library draws each hunk row's expand buttons and header text on
     both sides. Hide the old-side (left) copies so both appear once, on
     the new side.
     With line wrap off, split view draws each side in its own table;
     hunk rows carry data-side="old" or data-side="new". */
  :global(.diff-content tr.diff-line-hunk[data-side="old"] > td > *),
  /* With line wrap on, each hunk is one row of four cells: old action,
     old header, new action, new header. The old-side cells are the ones
     with an action cell after them. */
  :global(.diff-content tr.diff-line-hunk > td:has(~ td.diff-line-hunk-action) > *) {
    /* Hiding the contents instead of removing them keeps the
       old-side cells as spacers that hold their width. */
    visibility: hidden;
  }
  /* The library gives the old-side action cell an inline background of
     var(--diff-hunk-lineNumber--), the button tile colour. With its button
     hidden, it would look like a blank tile, so point that variable at the
     hunk content colour on this cell to blend it into the emptied header
     cell beside it. */
  :global(.diff-content tr.diff-line-hunk[data-side="old"] > td.diff-line-hunk-action),
  :global(.diff-content td.diff-line-hunk-action:has(~ td.diff-line-hunk-action)) {
    --diff-hunk-lineNumber--: var(--diff-hunk-content--);
  }
  /*
   * Drag-select highlights line-number cells in the range, plus the whole row
   * in unified view or only the selected side's number and content cells
   * (`.drag-selecting-side`) in split view. It shows the range the reviewer
   * is about to anchor a comment on and is cleared on pointerup or
   * pointercancel by the `$effect` when `dragStart` returns to `null`.
   */
  :global(.diff-content td.diff-line-old-num.drag-selecting),
  :global(.diff-content td.diff-line-new-num.drag-selecting),
  :global(.diff-content td.diff-line-num.drag-selecting) {
    /* biome-ignore lint/complexity/noImportantStyles: the diff library sets the line number's color inline, which only `!important` can override. */
    color: #ffffff !important;
  }
  :global(.diff-content tr.diff-line.drag-selecting > td),
  :global(.diff-content tr.diff-line > td.drag-selecting-side) {
    /* biome-ignore lint/complexity/noImportantStyles: the diff library sets each cell's background-color inline, which only `!important` can override; without it the add/del shading masks the drag indicator. */
    background-color: rgba(31, 111, 235, 0.32) !important;
    /* A moved line's tint gives way, as the rulers don't. */
    --meerkat-moved-tint: transparent;
    box-shadow: inset 0 0 0 9999px rgba(31, 111, 235, 0.18);
  }
  /* Visual indicator that a line is covered by an inline comment.
     Coloured left bar inside the line-num cell — high enough
     contrast to be obvious without being garish. */
  :global(.diff-content tr.diff-line.has-inline-comment td:first-child) {
    box-shadow: inset 3px 0 0 #1f6feb;
  }
  :global(.diff-content tr.diff-line.has-inline-comment) {
    background: rgba(31, 111, 235, 0.06);
  }
  /* DOM-injected comment row hosting one or more InlineComment
     instances. Stretches the full table width via the colspan'd
     <td> (with Wrap off the list inside is sized to the view, below);
     no per-line gutter so the comment body reads cleanly. */
  :global(.diff-content tr.meerkat-comment-row > td.meerkat-comment-cell) {
    padding: 0;
    background: #161b22;
    border-top: 1px solid #30363d;
    border-bottom: 1px solid #30363d;
  }
  :global(.diff-content tr.meerkat-comment-row .extend-comments) {
    list-style: none;
    padding: 0;
    margin: 0;
  }
  :global(.diff-content tr.meerkat-comment-row li.inline-comment-host) {
    list-style: none;
  }
  /* Inline comment form injected at the clicked / dragged anchor.
     The form's own padding handles inner spacing. */
  :global(.diff-content tr.meerkat-form-row > td.meerkat-form-cell) {
    padding: 0;
    background: #161b22;
    border-top: 1px solid #30363d;
    border-bottom: 1px solid #30363d;
    user-select: text;
  }
  /* With wrap off, a long line makes the table wider than its scroll
     view, and the injected cell spans the whole table. Size the form
     or comment list to the view (`cqi`) and pin it to the view's left
     edge, so it and its buttons stay in view at any scroll. Since it
     no longer scrolls with the code, long words in a comment's text
     and the form's checkboxes wrap. */
  .diff-content.no-wrap :global(.diff-table-scroll-container) {
    container-type: inline-size;
  }
  .diff-content.no-wrap :global(td.meerkat-form-cell > .comment-form),
  .diff-content.no-wrap :global(td.meerkat-comment-cell > .extend-comments) {
    position: sticky;
    left: 0;
    width: 100cqi;
  }
  .diff-content.no-wrap :global(td.meerkat-comment-cell .comment-body) {
    overflow-wrap: anywhere;
  }
  .diff-content.no-wrap :global(td.meerkat-form-cell > .comment-form .flags) {
    flex-wrap: wrap;
  }
  /* Spacer halves on the opposite side from a side-aware comment /
     form row, and the mirror rows standing in for them with Wrap off.
     Subtle border so the spatial relationship to the
     anchor row reads correctly. */
  :global(.diff-content tr.meerkat-comment-row > td.meerkat-comment-cell-spacer),
  :global(.diff-content tr.meerkat-form-row > td.meerkat-form-cell-spacer),
  :global(.diff-content tr.meerkat-mirror-row > td.meerkat-mirror-cell) {
    background: rgba(13, 17, 23, 0.6);
    border-top: 1px solid #30363d;
    border-bottom: 1px solid #30363d;
  }
  .extend-comments {
    list-style: none;
    padding: 0;
    margin: 0;
    background: #161b22;
    border-top: 1px solid #30363d;
    border-bottom: 1px solid #30363d;
  }
  .read-errors,
  .render-error {
    border: 1px solid #f85149;
    border-radius: 6px 6px 0 0;
    background: #2d0608;
    color: #ffa198;
    padding: 8px 12px;
    margin: 0;
    font-size: 12px;
  }
  .read-errors ul {
    margin: 4px 0;
    padding-left: 20px;
  }
  /* Moved-line highlighting — 4 colors cycled by pair id. Each content
     cell draws its rulers over the tint. */
  :global(.diff-content .moved-line.moved-pair-0) {
    --meerkat-moved-tint: rgba(96, 165, 250, 0.18);
  }
  :global(.diff-content .moved-line.moved-pair-1) {
    --meerkat-moved-tint: rgba(192, 132, 252, 0.18);
  }
  :global(.diff-content .moved-line.moved-pair-2) {
    --meerkat-moved-tint: rgba(52, 211, 153, 0.18);
  }
  :global(.diff-content .moved-line.moved-pair-3) {
    --meerkat-moved-tint: rgba(251, 191, 36, 0.18);
  }
  :global(.diff-content tr.diff-line.moved-line) {
    background-image: linear-gradient(var(--meerkat-moved-tint), var(--meerkat-moved-tint));
  }
  :global(.diff-content td.diff-line-old-content.moved-line) {
    background-image:
      var(--meerkat-rulers-old, none),
      linear-gradient(var(--meerkat-moved-tint), var(--meerkat-moved-tint));
  }
  :global(.diff-content td.diff-line-new-content.moved-line) {
    background-image:
      var(--meerkat-rulers-new, none),
      linear-gradient(var(--meerkat-moved-tint), var(--meerkat-moved-tint));
  }
  :global(.diff-content td.diff-line-content.moved-line) {
    background-image:
      var(--meerkat-rulers-unified, none),
      linear-gradient(var(--meerkat-moved-tint), var(--meerkat-moved-tint));
  }
  /* A moved line's arrow covers its +/− mark, which turns invisible. */
  :global(.diff-content .diff-line-content-operator.moved-mark) {
    position: relative;
    color: transparent;
  }
  /* A borderless app.css button: it keeps the pointer and focus ring. */
  :global(.moved-arrow) {
    position: absolute;
    inset: 0;
    padding: 0;
    border: 0;
    background: none;
    font-weight: bold;
    text-align: center;
    text-indent: 0;
  }
  /* Outranks app.css's `button:hover:not(:disabled)`. */
  :global(.diff-content .moved-arrow:hover) {
    background: var(--border);
  }
  :global(.moved-arrow.moved-pair-0) { color: rgb(96, 165, 250); }
  :global(.moved-arrow.moved-pair-1) { color: rgb(192, 132, 252); }
  :global(.moved-arrow.moved-pair-2) { color: rgb(52, 211, 153); }
  :global(.moved-arrow.moved-pair-3) { color: rgb(251, 191, 36); }
</style>
