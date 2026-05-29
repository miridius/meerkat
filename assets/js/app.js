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
  // in localStorage and rehydrates them on mount so they survive a
  // reload. The server keeps an in-memory copy; on mount we push our
  // values up, and the LV pushes any subsequent change back via
  // `settings:save` for us to save.
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
          /* storage full / disabled — stays in-memory for this tab */
        }
      });
      // The hint banner is dismissed once per browser via
      // `meerkat:hint-dismissed`. The LV pushes `hint.dismiss` only on
      // explicit click, but the JS hook hides the banner on mount if
      // the flag is already set so reviewers don't see the same line
      // every session.
      this.handleEvent("hint:set-dismissed", () => {
        try {
          localStorage.setItem("meerkat:hint-dismissed", "1");
        } catch (_e) {
          /* storage disabled */
        }
      });
      this.handleEvent("drafts:wipe", ({ review_id }) => {
        if (!review_id) return;
        try {
          const prefix = `meerkat:draft:${review_id}:`;
          const stale = [];
          for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i);
            if (k && k.startsWith(prefix)) stale.push(k);
          }
          for (const k of stale) localStorage.removeItem(k);
        } catch (_e) {
          /* storage disabled — nothing to clean */
        }
      });
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
  // Hide the line-comment hint banner on mount if the user has
  // already dismissed it once in this browser. The dismiss flag
  // lives under `meerkat:hint-dismissed` and is set by the Settings
  // hook when the LV pushes `hint:set-dismissed`.
  HintDismiss: {
    mounted() {
      try {
        if (localStorage.getItem("meerkat:hint-dismissed") === "1") {
          this.el.style.display = "none";
        }
      } catch (_e) {
        /* storage disabled — leave the hint visible */
      }
      this.handleEvent("hint:set-dismissed", () => {
        this.el.style.display = "none";
      });
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

      const clearHighlight = () => {
        for (const el of gutter.querySelectorAll("li.dragging")) {
          el.classList.remove("dragging");
        }
      };

      const applyHighlight = () => {
        clearHighlight();
        if (!dragStart || !dragEnd) return;
        const lo = Math.min(dragStart.start, dragEnd.start);
        const hi = Math.max(dragStart.end, dragEnd.end);
        for (const li of gutter.querySelectorAll("li[data-start-line]")) {
          const s = Number(li.dataset.startLine);
          const e = Number(li.dataset.endLine);
          if (s >= lo && e <= hi) li.classList.add("dragging");
        }
      };

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
        const hit = lineFor(ev.target);
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
        const finalHit = lineFor(ev.target) ?? dragEnd ?? dragStart;
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
      this.el.removeEventListener("pointerdown", this._onPointerDown);
      this.el.removeEventListener("pointermove", this._onPointerMove);
      this.el.removeEventListener("pointerup", this._onPointerUp);
      this.el.removeEventListener("pointercancel", this._onPointerUp);
      this.el.removeEventListener("click", this._onClickCapture, { capture: true });
    },
  },
};

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks,
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

// Server-driven scroll. Fired by `file.toggle_approved` so the
// just-collapsed file header re-anchors to the top of the viewport
// — without this the next file leaps up by ~viewport height.
window.addEventListener("phx:scroll-into-view", (e) => {
  const id = e.detail?.id;
  if (typeof id !== "string") return;
  const el = document.getElementById(id);
  if (el) el.scrollIntoView({ block: "start", behavior: "smooth" });
});

liveSocket.connect();
window.liveSocket = liveSocket;
