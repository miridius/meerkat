// Meerkat front-end entry point. LiveView socket + LiveSvelte hooks
// (WindowClose for the done-view auto-close, phx:open-url for the
// Post-to-GitHub new-tab navigation).

import "vite/modulepreload-polyfill";
import "../css/app.css";
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { getHooks } from "live_svelte";
import Components from "virtual:live-svelte-components";
import { countdownView } from "../ts/countdown";
import { holdTabState, onTabState, readTabState, writeTabState } from "../ts/tabs";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// WindowClose hook fires window.close() 500ms after the done view
// mounts. Chromium blocks the call for tabs not opened via
// window.open(), but the underlying "you can close this tab" copy
// + heading is the user-facing fallback — the spec asserts the
// heading is visible, not that the tab actually closed.
const hooks = {
  ...getHooks(Components),
  WindowClose: {
    mounted() {
      setTimeout(() => {
        try {
          window.close();
        } catch (_e) {
          /* Chromium blocks; leave the done view up */
        }
      }, 500);
    },
  },
  // Persists toolbar prefs (split/unified, wrap, font size, tab size)
  // in localStorage per browser; on mount, pushes them with
  // `settings.load`. The server's copy is the shared view, so every
  // tab of the review shows those settings. Toolbar events push
  // `settings:save` to the tab that changed them for localStorage.
  Settings: {
    mounted() {
      const KEY = "meerkat:settings";
      try {
        const raw = localStorage.getItem(KEY);
        if (raw) {
          const parsed = JSON.parse(raw);
          this.pushEvent("settings.load", parsed);
        }
      } catch (_e) {
        /* corrupt data — fall back to server defaults */
      }
      this.handleEvent("settings:save", (settings) => {
        try {
          localStorage.setItem(KEY, JSON.stringify(settings));
        } catch (_e) {
          /* storage full / disabled — settings remain only in the shared server view */
        }
      });
      // The hint dismissal is remembered per browser in
      // `meerkat:hint-dismissed`. HintDismiss pushes `hint.dismiss` on
      // mount when the flag is set; an explicit dismiss also reaches
      // the server. The server shares the dismissal across tabs and
      // sends `hint:set-dismissed` back to the sender, where this hook
      // writes the browser flag.
      this.handleEvent("hint:set-dismissed", () => {
        try {
          localStorage.setItem("meerkat:hint-dismissed", "1");
        } catch (_e) {
          /* storage disabled */
        }
      });
    },
  },
  // Ticks in the browser from an absolute deadline rather than from a
  // server push: the alternative sends every connected tab a diff once a
  // second, for as long as the review stays open.
  Countdown: {
    mounted() {
      this._tick = () => {
        const { text, warn, urgent } = countdownView(
          Number(this.el.dataset.deadline),
          Date.now(),
        );
        this.el.textContent = text;
        this.el.classList.toggle("urgent", urgent);
        this.el.classList.toggle("warn", warn);
      };
      this._tick();
      this._timer = setInterval(this._tick, 1000);
    },
    destroyed() {
      clearInterval(this._timer);
    },
  },
  // The toolbar wraps onto more rows as the window narrows, so
  // `.file-section-header` cannot pin itself below it at a fixed offset.
  ToolbarHeight: {
    mounted() {
      this._publish = () => {
        const h = Math.round(this.el.getBoundingClientRect().height);
        document.documentElement.style.setProperty("--toolbar-h", `${h}px`);
      };
      this._observer = new ResizeObserver(this._publish);
      this._observer.observe(this.el);
      this._publish();
    },
    destroyed() {
      this._observer?.disconnect();
      document.documentElement.style.removeProperty("--toolbar-h");
    },
  },
  // Generic "copy this element's data-copy attribute to clipboard"
  // hook. Used on per-file copy-name buttons in the file-section
  // header; flashes the .copied class for 1s so the click registers
  // visually without needing a toast.
  CopyOnClick: {
    mounted() {
      this._onClick = (ev) => {
        ev.preventDefault();
        const text = this.el.dataset.copy ?? "";
        if (!text) return;
        const finish = () => {
          this.el.classList.add("copied");
          setTimeout(() => this.el.classList.remove("copied"), 1000);
        };
        if (navigator.clipboard?.writeText) {
          navigator.clipboard.writeText(text).then(finish).catch(finish);
        } else {
          // Fallback: temporary textarea + execCommand("copy").
          const ta = document.createElement("textarea");
          ta.value = text;
          ta.style.position = "fixed";
          ta.style.left = "-9999px";
          document.body.appendChild(ta);
          ta.select();
          try {
            document.execCommand("copy");
          } catch (_e) {
            /* clipboard blocked */
          }
          ta.remove();
          finish();
        }
      };
      this.el.addEventListener("click", this._onClick);
    },
    destroyed() {
      this.el.removeEventListener("click", this._onClick);
    },
  },
  // On mount, read the per-browser `meerkat:hint-dismissed` flag.
  // If set, hide this tab's tip and push `hint.dismiss`; the server
  // records the dismissal in the shared view and hides the tip in
  // every tab. It then pushes `hint:set-dismissed` back to the sender
  // so the Settings hook can write the browser flag.
  HintDismiss: {
    mounted() {
      try {
        if (localStorage.getItem("meerkat:hint-dismissed") === "1") {
          this.el.style.display = "none";
          this.pushEvent("hint.dismiss", {});
        }
      } catch (_e) {
        /* storage disabled — leave the hint visible */
      }
    },
  },
  // Pointer-drag range selection over the commit-message gutter.
  // Each `<li>` carries `data-start-line`/`data-end-line` for the
  // block it represents; dragging across blocks selects from the
  // earliest start_line down to the latest end_line, then pushes
  // a single `comment_form.show_commit_msg` event for the range.
  CommitMsgGutter: {
    mounted() {
      const gutter = this.el;
      let dragStart = null;
      let dragEnd = null;

      const lineFor = (target) => {
        if (!(target instanceof Element)) return null;
        const li = target.closest("li[data-start-line]");
        if (!li || !gutter.contains(li)) return null;
        const s = Number(li.dataset.startLine);
        const e = Number(li.dataset.endLine);
        if (!Number.isFinite(s) || !Number.isFinite(e)) return null;
        return { li, start: s, end: e };
      };

      // Once the gutter captures the pointer, every move and up event
      // targets the <ol> itself, so find the block under the pointer.
      const lineUnder = (ev) =>
        lineFor(document.elementFromPoint(ev.clientX, ev.clientY) ?? ev.target);

      // Every tab of the review shows the blocks being dragged over in
      // any of them.
      const highlight = (range) => {
        for (const el of gutter.querySelectorAll("li.dragging")) {
          el.classList.remove("dragging");
        }
        if (!range) return;
        for (const li of gutter.querySelectorAll("li[data-start-line]")) {
          const s = Number(li.dataset.startLine);
          const e = Number(li.dataset.endLine);
          if (s >= range.lo && e <= range.hi) li.classList.add("dragging");
        }
      };

      const clearHighlight = () => {
        highlight(null);
        holdTabState("gutter-drag", null);
      };

      const applyHighlight = () => {
        if (!dragStart || !dragEnd) return clearHighlight();
        const range = {
          lo: Math.min(dragStart.start, dragEnd.start),
          hi: Math.max(dragStart.end, dragEnd.end),
        };
        highlight(range);
        holdTabState("gutter-drag", range);
      };

      highlight(readTabState("gutter-drag"));
      this._stopTabState = onTabState("gutter-drag", highlight);

      // Set on pointerdown; cleared on pointerup/cancel. Track the
      // pointerId separately so we can release the capture in the
      // same shape we acquired it (capture is per-pointer, not
      // per-listener).
      let capturedPointerId = null;

      this._onPointerDown = (ev) => {
        if (ev.button !== 0) return;
        const hit = lineFor(ev.target);
        if (!hit) return;
        // Just record the start block. Do NOT setPointerCapture
        // here: capturing on the <ol> before any movement steals
        // the button's implicit pointer capture, which makes
        // real-mouse pointerup synthesise its `click` event on the
        // gutter (a <ul>) instead of on the button, so phx-click on
        // the button never fires. We only need capture if the user
        // actually drags across blocks — defer until pointermove
        // crosses into a second block.
        dragStart = hit;
        dragEnd = hit;
      };

      this._onPointerMove = (ev) => {
        if (!dragStart) return;
        const hit = lineUnder(ev);
        if (!hit) return;
        if (hit.li === dragEnd?.li) return;
        // First time the pointer enters a different block — this is
        // a real drag. Grab pointer capture now so pointerup still
        // fires on the gutter even if the user releases outside the
        // <ol>'s bounding box.
        if (capturedPointerId === null) {
          try {
            gutter.setPointerCapture?.(ev.pointerId);
            capturedPointerId = ev.pointerId;
          } catch (_e) {
            /* ignore */
          }
        }
        dragEnd = hit;
        applyHighlight();
      };

      // Set when a pointerup ends a multi-block drag. The follow-up
      // `click` event fires AFTER pointerup; if we don't swallow it,
      // the start block's `phx-click` would also push a single-block
      // range and the form would race itself.
      let suppressNextClick = false;

      this._onPointerUp = (ev) => {
        if (!dragStart) return;
        const finalHit = lineUnder(ev) ?? dragEnd ?? dragStart;
        const lo = Math.min(dragStart.start, finalHit.start);
        const hi = Math.max(dragStart.end, finalHit.end);
        const crossedBlocks = finalHit.li !== dragStart.li;
        dragStart = null;
        dragEnd = null;
        clearHighlight();
        if (capturedPointerId !== null) {
          try {
            gutter.releasePointerCapture?.(capturedPointerId);
          } catch (_e) {
            /* ignore */
          }
          capturedPointerId = null;
        }
        if (crossedBlocks) {
          suppressNextClick = true;
          ev.preventDefault();
          ev.stopPropagation();
          this.pushEvent("comment_form.show_commit_msg", {
            start_line: String(lo),
            end_line: String(hi),
          });
        }
      };

      this._onClickCapture = (ev) => {
        if (!suppressNextClick) return;
        suppressNextClick = false;
        ev.preventDefault();
        ev.stopPropagation();
        ev.stopImmediatePropagation();
      };

      gutter.addEventListener("pointerdown", this._onPointerDown);
      gutter.addEventListener("pointermove", this._onPointerMove);
      gutter.addEventListener("pointerup", this._onPointerUp);
      gutter.addEventListener("pointercancel", this._onPointerUp);
      gutter.addEventListener("click", this._onClickCapture, { capture: true });
    },

    destroyed() {
      this._stopTabState();
      this.el.removeEventListener("pointerdown", this._onPointerDown);
      this.el.removeEventListener("pointermove", this._onPointerMove);
      this.el.removeEventListener("pointerup", this._onPointerUp);
      this.el.removeEventListener("pointercancel", this._onPointerUp);
      this.el.removeEventListener("click", this._onClickCapture, { capture: true });
    },
  },
  // Version chip popover + "new version" badge. data-pr-numbers lists the
  // changelog PR numbers; lastSeenPr (per origin, so per review port)
  // records the newest PR the reviewer has acknowledged. A live-restart
  // onto a newer version brings higher PR numbers, so the badge counts
  // those and clears when the popover opens.
  VersionChip: {
    mounted() {
      const wrap = this.el;
      const btn = wrap.querySelector(".version-chip-btn");
      const popover = wrap.querySelector(".version-popover");
      const badge = wrap.querySelector(".version-badge");
      const KEY = "meerkat:lastSeenPr";

      // Read fresh from the element each time: a server-only upgrade (no
      // asset change, so no full reload) live-restarts via a socket patch
      // that updates data-pr-numbers in place and fires updated(), not a
      // re-mount.
      const nums = () =>
        (wrap.dataset.prNumbers || "")
          .split(",")
          .map(Number)
          .filter((n) => Number.isFinite(n) && n > 0);
      const maxPr = () => {
        const ns = nums();
        return ns.length ? Math.max(...ns) : 0;
      };
      const lastSeen = () => {
        try {
          return parseInt(localStorage.getItem(KEY) || "0", 10) || 0;
        } catch (_e) {
          return 0;
        }
      };
      const setSeen = (n) => {
        try {
          localStorage.setItem(KEY, String(n));
        } catch (_e) {
          /* storage disabled; the badge just won't persist */
        }
      };
      this._refreshBadge = () => {
        const count = nums().filter((n) => n > lastSeen()).length;
        badge.textContent = String(count);
        badge.hidden = count === 0;
      };

      // First sight of this review's origin: treat the current version as
      // seen so the badge fires only after a later live-restart.
      try {
        if (localStorage.getItem(KEY) === null) setSeen(maxPr());
      } catch (_e) {
        /* storage disabled */
      }
      this._refreshBadge();

      // The server owns whether the popover is open, so every tab of the
      // review shows the same; each tab marks the changelog seen while
      // it shows the popover.
      this._sync = () => {
        if (!popover.hidden) setSeen(maxPr());
        this._refreshBadge();
      };
      this._sync();

      const setOpen = (open) => this.pushEvent("version.set_popover_open", { open });
      this._onClick = () => setOpen(popover.hidden);
      btn.addEventListener("click", this._onClick);

      this._onDocClick = (e) => {
        if (!popover.hidden && !wrap.contains(e.target)) setOpen(false);
      };
      this._onEsc = (e) => {
        if (e.key === "Escape" && !popover.hidden) setOpen(false);
      };
      // Another tab marking the changelog seen clears this tab's badge.
      this._onStorage = (e) => {
        if (e.key === KEY) this._refreshBadge();
      };
      document.addEventListener("click", this._onDocClick, true);
      document.addEventListener("keydown", this._onEsc);
      window.addEventListener("storage", this._onStorage);
    },
    updated() {
      this._sync?.();
    },
    destroyed() {
      document.removeEventListener("click", this._onDocClick, true);
      document.removeEventListener("keydown", this._onEsc);
      window.removeEventListener("storage", this._onStorage);
    },
  },
  // The display-settings `<details>`: the server owns whether it is
  // open, so every tab of the review shows the same.
  SettingsPopover: {
    mounted() {
      this._onToggle = () => {
        if (this.el.open !== (this.el.dataset.open === "true")) {
          this.pushEvent("toolbar.set_settings_open", { open: this.el.open });
        }
      };
      this.el.addEventListener("toggle", this._onToggle);
    },
    destroyed() {
      this.el.removeEventListener("toggle", this._onToggle);
    },
  },
  // LiveView does not patch a focused input's value, so this hook keeps the
  // box in sync with the review's shared filter, including changes from other
  // tabs. It leaves the box alone while typing is pending or pushes are in
  // flight, then applies the shared value once idle so late replies cannot
  // overwrite newer typing.
  SharedInput: {
    mounted() {
      this._timer = null;
      this._pending = 0;
      this._sync = () => {
        if (this._timer || this._pending > 0) return;
        if (this.el.value !== this.el.dataset.value) this.el.value = this.el.dataset.value;
      };
      const pushed = () => {
        this._pending--;
        this._sync();
      };
      this._onInput = () => {
        clearTimeout(this._timer);
        this._timer = setTimeout(() => {
          this._timer = null;
          this._pending++;
          this.pushEvent(this.el.dataset.event, { value: this.el.value }).then(pushed, pushed);
        }, 50);
      };
      this.el.addEventListener("input", this._onInput);
    },
    updated() {
      this._sync();
    },
    destroyed() {
      clearTimeout(this._timer);
      this.el.removeEventListener("input", this._onInput);
    },
  },
};

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks,
});

