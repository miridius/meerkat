<script context="module" lang="ts">
  import type { DiffHighlighter } from "@git-diff-view/shiki";
  import { getDiffViewHighlighter } from "@git-diff-view/shiki";

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

  const sharedHighlighter: Promise<DiffHighlighter | null> = getDiffViewHighlighter(
    PRELOAD_LANGS as never[],
  )
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
</script>

<script lang="ts">
  import { DiffFile, DiffView, DiffModeEnum, SplitSide } from "@git-diff-view/svelte";
  import "@git-diff-view/svelte/styles/diff-view.css";
  import { mount, unmount, tick } from "svelte";
  import InlineComment from "./InlineComment.svelte";
  import CommentForm from "./CommentForm.svelte";
  import PlantUmlPreview from "./PlantUmlPreview.svelte";

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
    language: string;
    old_content: string;
    new_content: string;
    hunks: string[];
    status?: string | null;
    read_errors?: string[] | null;
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
    learn_from_this?: boolean | null;
  };

  type LiveBridge = {
    pushEvent: (event: string, payload: unknown, cb?: (reply: unknown) => void) => void;
  };

  type InlineFormDescriptor = {
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
    comments = [],
    inline_form = null,
    plantuml_available = false,
    live,
  }: {
    file: FileDiff;
    file_index: number;
    mode?: "split" | "unified";
    wrap_lines?: boolean;
    font_size_px?: number;
    tab_size?: number;
    comments?: InlineCommentT[];
    inline_form?: InlineFormDescriptor | null;
    plantuml_available?: boolean;
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

  const diffViewMode = $derived(
    isOneSided
      ? DiffModeEnum.Unified
      : mode === "unified"
        ? DiffModeEnum.Unified
        : DiffModeEnum.Split,
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
  $effect(() => {
    const lang = file.language;
    if (!lang || lang === "plaintext" || lang === "text") {
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
    const oldName = file.old_file_name ?? file.file_name;
    const unifiedDiff = [
      `diff --git a/${oldName} b/${file.file_name}`,
      `--- a/${oldName}`,
      `+++ b/${file.file_name}`,
      ...file.hunks,
    ].join("\n");

    try {
      const instance = DiffFile.createInstance({
        oldFile: { fileName: oldName, fileLang: file.language, content: file.old_content },
        newFile: { fileName: file.file_name, fileLang: file.language, content: file.new_content },
        hunks: [unifiedDiff],
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
  // Re-runs whenever the comments prop or diff instance changes;
  // tolerates @git-diff-view's internal re-renders by re-applying.
  let mountedInlineComments: Array<{ component: ReturnType<typeof mount>; host: HTMLElement }> = [];
  let injectedCommentRows: HTMLTableRowElement[] = [];
  let mountedInlineForm: { component: ReturnType<typeof mount>; row: HTMLTableRowElement } | null = null;

  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    void comments.length;
    let cancelled = false;
    // Defer two animation frames so @git-diff-view's syntax / extend
    // rendering settles before we walk the rows.
    const h1 = requestAnimationFrame(() => {
      const h2 = requestAnimationFrame(() => {
        if (cancelled) return;
        applyCommentMarkers();
        renderInlineComments();
      });
      (window as Window & { __h2?: number }).__h2 = h2;
    });
    return () => {
      cancelled = true;
      cancelAnimationFrame(h1);
    };
  });

  // Hunk-expand: re-render injected rows when @git-diff-view changes
  // the diff body's row structure. Strictly scoped to mutations on
  // tbody whose added/removed nodes are tr.diff-line — anything else
  // (CodeMirror's DOM churn inside the form, our own row injects,
  // attribute / text changes from syntax highlighting) is ignored.
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
        applyCommentMarkers();
        renderInlineComments();
        renderInlineForm(inline_form);
      });
    });
    obs.observe(diffContainer, { childList: true, subtree: true });
    return () => obs.disconnect();
  });

  // Inject the inline-comment FORM at its anchor row when the LV's
  // open_form points at this file. Re-runs whenever inline_form
  // changes; tears down the previous mount cleanly so a re-anchor
  // (drag a different range) moves the form instead of stacking it.
  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    const desc = inline_form;
    const handle = requestAnimationFrame(() => {
      const handle2 = requestAnimationFrame(() => renderInlineForm(desc));
      (window as Window & { __h2?: number }).__h2 = handle2;
    });
    return () => cancelAnimationFrame(handle);
  });

  function renderInlineForm(desc: InlineFormDescriptor | null) {
    if (!diffContainer) return;
    if (mountedInlineForm) {
      try {
        unmount(mountedInlineForm.component);
      } catch {
        /* already gone */
      }
      mountedInlineForm.row.parentNode?.removeChild(mountedInlineForm.row);
      mountedInlineForm = null;
    }
    // Belt-and-braces: any orphan form row gets swept.
    diffContainer
      .querySelectorAll("tr.meerkat-form-row")
      .forEach((tr) => tr.parentNode?.removeChild(tr));

    if (!desc) return;
    const side = desc.anchor.side === "old" ? "old" : "new";
    const rows = anchorRowsFor(side, desc.anchor.end_line);
    if (rows.length === 0) return;
    const anchor = rows[rows.length - 1];

    const tr = buildSideAwareRow(anchor, side, "meerkat-form-row", "meerkat-form-cell");
    tr.setAttribute("data-meerkat-form-anchor", String(desc.anchor.end_line));
    tr.setAttribute("data-meerkat-form-side", side);
    const contentTd = tr.querySelector("td.meerkat-form-cell") as HTMLTableCellElement;
    anchor.parentNode?.insertBefore(tr, anchor.nextSibling);

    const cmp = mount(CommentForm, {
      target: contentTd,
      props: { ...desc.props, live },
    });
    mountedInlineForm = { component: cmp, row: tr };
  }

  function applyCommentMarkers() {
    if (!diffContainer) return;
    diffContainer.querySelectorAll("tr.diff-line.has-inline-comment").forEach((row) => {
      row.classList.remove("has-inline-comment");
    });
    // Build a `"side:line" -> rows` map once per call. Previously we
    // did `anchorRowsFor(side, n)` per LINE per comment, each
    // firing two querySelectorAll. A 50-line comment range hits 100
    // queries; this collapses to one walk of `tr.diff-line` plus
    // O(1) Map lookups per (side, line).
    const rowsBySideLine = buildAnchorIndex();
    for (const c of comments) {
      const wantSide = c.side === "old" ? "old" : "new";
      for (let n = c.start_line; n <= c.end_line; n++) {
        const rows = rowsBySideLine.get(`${wantSide}:${n}`);
        rows?.forEach((row) => row.classList.add("has-inline-comment"));
      }
    }
  }

  // One-pass scan of every `tr.diff-line` under diffContainer; emits
  // a `"old:N" | "new:N" -> rows[]` map. Skips our injected comment
  // rows so we don't re-anchor comments to comment hosts.
  function buildAnchorIndex(): Map<string, HTMLTableRowElement[]> {
    const index = new Map<string, HTMLTableRowElement[]>();
    if (!diffContainer) return index;
    const rows = diffContainer.querySelectorAll<HTMLTableRowElement>(
      "tr.diff-line:not(.meerkat-comment-row):not(.meerkat-form-row)",
    );
    for (const row of rows) {
      // Inspect every line-number anchor inside this row. Same row
      // can carry both sides in unified mode; in split mode each
      // <td> has one side.
      row.querySelectorAll<HTMLElement>("[data-line-new-num]").forEach((el) => {
        push(index, "new", el.getAttribute("data-line-new-num"), row);
      });
      row.querySelectorAll<HTMLElement>("[data-line-old-num]").forEach((el) => {
        push(index, "old", el.getAttribute("data-line-old-num"), row);
      });
      // Split-mode generic span: `td.diff-line-{side}-num > span[data-line-num]`.
      row.querySelectorAll<HTMLElement>("td.diff-line-new-num span[data-line-num]").forEach((el) => {
        push(index, "new", el.getAttribute("data-line-num"), row);
      });
      row.querySelectorAll<HTMLElement>("td.diff-line-old-num span[data-line-num]").forEach((el) => {
        push(index, "old", el.getAttribute("data-line-num"), row);
      });
    }
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
    diffContainer
      .querySelectorAll("tr.meerkat-comment-row")
      .forEach((tr) => tr.parentNode?.removeChild(tr));

    for (const group of commentGroups()) {
      const rows = anchorRowsFor(group.side, group.line);
      if (rows.length === 0) continue;
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

  // Re-apply `.drag-selecting` to every line-num cell + row in the
  // current drag range so the reviewer can see what they're about to
  // anchor on. Runs whenever the drag state changes; cleared when
  // `dragStart` returns to null.
  $effect(() => {
    if (!diffContainer) return;
    for (const el of diffContainer.querySelectorAll(".drag-selecting")) {
      el.classList.remove("drag-selecting");
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
      td.closest("tr.diff-line")?.classList.add("drag-selecting");
    }
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

  // Moved-line highlighting + jump badges. Each block of moved lines
  // gets a coloured background (4 colors cycled by pairId) on the
  // covered rows, plus a clickable "← from foo:N" / "→ to foo:N"
  // badge in the corner of the first row. Click dispatches a
  // document-level `meerkat-move-jump` event the sibling DiffViewers
  // listen for so the target file scrolls into view and flashes.
  $effect(() => {
    if (!diffContainer || !diffInstance) return;
    const blocks = file.moved_lines ?? [];
    const handle = requestAnimationFrame(() => applyMovedHighlights(blocks));
    return () => cancelAnimationFrame(handle);
  });

  function clearMovedHighlights() {
    if (!diffContainer) return;
    diffContainer.querySelectorAll(".moved-line").forEach((el) => {
      el.classList.remove("moved-line", "moved-pair-0", "moved-pair-1", "moved-pair-2", "moved-pair-3");
    });
    diffContainer.querySelectorAll(".moved-badge").forEach((el) => el.remove());
  }

  function applyMovedHighlights(blocks: MovedBlock[]) {
    if (!diffContainer) return;
    clearMovedHighlights();
    if (blocks.length === 0) return;

    for (const block of blocks) {
      const pairClass = `moved-pair-${block.pair_id % 4}`;
      const side = block.side === "old" ? "old" : "new";
      for (let ln = block.line_start; ln <= block.line_end; ln++) {
        anchorRowsFor(side, ln).forEach((row) => {
          row.classList.add("moved-line", pairClass);
          const td = row.querySelector(`td.diff-line-${side}-content`);
          if (td) td.classList.add("moved-line", pairClass);
        });
      }
      const firstRows = anchorRowsFor(side, block.line_start);
      if (firstRows.length === 0) continue;
      const contentTd = firstRows[0].querySelector(
        `td.diff-line-${side}-content, td.diff-line-content`,
      ) as HTMLElement | null;
      if (!contentTd) continue;

      const badge = document.createElement("button");
      badge.type = "button";
      badge.className = `moved-badge ${pairClass}`;
      const arrow = block.side === "old" ? "→" : "←";
      const range =
        block.to_line_start === block.to_line_end
          ? `${block.to_line_start}`
          : `${block.to_line_start}-${block.to_line_end}`;
      badge.textContent = `${arrow} ${block.to_file}:${range}`;
      badge.title = `moved ${block.side === "old" ? "to" : "from"} ${block.to_file} lines ${range}`;
      badge.addEventListener("click", (e) => {
        e.stopPropagation();
        document.dispatchEvent(
          new CustomEvent("meerkat-move-jump", {
            detail: {
              fileName: block.to_file,
              side: block.to_side,
              lineStart: block.to_line_start,
              lineEnd: block.to_line_end,
            },
          }),
        );
      });
      contentTd.style.position = "relative";
      contentTd.appendChild(badge);
    }
  }

  // Listen for jump events from sibling DiffViewers. If the event's
  // fileName matches THIS file, scroll the target line into view and
  // flash a temporary highlight so the reviewer can spot the
  // counterpart of a moved block they just clicked.
  $effect(() => {
    if (!diffContainer) return;
    const handler = (e: Event) => {
      const ev = e as CustomEvent<{ fileName: string; side: "old" | "new"; lineStart: number; lineEnd: number }>;
      if (!ev.detail || ev.detail.fileName !== file.file_name) return;
      const rows = anchorRowsFor(ev.detail.side, ev.detail.lineStart);
      if (rows.length === 0) return;
      const row = rows[0];
      row.scrollIntoView({ block: "center", behavior: "smooth" });
      // Flash highlight for 1.6s.
      for (let ln = ev.detail.lineStart; ln <= ev.detail.lineEnd; ln++) {
        anchorRowsFor(ev.detail.side, ln).forEach((r) => r.classList.add("moved-flash"));
      }
      setTimeout(() => {
        for (let ln = ev.detail.lineStart; ln <= ev.detail.lineEnd; ln++) {
          anchorRowsFor(ev.detail.side, ln).forEach((r) => r.classList.remove("moved-flash"));
        }
      }, 1600);
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
      if (mountedInlineForm) {
        try {
          unmount(mountedInlineForm.component);
        } catch {
          /* already gone */
        }
        mountedInlineForm.row.parentNode?.removeChild(mountedInlineForm.row);
        mountedInlineForm = null;
      }
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

{#if diffInstance}
  <div
    class="diff-content"
    role="presentation"
    bind:this={diffContainer}
    onpointerdown={handlePointerDown}
    onpointermove={handlePointerMove}
    onpointerup={handlePointerUp}
    onpointercancel={handlePointerCancel}
    style:tab-size={tab_size}
    style:--tab-size={tab_size}
  >
    <DiffView
      diffFile={diffInstance}
      {diffViewMode}
      diffViewWrap={wrap_lines}
      diffViewHighlight={true}
      diffViewFontSize={font_size_px}
      diffViewTheme="dark"
      diffViewAddWidget={false}
      registerHighlighter={highlighter ?? undefined}
    />
  </div>
{/if}

{#if isPlantUml && file.status !== "deleted"}
  <PlantUmlPreview
    oldSource={file.old_content ?? ""}
    newSource={file.new_content ?? ""}
    status={(file.status ?? "modified") as "added" | "modified" | "deleted" | "renamed"}
    available={plantuml_available}
  />
{/if}

<style>
  .diff-content {
    border: 1px solid #30363d;
    border-radius: 0 0 6px 6px;
    background: #0d1117;
    /* horizontal scroll for long unwrapped lines; vertical scroll
       handled by the page body */
    overflow-x: auto;
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
  /* Drag-select highlight — applied to every line-num cell + row
     between dragStart and dragCurrent so the reviewer can see the
     range they're about to anchor a comment on. Cleared on
     pointerup / pointercancel via the $effect that drives it. */
  /* `!important` so the highlight wins over the diff library's
     per-row `.diff-line-add` / `.diff-line-del` backgrounds —
     without it the green/red add/del shading completely masks
     the drag indicator. */
  :global(.diff-content td.diff-line-old-num.drag-selecting),
  :global(.diff-content td.diff-line-new-num.drag-selecting),
  :global(.diff-content td.diff-line-num.drag-selecting) {
    background: #1f6feb !important;
    color: #ffffff !important;
  }
  :global(.diff-content tr.diff-line.drag-selecting > td) {
    background: rgba(31, 111, 235, 0.32) !important;
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
     <td>; no per-line gutter so the comment body reads cleanly. */
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
  /* Spacer halves on the opposite side from a side-aware comment /
     form row. Subtle border so the spatial relationship to the
     anchor row reads correctly. */
  :global(.diff-content tr.meerkat-comment-row > td.meerkat-comment-cell-spacer),
  :global(.diff-content tr.meerkat-form-row > td.meerkat-form-cell-spacer) {
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
  /* Moved-line highlighting — 4 colors cycled by pair id. */
  :global(.diff-content tr.diff-line.moved-line.moved-pair-0),
  :global(.diff-content td.diff-line-old-content.moved-line.moved-pair-0),
  :global(.diff-content td.diff-line-new-content.moved-line.moved-pair-0) {
    background-image: linear-gradient(
      rgba(96, 165, 250, 0.18),
      rgba(96, 165, 250, 0.18)
    );
  }
  :global(.diff-content tr.diff-line.moved-line.moved-pair-1),
  :global(.diff-content td.diff-line-old-content.moved-line.moved-pair-1),
  :global(.diff-content td.diff-line-new-content.moved-line.moved-pair-1) {
    background-image: linear-gradient(
      rgba(192, 132, 252, 0.18),
      rgba(192, 132, 252, 0.18)
    );
  }
  :global(.diff-content tr.diff-line.moved-line.moved-pair-2),
  :global(.diff-content td.diff-line-old-content.moved-line.moved-pair-2),
  :global(.diff-content td.diff-line-new-content.moved-line.moved-pair-2) {
    background-image: linear-gradient(
      rgba(52, 211, 153, 0.18),
      rgba(52, 211, 153, 0.18)
    );
  }
  :global(.diff-content tr.diff-line.moved-line.moved-pair-3),
  :global(.diff-content td.diff-line-old-content.moved-line.moved-pair-3),
  :global(.diff-content td.diff-line-new-content.moved-line.moved-pair-3) {
    background-image: linear-gradient(
      rgba(251, 191, 36, 0.18),
      rgba(251, 191, 36, 0.18)
    );
  }
  :global(.diff-content tr.diff-line.moved-flash) {
    animation: moved-flash-anim 1.6s ease-out;
  }
  @keyframes moved-flash-anim {
    0%, 60% { background-color: rgba(88, 166, 255, 0.35); }
    100% { background-color: transparent; }
  }
  :global(.moved-badge) {
    position: absolute;
    top: 2px;
    right: 6px;
    z-index: 2;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 10px;
    padding: 1px 6px;
    border-radius: 3px;
    border: 1px solid #30363d;
    background: #161b22;
    color: #c9d1d9;
    cursor: pointer;
    max-width: 40ch;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  :global(.moved-badge:hover) {
    background: #21262d;
    border-color: #58a6ff;
  }
  :global(.moved-badge.moved-pair-0) { border-left: 3px solid rgb(96, 165, 250); }
  :global(.moved-badge.moved-pair-1) { border-left: 3px solid rgb(192, 132, 252); }
  :global(.moved-badge.moved-pair-2) { border-left: 3px solid rgb(52, 211, 153); }
  :global(.moved-badge.moved-pair-3) { border-left: 3px solid rgb(251, 191, 36); }
</style>
