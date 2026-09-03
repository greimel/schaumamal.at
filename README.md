# schaumamal.at

Klimawandel in Österreich, ein Thema pro Grafik, zum Herzeigen am Handy.
Julia + Makie, exported to static files, served from GitHub Pages at
**schaumamal.at**. First topic: [Hitzetage](https://schaumamal.at/hitzetage/).

This is the public source of the site. Everything the deploy needs is here;
the site builds offline from `data/processed/`.

## Layout

    data/raw/            downloads, gitignored, reproducible from src/ingest
    data/processed/      tidy CSV, committed — the site builds without network
    src/ingest/          one script per data source (GeoSphere Data Hub, geoBoundaries)
    src/lib/             shared theme and helpers
    notebooks/           one Pluto notebook per chart — the page source itself
    build_prototype.jl   renders the site into _site/ (what CI deploys)

The build writes `_site/index.html` (the landing page), `_site/hitzetage/`
(topic page) and `_site/hitzetage/<station>/` (one page per station), plus
`_site/CNAME` for the custom domain.

## Commands

    julia --project -e 'using Pkg; Pkg.instantiate()'
    julia --project src/ingest/heat_days_stations.jl --all   # needs internet; --refresh bypasses the cache
    julia --project build_prototype.jl                        # writes _site/
    KLIMA_ONLY=krems,wien julia --project build_prototype.jl  # a few stations
    cd _site && python3 -m http.server 8000                   # the only honest preview

Always confirm a chart in `_site/`, never only in Pluto: the published page
has no Julia process behind it.

## Deploying

Pushing to `main` builds the site in six slices and publishes `_site/` to the
`gh-pages` branch (`.github/workflows/deploy.yml`). One-time setup:

- GitHub → Settings → Pages: source `gh-pages`, custom domain `schaumamal.at`,
  enforce HTTPS once the certificate is issued.
- At the registrar: `A`/`AAAA` records for the apex pointing at GitHub Pages,
  `CNAME www → greimel.github.io.`
- `hitzetage.at` forwards to `https://schaumamal.at/hitzetage/`.

## Data

Temperature series: GeoSphere Austria Data Hub, dataset `klima-v2-1d`,
parameter `tlmax`. Borders: geoBoundaries (CC BY 4.0). The scheduled
`refresh-data` workflow opens a pull request with new data rather than
pushing, so revisions to historical values get looked at.

Written with Claude Fable 5.