window.addEventListener("phx:drafts:wipe", (e) => {
  const review_id = e.detail?.review_id;
  if (!review_id) return;
  try {
    const prefixes = [`meerkat:draft:${review_id}:`, `meerkat:view:${review_id}:`];
    const stale = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (prefixes.some((p) => k?.startsWith(p))) stale.push(k);
    }
    for (const k of stale) localStorage.removeItem(k);
  } catch (_e) {
    /* storage disabled — nothing to clean */
  }
});

// `push_event(socket, "open-url", %{url: ...})` from the server
// fires this window event; we open the URL in a new tab. Used by
// Post-to-GitHub to navigate the user to the freshly-created
// PENDING review. `noopener` keeps the new tab out of
// window.opener (and so out of postMessage range from the parent).
window.addEventListener("phx:open-url", (e) => {
  const url = e.detail?.url;
  if (typeof url === "string") {
    window.open(url, "_blank", "noopener");
  }
});

// Server-driven scroll for file approval and file-filter panel opening.
// After approval, it re-anchors the collapsed file header at the top of
// the viewport; otherwise the next file leaps up by about a viewport height.
// On every panel open, it scrolls the panel to the top of the viewport,
// regardless of the current scroll position. The handler scrolls the element
// with the given id to the top of the viewport.
window.addEventListener("phx:scroll-into-view", (e) => {
  const id = e.detail?.id;
  if (typeof id !== "string") return;
  const el = document.getElementById(id);
  if (el) el.scrollIntoView({ block: "start", behavior: "smooth" });
});

