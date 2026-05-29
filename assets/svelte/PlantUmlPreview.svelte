<script lang="ts">
  // Per-side PlantUML preview, rendered server-side via
  // /api/plantuml/svg (Meerkat.PlantUML.render/1 pipes the source
  // into `plantuml -tsvg -pipe`). Shows Old + New side-by-side for
  // modified / renamed files, Old-only for deleted, New-only for
  // added. Empty sources are skipped.

  let {
    oldSource,
    newSource,
    status,
    available,
  }: {
    oldSource: string;
    newSource: string;
    status: "added" | "modified" | "deleted" | "renamed";
    available: boolean;
  } = $props();

  type Side = { label: string; source: string };

  const sides = $derived.by<Side[]>(() => {
    const out: Side[] = [];
    if (status !== "added" && oldSource.length > 0) {
      out.push({ label: "Old", source: oldSource });
    }
    if (status !== "deleted" && newSource.length > 0) {
      out.push({ label: "New", source: newSource });
    }
    return out;
  });

  function imgSrc(source: string): string {
    return `/api/plantuml/svg?src=${encodeURIComponent(source)}`;
  }

  // Per-side error state. The `/api/plantuml/svg` endpoint returns
  // 422 with the actual `plantuml` stderr in the body (see
  // `MeerkatWeb.PlantUMLController.svg/2`). On `<img>` `onerror` we
  // re-`fetch` the same URL so we can read that body and show the
  // real reason rather than a generic "render failed — likely
  // syntax" placeholder.
  let imgErrors = $state<Record<string, string>>({});

  function markImgError(label: string, source: string) {
    if (imgErrors[label] !== undefined) return;
    imgErrors = { ...imgErrors, [label]: "Fetching error details…" };
    fetch(imgSrc(source))
      .then((r) => r.text().then((body) => ({ status: r.status, body })))
      .then(({ status, body }) => {
        imgErrors = {
          ...imgErrors,
          [label]: body && body.trim() !== "" ? body : `HTTP ${status} from plantuml endpoint`,
        };
      })
      .catch((e) => {
        imgErrors = { ...imgErrors, [label]: String(e) };
      });
  }
</script>

<section class="puml-preview" aria-label="PlantUML preview">
  {#if !available}
    <div class="puml-hint">
      <strong>Install <code>plantuml</code> to see inline previews.</strong>
      Tried <code>plantuml -version</code>; not found on <code>$PATH</code>.
      macOS: <code>brew install plantuml</code>. Diagrams render locally — nothing leaves your machine.
    </div>
  {:else if sides.length === 0}
    <div class="puml-hint">No diagram source on either side.</div>
  {:else}
    <header class="puml-head">
      <span class="puml-label">PlantUML preview</span>
      <span class="puml-note">rendered locally</span>
    </header>
    <div class="puml-grid" class:single={sides.length === 1}>
      {#each sides as side (side.label)}
        <figure class="puml-side">
          <figcaption class="puml-side-head">
            <span class="puml-side-label">{side.label}</span>
          </figcaption>
          {#if imgErrors[side.label] !== undefined}
            <div class="puml-error">
              <strong>plantuml failed to render the {side.label.toLowerCase()} side.</strong>
              <pre class="puml-error-body">{imgErrors[side.label]}</pre>
            </div>
          {:else}
            <img
              class="puml-img"
              src={imgSrc(side.source)}
              alt={`PlantUML diagram (${side.label} side)`}
              onerror={() => markImgError(side.label, side.source)}
            />
          {/if}
        </figure>
      {/each}
    </div>
  {/if}
</section>

<style>
  .puml-preview {
    margin-top: 6px;
    background: #0d1117;
    border-top: 1px solid #30363d;
    padding: 8px 12px;
  }
  .puml-head {
    display: flex;
    align-items: baseline;
    gap: 8px;
    margin-bottom: 6px;
  }
  .puml-label {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #8b949e;
  }
  .puml-note {
    font-size: 0.7rem;
    color: #6e7681;
  }
  .puml-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }
  .puml-grid.single {
    grid-template-columns: 1fr;
  }
  .puml-side {
    margin: 0;
    border: 1px solid #30363d;
    border-radius: 4px;
    padding: 8px;
    background: #ffffff;
  }
  .puml-side-head {
    margin: 0 0 4px;
    font-size: 0.7rem;
    color: #6e7681;
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  .puml-img {
    display: block;
    width: 100%;
    height: auto;
    max-height: 80vh;
    object-fit: contain;
  }
  .puml-hint {
    font-size: 0.85rem;
    color: #c9d1d9;
    padding: 6px 10px;
    border: 1px dashed #444c56;
    border-radius: 4px;
    background: #161b22;
  }
  .puml-hint code {
    background: rgba(110, 118, 129, 0.2);
    padding: 0 4px;
    border-radius: 3px;
  }
  .puml-error {
    font-size: 0.8rem;
    color: #ffa198;
    padding: 6px 8px;
    background: rgba(248, 81, 73, 0.08);
    border: 1px solid rgba(248, 81, 73, 0.4);
    border-radius: 4px;
  }
  .puml-error-body {
    margin: 4px 0 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.75rem;
    color: #ffd2cc;
    white-space: pre-wrap;
    overflow-x: auto;
  }
</style>
