# schaumamal.at — working notes for Claude Code

Charts about climate change in Austria, one topic per visual, for arguments
Fabian keeps having with friends. Julia + Makie, exported to static files,
served from GitHub Pages at `schaumamal.at`.

This is the **public** source repository. Planning notes (roadmap, diary)
live in the private `klimacharts` repo and must not be copied here. Nothing
in this repo may contain private notes, session links or credentials.

## The constraint that shapes everything

**The published page has no Julia process behind it.**

GitHub Pages serves static files. WGLMakie's usual interactivity comes from a
live Julia process over a WebSocket, and there is none. So anything that would
re-enter Makie's conversion pipeline at interaction time cannot run:

- pushing new data into a plot
- recomputing axis limits
- any `on(obs) do ...` callback with Julia in it

What *does* survive is directly-synced GPU state, and that is fiddly and
version-sensitive. So the working rule is:

> Prefer no JavaScript. Pre-render every variant at build time and switch
> between them with CSS. Reach for JS-side observables only when the
> combinatorics make pre-rendering genuinely impossible, and prove it works in
> `_site/` before building on it.

`notebooks/bar_race.jl` is the reference implementation: one tagged SVG per
threshold and size, hidden radio inputs, `:checked ~ sibling` selectors, CSS
transitions between resting states. The one JS exception (swipe, arrow keys,
⏸, the auto-play handover) only checks the same radios the buttons use.

The corollary: **Pluto is not a preview.** Pluto has a live Julia process and
will happily run something that then breaks on the published page. Always
confirm in `_site/`.

Verified 2026-08-31 (Bonito 5.2.0, WGLMakie 0.13.13, Pluto 1.0.3, Julia 1.12):
live WGLMakie in Pluto *does* render now — multiple plots, one stable
connection — as long as the browser is open while the cells run. It needs
Bonito ≥ 5.2.0 (the fix is Bonito#369; older Bonito froze the plots). Two traps
this hides:

- Bonito starts its own websocket server *inside the notebook's worker process*
  (default port 9384) and, with no proxy env set, hands the browser an absolute
  `ws://localhost:9384/…`. Fine on localhost; breaks behind a proxy or on a
  remote Pluto unless `Bonito.configure_server!(proxy_url=…)` is set.
- Bonito's default cleanup closes a rendered session 30 s after render if no
  browser connected. So *render-into-a-file-then-open-later* looks broken —
  blank plot, websocket closes code 1000, retries forever — while the live loop
  is fine. Keep the browser attached.

None of this softens the rule above — but the two offline paths are *not* the
same code. Pluto's own static HTML export (`generate_html` / `/notebookexport`)
bakes a live session into the statefile and renders **blank** offline
(confirmed; the long-open Makie#1343 / Bonito#123 / Pluto#1822). `Bonito.export_static`
— what `build.jl` used — takes a different route (`NoConnection` + an on-disk
asset folder, offline by design) and was **not** tested here; it may well work.
Either way, open `_site/` in a browser with no server and check the canvases
actually *paint* before trusting it. Deep dive and fix plan:
`HANDOFF-static-export.md`.

## Layout

    data/raw/         downloads, gitignored, reproducible from src/ingest
    data/processed/   tidy CSV, committed
    src/ingest/       one Pluto notebook per data source; runs as a script too
    src/lib/          shared theme and helpers
    src/calc/         standalone back-of-envelope scripts, no data, no plots
    notebooks/        one Pluto notebook per chart — the page source itself
    build_prototype.jl  renders the site into _site/ (includes the notebooks)

URL layout: `/` landing, `/hitzetage/` topic page, `/hitzetage/<slug>/` one
page per station. Slugs are short and sayable (`krems`, `wien`, `ischl`);
the rule lives in `short_slugs` in `src/ingest/heat_days_stations.jl`.

## Commands

    julia --project -e 'using Pkg; Pkg.instantiate()'
    julia --project src/ingest/heat_days_stations.jl --all   # needs internet; --refresh to bypass cache
    julia --project build_prototype.jl             # writes _site/ (what CI deploys)
    KLIMA_ONLY=krems,wien julia --project build_prototype.jl   # a few stations
    cd _site && python3 -m http.server 8000        # the only honest preview

    julia -e 'using Pluto; Pluto.run()'            # Pluto lives in the global env

## Conventions

- `data/processed/` is committed. The site must build with no network, and
  data revisions must show up as reviewable diffs. The scheduled
  `refresh-data` workflow opens a PR rather than pushing, for exactly this
  reason.
- Every chart page states its source and the retrieval date.
- One claim per page. If a chart needs two paragraphs of caveats to not
  mislead, it gets the two paragraphs. Prefer showing the counter-objection
  (e.g. urban heat island at Hohe Warte) to omitting it.
- Each chart page *is* a Pluto notebook, and `build_prototype.jl` `include`s it
  directly, so the notebook and the built site cannot drift. Cells that only
  serve development — previews, sample data, prose — are marked *skip as
  script* in Pluto, which writes them into the file inside `#=╠═╡ ... ╠═╡ =#`
  comments that a plain `include` steps over.
- Nothing that must run at build time may depend on a skipped cell. Pluto
  comments out the *dependents* of skipped cells too, so the build would
  quietly lose them. Keep the `using`/`include` cell and every definition
  unskipped, and check `julia --project build_prototype.jl` after re-arranging cells.
- The same applies, harder, to Pluto's *disabled* flag: `must_be_commented_in_file`
  is `disabled || skip_as_script || depends_on_disabled_cells ||
  depends_on_skipped_cells`. Disabling a `using` cell to switch Makie backends
  therefore deletes every definition that touches Makie from the built site,
  silently. Load both backends instead and switch with `CairoMakie.activate!()` /
  `WGLMakie.activate!()`, from a cell that uses `import`, not `using` — a
  `using` cell defines a wildcard and drags the definitions into
  `depends_on_skipped_cells`.
- Two package-management modes, on purpose. `notebooks/bar_race.jl` calls
  `Pkg.activate` and so uses the repo environment, because the chart has to
  render with the versions `build_prototype.jl` uses. `src/ingest/geosphere.jl` has no
  `Pkg.activate`, so Pluto's own package manager runs it and pins versions in
  the file; it only has to emit a CSV, and its dependencies are in
  `Project.toml` regardless for the script and CI path. Note the trigger:
  `use_plutopkg` is static analysis, and a single `Pkg.activate`/`Pkg.add`
  anywhere in a notebook switches Pluto's manager off for that notebook —
  marking the cell *skip as script* does not hide it.
- Station IDs, parameter names and similar magic values are resolved from
  provider metadata at ingest time, not hard-coded. Ambiguity is an error, not
  a silent first match.
- Page text is German; code and comments are English.

## Fabian

Quantitative macroeconomist, comfortable in Julia and in the technical
domains here (electrical engineering, building physics, HVAC). Develops
interactively in Pluto. Do not over-explain the economics or the
thermodynamics; do flag uncertainty about library APIs, which is where the
actual risk in this repo lives.