// A footer open-form link: the server has just expanded / unhidden the
// form's file, so the form may take a few frames to mount (DiffViewer
// injects inline forms two frames after render).
window.addEventListener("phx:comment-form:reveal", (e) => {
  const { key, id } = e.detail ?? {};
  if (typeof key !== "string" || typeof id !== "string") return;
  const find = () =>
    document.getElementById(id) ??
    document.querySelector(`tr.meerkat-form-row[data-meerkat-form-key="${CSS.escape(key)}"]`);
  const deadline = performance.now() + 3000;
  const tick = () => {
    const el = find();
    if (el) {
      el.scrollIntoView({ block: "center" });
      el.querySelector("textarea")?.focus({ preventScroll: true });
    } else if (performance.now() < deadline) {
      requestAnimationFrame(tick);
    } else {
      console.warn("meerkat: open form not found to reveal", key);
    }
  };
  tick();
});

// Every tab of the review stays scrolled to the same place: a tab that
// scrolls saves where it is as tab state, the others follow, and a tab
// that opens or reloads (a live-restart reloads every tab) scrolls
// there. A scroll this tab made to follow (`echoY`) is not saved back.
//
// The diff only renders once the LiveView connects (a few hundred ms
// after a load), so the document is too short to scroll at first. Poll
// each frame until it's tall enough to reach the position, then scroll
// once; give up after a few seconds (a shorter diff clamps to its own
// bottom).
//
// Do not publish a tab's temporary scroll while its page renders:
// ignore scroll events until the shared-position restore finishes
// (immediately if there is no shared position). Browser scroll
// restoration is disabled, so this code is the only restore.
let echoY = null;
const scrollWhenReachable = (anchor, done = () => {}) => {
  if (!anchor) return done();
  const deadline = Date.now() + 5000;
  const attempt = () => {
    const y = Math.round(anchorY(anchor));
    const maxY = document.documentElement.scrollHeight - window.innerHeight;
    if (maxY >= y || Date.now() >= deadline) {
      echoY = Math.max(0, Math.min(y, maxY));
      window.scrollTo(0, y);
      done();
    } else {
      requestAnimationFrame(attempt);
    }
  };
  requestAnimationFrame(attempt);
};

// The file section at the top of the viewport and how far into it the
// tab has scrolled, as a fraction of its height, so tabs whose windows
// differ in width still show the same place. `id` is null above the
// first file.
const scrollAnchor = () => {
  let section = null;
  for (const el of document.querySelectorAll(".file-section")) {
    if (el.getBoundingClientRect().top > 0) break;
    section = el;
  }
  if (!section) return { id: null, fraction: 0, y: window.scrollY };
  const rect = section.getBoundingClientRect();
  return { id: section.id, fraction: -rect.top / rect.height, y: window.scrollY };
};

const anchorY = ({ id, fraction, y }) => {
  const el = id ? document.getElementById(id) : null;
  if (!el) return y;
  return el.getBoundingClientRect().top + window.scrollY + fraction * el.offsetHeight;
};

let scrollPostPending = false;
let restored = false;
history.scrollRestoration = "manual";
window.addEventListener(
  "scroll",
  () => {
    if (!restored) return;
    const echo = echoY !== null && Math.abs(window.scrollY - echoY) <= 1;
    echoY = null;
    if (echo || scrollPostPending) return;
    scrollPostPending = true;
    requestAnimationFrame(() => {
      scrollPostPending = false;
      writeTabState("scroll", scrollAnchor());
    });
  },
  { passive: true },
);

scrollWhenReachable(readTabState("scroll"), () => {
  restored = true;
});
onTabState("scroll", scrollWhenReachable);

liveSocket.connect();
window.liveSocket = liveSocket;
