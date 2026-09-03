#!/usr/bin/env julia
"""
The heat-days site, fully static.

    julia --project build_prototype.jl
    cd _site && python3 -m http.server 8000

Index: SVG map of Austria (Bundesländer + country outline), every station
with a page is clickable, no labels; below it the year's ranking — the five
stations with the most and the fewest hot days so far, per threshold. Per
station: the reel from `notebooks/reel.jl` for ≥ 25/30/35 °C (hidden-radio
CSS switcher), the four numbers below it, and the method notes.

The chart is the notebook's: this file `include`s it and composes its pieces
(`reel_box_html`, `reel_css`, `reel_script`), so the preview page and the
site cannot drift. Everything on a station page comes from
`heat_days.csv` (one row per station-year) — no daily data, no
AlgebraOfGraphics, which is what lets the build fit the 7 GB CI runner.

The only JavaScript: the station finder on the index (geolocation cannot be
pre-rendered) and the reel's tap/swipe/keyboard helper, both progressive.

Dev shortcut: KLIMA_ONLY=krems,wien limits the station loop.

CI builds in slices, each in its own process (resident memory grows per
station and is not returned on Linux — see DIARY 2026-09-01):

    KLIMA_CHUNK=i/n   build stations i, i+n, i+2n, … into an existing _site,
                      write no index
    KLIMA_INDEX=1     write style.css and the index from the station pages
                      actually present on disk, and fail if any is missing

With no variable set the build does everything in one process.
"""

# The chart notebook: CairoMakie, the reel's data frame per station, the
# tagged SVGs, the reel CSS/HTML/JS. It includes `bar_race.jl` for the SVG
# helpers; both files' dev-only cells are commented out and their entry
# points guarded by PROGRAM_FILE, so nothing is generated at include time.
# It also activates the project and includes src/lib/{theme,terms,windows}.jl.
include(joinpath(@__DIR__, "notebooks", "reel.jl"))
CairoMakie.activate!()

using Chain, DataFrameMacros

const SITE = joinpath(@__DIR__, "_site")

# Where the site lives and where this topic sits under it. The build writes
# _site/CNAME, so GitHub Pages serves the gh-pages branch at the apex domain;
# pages carry a canonical link to the same address.
const DOMAIN   = "schaumamal.at"
const SITE_URL = "https://" * DOMAIN
const TOPIC    = "hitzetage"
const PROC = joinpath(@__DIR__, "data", "processed")
const THRESHOLDS = [25, 30, 35]
const DEFAULT_THRESHOLD = 30

# ------------------------------------------------------------------ map

const TIER_STYLE = Dict(
    "platin" => ("#546e7a", 6.5, "seit 1900 oder früher"),
    "gold"   => ("#c9a227", 5.5, "1901–1925"),
    "silber" => ("#9e9e9e", 4.5, "1926–1950"),
    "bronze" => ("#b07d4f", 3.5, "1951–1970"),
)
const TIER_ORDER = ["platin", "gold", "silber", "bronze"]

"""
Hand-written SVG map: Bundesländer, country outline, one dot per qualifying
station. Dots with a page are links (hover ring, pointer); every dot carries
a `<title>`. No text labels — the map would drown in them.

The hover labels live in ONE group at the very end of the SVG, not inside
their `<a>`: SVG paints in document order and knows no z-index, so a label
inside its link was overprinted by every dot drawn later. A sibling rule per
station (`a[data-s]:hover ~ .labels text[data-s]`), emitted as a `<style>`
inside the SVG, shows the right label — on top of everything, still no JS.
"""
function map_svg(stations, laender, border, has_page; width = 940)
    lon0, lon1 = extrema(border.lon)
    lat0, lat1 = extrema(border.lat)
    k = cosd((lat0 + lat1) / 2)
    pad = 14
    s = (width - 2pad) / ((lon1 - lon0) * k)
    height = ceil(Int, 2pad + (lat1 - lat0) * s)
    X(lon) = round(pad + (lon - lon0) * k * s; digits = 1)
    Y(lat) = round(pad + (lat1 - lat) * s; digits = 1)
    poly(df, class) = join(
        ["<polygon class=\"$class\" points=\"" *
         join(["$(X(r.lon)),$(Y(r.lat))" for r in eachrow(g)], " ") * "\"/>"
         for g in groupby(df, :ring)], "\n")

    io, labels, rules = IOBuffer(), IOBuffer(), IOBuffer()
    # Not role="img": that would make the 138 station links presentational
    # for screen readers. The Bundesland list is the equivalent path.
    print(io, "<svg class=\"map\" viewBox=\"0 0 $width $height\" role=\"group\" ",
          "aria-label=\"Karte der Wetterstationen in Österreich\">\n",
          poly(DataFrame(laender), "land"), "\n",
          poly(DataFrame(border), "border"), "\n")
    for st in sort(DataFrame(stations), :from_year, rev = true) |> eachrow
        color, r, _ = TIER_STYLE[st.tier]
        x, y = X(st.lon), Y(st.lat)
        if st.slug in has_page
            # Instant hover: a CSS-shown <text> instead of the browser's slow
            # native <title> tooltip, plus an invisible larger hit circle.
            label = "$(st.name) — seit $(st.from_year)"
            anchor = x > width - 170 ? "end" : x < 170 ? "start" : "middle"
            ly = y < 42 ? y + r + 18 : y - r - 8
            print(io, "<a href=\"$(st.slug)/\" data-s=\"$(st.slug)\" aria-label=\"$(st.name)\">",
                  "<circle class=\"hit\" cx=\"$x\" cy=\"$y\" r=\"10\"/>",
                  "<circle class=\"dot\" cx=\"$x\" cy=\"$y\" r=\"$r\" fill=\"$color\"/>",
                  "</a>\n")
            print(labels, "<text class=\"hlabel\" data-s=\"$(st.slug)\" x=\"$x\" y=\"$ly\" ",
                  "text-anchor=\"$anchor\">$label</text>\n")
            print(rules, ".map a[data-s=\"$(st.slug)\"]:hover ~ .labels text[data-s=\"$(st.slug)\"], ",
                  ".map a[data-s=\"$(st.slug)\"]:focus ~ .labels text[data-s=\"$(st.slug)\"] { display: block; }\n")
        else
            print(io, "<g class=\"nopage\"><circle class=\"dot\" cx=\"$x\" cy=\"$y\" r=\"$r\" ",
                  "fill=\"$color\"/><title>$(st.name) — seit $(st.from_year)</title></g>\n")
        end
    end
    print(io, "<g class=\"labels\">\n", String(take!(labels)), "</g>\n",
          "<style>\n", String(take!(rules)), "</style>\n</svg>\n")
    String(take!(io))
end

# ------------------------------------------------------------------ html

# Headline is Radlberger's "Ein Sommer wie damals" verbatim — a slogan most
# people in Austria can finish themselves — with a question mark. The lead
# answers it: yes, like the *extreme* ones back then. That is the normal one
# now. Conceding the memory first is the point (the objection is factually
# right: 1947 and 1983 ARE the record years in our own data); see DIARY
# 2026-09-01. It is also the weather services' own line — DWD/MeteoSchweiz/
# ZAMG 2020: "Aus extrem wurde normal."
const KICKER   = "Hitzetage in Österreich"
const HEADLINE = "Ein Sommer wie damals?"
const LEAD     = "Sommer, die früher extrem waren, sind heute normal. " *
                 "Schau dir eine Wetterstation in deiner Nähe an."

# Public source repository (this one). `nothing` would drop the link from the
# footer; the private working repo with the planning notes is not linked.
const SOURCE_URL = "https://github.com/greimel/schaumamal.at"

# Fabian's public profile, for the footer on every page — GitHub only, no
# personal website (his call, 2026-09-03).
const AUTHOR_GITHUB = "https://github.com/greimel"

# Anonymous visit counter (GoatCounter): no cookies, no persistent
# identifier, no consent banner needed, and it counts per path — so
# per-station numbers come for free. `nothing` removes the snippet entirely.
# The code must be registered at goatcounter.com before anything is counted
# (the dashboard then lives at https://<code>.goatcounter.com); until then
# the script 404s silently and the pages work as before. GoatCounter's
# script does not count localhost, so the honest preview stays clean.
const GOATCOUNTER = "klimacharts"

const MONTHS_DE_FULL = ["Jänner", "Februar", "März", "April", "Mai", "Juni", "Juli",
                        "August", "September", "Oktober", "November", "Dezember"]
fmt_date(d::Date) = "$(day(d)). $(MONTHS_DE_FULL[month(d)]) $(year(d))"
"German decimal comma."
fmt_num(x; digits = 1) = replace(string(round(x; digits)), "." => ",")

const STATE_ORDER = ["Burgenland", "Kärnten", "Niederösterreich", "Oberösterreich",
                     "Salzburg", "Steiermark", "Tirol", "Vorarlberg", "Wien"]

const CSS = """
/* --------------------------------------------------------------- base */
:root {
  --ink: #1c1b19; --muted: #6d6a64; --rule: #e6e1d8; --paper: #fff;
  --soft: #faf8f4; --accent: #a63d2a; --link: #1b6ca8;
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--paper); color: var(--ink); line-height: 1.55;
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  -webkit-text-size-adjust: 100%; }
main { max-width: 960px; margin: 0 auto; padding: 40px 20px 80px; }
a { color: var(--link); }

/* --------------------------------------------------------------- head */
.kicker { margin: 0 0 6px; font-size: 12px; letter-spacing: 0.12em;
  text-transform: uppercase; color: var(--muted); font-weight: 600; }
.kicker a { color: inherit; text-decoration: none; }
.kicker a:hover { text-decoration: underline; }
h1 { margin: 0 0 10px; font-size: clamp(1.9rem, 5.5vw, 2.9rem); line-height: 1.12;
  letter-spacing: -0.02em; font-weight: 700; }
h2 { margin: 0 0 6px; font-size: 1.25rem; letter-spacing: -0.01em; }
.lead { margin: 0 0 4px; font-size: clamp(1.02rem, 2.3vw, 1.2rem); color: #3b3935;
  max-width: 34em; }
.sub { margin: 0; color: var(--muted); font-size: 15px; }

/* data currency — small, but always above the fold */
.stand { display: flex; flex-wrap: wrap; gap: 8px 10px; margin: 18px 0 0;
  padding: 0; list-style: none; font-size: 13px; }
.stand li { background: var(--soft); border: 1px solid var(--rule);
  border-radius: 999px; padding: 4px 12px; color: var(--muted); }
.stand b { color: var(--ink); font-weight: 600; }

/* ------------------------------------------------------------- finder */
.finder { margin: 30px 0 8px; padding: 18px 18px 16px; background: var(--soft);
  border: 1px solid var(--rule); border-radius: 12px; }
.finder h2 { margin: 0 0 4px; font-size: 1.05rem; }
.finder p { margin: 0; color: var(--muted); font-size: 14px; }
.finder .row { display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0 8px; }
.finder button, .finder input {
  font: inherit; font-size: 15px; padding: 9px 14px; border-radius: 8px;
  border: 1px solid #cfc8bc; background: var(--paper); color: var(--ink); }
.finder button { cursor: pointer; font-weight: 600; border-color: var(--ink);
  background: var(--ink); color: #fff; }
.finder button:hover { background: #383632; }
.finder input { flex: 1 1 240px; min-width: 0; }
.finder .out { margin-top: 6px; font-size: 15px; color: var(--ink); min-height: 1.5em; }
.finder .out a { font-weight: 600; }
.finder .privacy { margin-top: 8px; font-size: 12.5px; }

/* --------------------------------------------------- threshold tabs */
.panelbox { margin-top: 26px; }
.panelbox > input, .rankbox > input { position: absolute; opacity: 0; pointer-events: none; }
.tabs { display: flex; gap: 8px; margin: 0 0 10px; flex-wrap: wrap; }
.tabs label { padding: 7px 14px; border: 1px solid var(--rule); border-radius: 10px;
  cursor: pointer; font-size: 14px; font-weight: 600; background: var(--paper);
  user-select: none; line-height: 1.25; text-align: center; }
.tabs label span { display: block; font-size: 11.5px; font-weight: 500; opacity: 0.65; }
.tabs label:hover { background: var(--soft); }
$(join(["""
#th-$t:checked ~ .tabs label[for="th-$t"],
#rk-$t:checked ~ .tabs label[for="rk-$t"] { background: var(--ink); border-color: var(--ink); color: #fff; }
""" for t in THRESHOLDS]))

/* the numbers, below the chart */
.statlead { margin: 0 0 10px; font-size: 14px; color: var(--muted); }
.stats { display: grid; gap: 10px; margin: 0 0 6px;
  grid-template-columns: repeat(auto-fit, minmax(132px, 1fr)); }
.stat { border: 1px solid var(--rule); border-radius: 10px; padding: 12px 14px; }
.stat .k { display: block; font-size: 12px; color: var(--muted); }
.stat .v { display: block; font-size: 1.75rem; font-weight: 700; line-height: 1.15;
  font-variant-numeric: tabular-nums; letter-spacing: -0.02em; }
.stat .u { display: block; font-size: 12px; color: var(--muted); }
.stat.now { border-color: var(--accent); }
.stat.now .v { color: var(--accent); }
.muted { color: var(--muted); }
.statbox { display: none; margin-top: 22px; }
.claim { margin: 16px 0 0; max-width: 40em; font-size: 16.5px; line-height: 1.5; }
.claim.national { margin-top: 10px; }
$(join(["#th-$t:checked ~ .statbox-$t { display: block; }\n" for t in THRESHOLDS]))

.reelbox { margin-top: 26px; }

$(reel_css(; thresholds = THRESHOLDS))

/* ---------------------------------------------------------------- map */
.map { width: 100%; height: auto; display: block; margin-top: 6px; }
.map .land { fill: #f4f1ec; stroke: #cfc7ba; stroke-width: 0.8; }
.map .border { fill: none; stroke: #8a8175; stroke-width: 1.2; }
.map .dot { stroke: #fff; stroke-width: 1; }
.map a { cursor: pointer; }
.map a .hit { fill: transparent; }
.map a .dot { stroke: #555; stroke-width: 1.2; }
.map a:hover .dot, .map a:focus .dot { stroke: #111; stroke-width: 2.5; r: 8px; }
.map .hlabel { display: none; font-size: 13px; font-weight: 600; fill: #111;
  paint-order: stroke; stroke: #fff; stroke-width: 3.5px; pointer-events: none; }
/* which label shows: per-station sibling rules in a <style> inside the SVG */
.map .nopage .dot { opacity: 0.55; }
.legend { display: flex; gap: 16px; flex-wrap: wrap; font-size: 13px;
  color: var(--muted); margin: 4px 0 0; align-items: center; }
.legend .dot { display: inline-block; width: 11px; height: 11px;
  border-radius: 50%; margin-right: 5px; vertical-align: -1px; }

/* ------------------------------------------------------- this year's ranking */
.rankbox { margin-top: 34px; position: relative; }
.rankbox h2 { margin-bottom: 10px; }
.nclaim { display: none; }
$(join(["#rk-$t:checked ~ .nclaim-$t { display: block; }\n" for t in THRESHOLDS]))
.rankbox .nclaim .claim { margin-top: 4px; }
.rank { display: none; }
$(join(["#rk-$t:checked ~ .rank-$t { display: grid; }\n" for t in THRESHOLDS]))
.rank { grid-template-columns: repeat(auto-fit, minmax(270px, 1fr)); gap: 12px 28px; }
.rank h3 { margin: 0 0 4px; font-size: 13px; letter-spacing: 0.06em;
  text-transform: uppercase; color: var(--muted); }
.rank ol { margin: 0; padding: 0; list-style: none; }
.rank li { display: flex; align-items: baseline; gap: 10px; font-size: 15px;
  line-height: 1.75; border-top: 1px solid var(--rule); }
.rank li:first-child { border-top: 0; }
.rank .n { flex: none; width: 4.8em; text-align: right; font-weight: 700;
  font-variant-numeric: tabular-nums; white-space: nowrap; }
.rank .n small { font-weight: 400; color: var(--muted); font-size: 12px; }
.rank .who { flex: 1; min-width: 0; }
.rank .where { color: var(--muted); font-size: 12.5px; white-space: nowrap; }
.rank .more { color: var(--muted); font-size: 13px; }
.rank .more .n { visibility: hidden; }
.rankbox .note { margin: 10px 0 0; font-size: 13px; color: var(--muted); }

/* --------------------------------------------------- station listing */
.lgroup { margin: 14px 0; }
.lgroup h3 { margin: 0 0 4px; font-size: 13px; letter-spacing: 0.06em;
  text-transform: uppercase; color: var(--muted); }
.lgroup ul { margin: 0; padding: 0; list-style: none;
  columns: 3 190px; column-gap: 22px; }
.lgroup li { break-inside: avoid; font-size: 14.5px; line-height: 1.75; }
.lgroup li span { color: var(--muted); font-size: 12.5px; }

/* ------------------------------------------------- collapsible detail */
.box { border-top: 1px solid var(--rule); }
.details-wrap .box:last-of-type { border-bottom: 1px solid var(--rule); }
.box > summary { cursor: pointer; padding: 14px 2px; font-weight: 600;
  font-size: 15px; list-style: none; display: flex; align-items: center; gap: 8px; }
.box > summary::-webkit-details-marker { display: none; }
.box > summary::before { content: "+"; color: var(--muted); font-weight: 400;
  font-size: 18px; width: 14px; }
.box[open] > summary::before { content: "–"; }
.box > summary:hover { color: var(--accent); }
.boxbody { padding: 0 2px 18px 24px; font-size: 14.5px; color: #3b3935;
  max-width: 42em; }
.boxbody p { margin: 0 0 0.85em; }
.boxbody p:last-child { margin-bottom: 0; }
.boxbody dt { font-weight: 600; margin-top: 0.7em; }
.boxbody dd { margin: 0; color: var(--muted); }
.details-wrap { margin-top: 34px; }
footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--rule);
  font-size: 13px; color: var(--muted); }
footer p { margin: 0; max-width: 52em; }
footer a { color: inherit; }
"""

# `root` is the relative path back to the site root ("" on the index,
# "../../" on station pages). Relative on purpose: the site must work at a
# domain root (schaumamal.at) and under a project-pages subpath alike.
"""
The footer every page shares: whose project this is, who built it, where the
source will live (`SOURCE_URL` flips the wording once the public repo
exists) and what the counter does — the whole privacy story in one line.
"""
function site_footer()
    src = SOURCE_URL === nothing ?
        "Der Quellcode wird als öffentliches Repository auf GitHub veröffentlicht." :
        """Quellcode: <a href="$SOURCE_URL">$(replace(SOURCE_URL, r"^https://" => ""))</a>."""
    counter = GOATCOUNTER === nothing ? "" :
        """ Besuche werden anonym gezählt — ohne Cookies und ohne persönliche Daten
        (<a href="https://www.goatcounter.com" rel="noopener">GoatCounter</a>)."""
    """
<footer>
<p>Ein Projekt von <a href="$AUTHOR_GITHUB" rel="noopener">Fabian Greimel</a> — gebaut von
<a href="https://claude.com/claude-code" rel="noopener">Claude&nbsp;Code</a>.
$src$counter</p>
</footer>"""
end

"""
The GoatCounter snippet, at the very end of the body. The script counts one
pageview per visit under `location.pathname`, so station pages land under
/hitzetage/<slug>/ and the dashboard groups by station with no extra wiring;
`path` only feeds the no-JavaScript fallback pixel.
"""
counter_html(path) = GOATCOUNTER === nothing ? "" :
    """
<script data-goatcounter="https://$GOATCOUNTER.goatcounter.com/count" async src="https://gc.zgo.at/count.js"></script>""" *
    (path === nothing ? "" : """
<noscript><img src="https://$GOATCOUNTER.goatcounter.com/count?p=$path" alt=""></noscript>""")

page(title, body; root = "", description = "", script = "", path = nothing) = """
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<meta name="description" content="$description">
$(path === nothing ? "" : "<link rel=\"canonical\" href=\"$SITE_URL$path\">")
<link rel="stylesheet" href="$(root)style.css">
</head>
<body>
<main>
$body
$(site_footer())
</main>
$script$(counter_html(path))
</body>
</html>
"""

"The two dates the reader needs to trust the page, as pills near the top."
stand_bar(until, updated) = """
<ul class="stand">
<li><b>Daten bis</b> $until</li>
<li><b>Aktualisiert</b> $(fmt_date(updated))</li>
</ul>"""

collapsible(summary, body) =
    "<details class=\"box\"><summary>$summary</summary><div class=\"boxbody\">$body</div></details>"

# ------------------------------------------------------------- numbers

"Early vs. recent average and the record year — the tiles below the chart."
function station_stats(w, threshold)
    col = Symbol("days_ge_", threshold)
    d = w.all
    i = findlast(==(maximum(d[!, col])), d[!, col])
    (; e_span = w.e_span, e_mean = mean(w.e[!, col]),
       l_span = w.l_span, l_mean = mean(w.l[!, col]),
       rec_year = d.year[i], rec_days = d[i, col])
end

"""
The sentence under the tiles that says what the reel shows *here*, in prose:
the year with the most days, how many of the last 30 years beat it, and —
from eight on — that what was an exception is nothing special any more. The
word „Rekord" appears nowhere on the page (Fabian, 2026-09-03). The same words and the
same strict count as the subtitles (`reel_captions`): a year has to have
*more* such days than the old record; a tie stays grey and is not counted.
The count runs over every year of the late window, gaps included (a year
with gaps can only be too low). Wording settled with Fabian, DIARY
2026-09-01 (Abend) and 2026-09-03.

A record of zero — no such day in the early window at all, 55 stations at
35 °C — turns the record year into the day: how many of the last 30 years
had one. Ties of any size are named. Every case has words; nothing here can
fail a build.
"""
function local_claim(w, annual, t, late)
    col = Symbol("days_ge_", t)
    plural, sing = day_term_plain(t), day_term_sing(t)
    span = w.kind == :reference ?
        "zwischen $(first(REF_WINDOW)) und $(last(REF_WINDOW))" :
        "zwischen $(minimum(w.e.year)) und $(maximum(w.e.year))"
    since = "Seit $(w.since)"
    rl = race_line(w, t)                 # the reel's line: same rule, same numbers
    rec, years = rl.rec, rl.rec_years
    l0, l1 = w.kind == :reference ? (first(late), last(late)) : extrema(w.l.year)
    n = count(>(rec), annual[l0 .<= annual.year .<= l1, col])
    if rec > 0
        yrs = join_de(years)
        s1 = "Die meisten $plural $span gab es $yrs: " * (length(years) == 1 ? "" : "je ") * "$rec."
        s2 = n == 0 ? "$since war kein Jahr extremer als $yrs." :
             n == 1 ? "$since war ein Jahr extremer als $yrs." :
                      "$since waren schon $(num_de(n)) Jahre extremer als $yrs."
        s3 = n >= 8 ? " Was früher eine Ausnahme war, ist heute nichts Besonderes mehr." :
             n >= 3 ? " Was früher eine Ausnahme war, ist heute keine Seltenheit mehr." : ""
    else
        s1 = "$(uppercasefirst(span)) gab es keinen einzigen $sing."
        s2 = n == 0 ? "$since auch keinen." :
             n == 1 ? "$since gab es in einem Jahr einen." :
                      "$since gab es in $(num_de(n)) Jahren welche."
        s3 = n >= 8 ? " Ein $sing ist heute nichts Besonderes mehr." :
             n >= 3 ? " Ein $sing ist heute keine Seltenheit mehr." : ""
    end
    s1 * " " * s2 * s3
end

"""
The one sentence that turns 138 pages into a climate statement: the same
shift everywhere at once, over thirty years, at every threshold — which is
what separates climate from a hot summer, without saying so. Counted over
the stations with both windows, by days: "mehr" means more days in the last
30 years (1997–2026, the running year as far as it goes) than in 1961–1990.
Means, for the factors, use complete years only.

The wording per threshold is written by hand for the numbers as they are,
and every adjective is asserted against the numbers it describes — so a data
refresh that outgrows the words fails the build instead of shipping a stale
claim. The one deliberate exception per threshold (four stations with one or
two days fewer at 35 °C; the summits that never had a day) stays in the
sentence: whoever looks for the counter-example finds it here first.
"""
function national_claims(annual_all, mapst, late)
    running = year(today())
    altitude = Dict(String(r.name) => r.altitude for r in eachrow(mapst))
    complete = @subset(annual_all, :complete && :year != running)
    groups = groupby(complete, :station_name)
    byname = Dict(String(first(g.station_name)) => g for g in groupby(annual_all, :station_name))
    has_windows(g) = count(in(REF_WINDOW), g.year) >= WINDOW_MIN && count(in(late), g.year) >= WINDOW_MIN
    n_short = count(g -> nrow(g) >= 20 && !has_windows(g), groups)
    ref = "$(first(REF_WINDOW))–$(last(REF_WINDOW))"
    claims, more = Dict{Int,String}(), Dict{Int,Set{String}}()
    n_all = 0
    for t in THRESHOLDS
        col = Symbol("days_ge_", t)
        rows = []
        for g in groups
            has_windows(g) || continue
            name = String(first(g.station_name))
            e = @subset(g, :year in REF_WINDOW)
            l = @subset(g, :year in late)                 # complete years: the means
            lall = @subset(byname[name], :year in late)   # every row: the sums
            push!(rows, (; station = name,
                           sE = sum(e[!, col]), sL = sum(lall[!, col]),
                           mE = mean(e[!, col]), mL = mean(l[!, col]),
                           ever = sum(byname[name][!, col]) > 0))
        end
        r = DataFrame(rows)
        n = nrow(r)
        n_all = n
        up, down, same = r[r.sL .> r.sE, :], r[r.sL .< r.sE, :], r[r.sL .== r.sE, :]
        zero, same_pos = same[same.sE .== 0, :], same[same.sE .> 0, :]
        more[t] = Set(up.station)
        # factor per year; from nothing to something satisfies any factor
        ratio(x) = x.sE == 0 ? Inf : x.mL / x.mE
        share(f) = count(f, eachrow(up)) / nrow(up)
        check(ok, words) = ok || error("country-wide sentence at $t °C: the words „$(words)“ no longer fit the data")
        plural = day_term_plain(t)
        head = "An $(nrow(up)) von $n Stationen gibt es seit $(first(late)) mehr $plural als $ref"
        # "nie" only if the whole record agrees — Patscherkofel had four
        # Sommertage in 1957, before the reference window
        none(zero) = any(zero.ever) ? "hatten damals wie heute keinen" : "hatten nie einen"
        claims[t] = if t == 30
            check(nrow(down) == 0 && nrow(same_pos) == 0, "an keiner einzigen wurden es weniger")
            check(nrow(zero) >= 2, "die übrigen")
            check(all(altitude[s] > 1400 for s in zero.station), "hoch im Gebirge")
            check(share(x -> ratio(x) > 2) >= 0.75, "meist mehr als doppelt so viele")
            check(0.40 <= share(x -> ratio(x) >= 3) < 0.55, "an fast jeder zweiten dreimal so viele")
            "$head — meist mehr als doppelt so viele, an fast jeder zweiten dreimal so viele. " *
            "(Die übrigen $(num_de(nrow(zero))) liegen hoch im Gebirge und $(none(zero)).) " *
            "An keiner einzigen wurden es weniger. So sieht Klimawandel aus."
        elseif t == 25
            check(nrow(down) == 0 && nrow(same_pos) == 0, "an keiner einzigen wurden es weniger")
            check(nrow(zero) >= 2, "die übrigen")
            check(share(x -> ratio(x) >= 4 / 3) >= 0.75, "meist um ein Drittel mehr")
            check(0.45 <= share(x -> ratio(x) >= 1.5) < 0.60, "an jeder zweiten um die Hälfte")
            "$head — meist um ein Drittel mehr, an jeder zweiten um die Hälfte. " *
            "(Die übrigen $(num_de(nrow(zero))) $(none(zero)).) " *
            "An keiner einzigen wurden es weniger. So sieht Klimawandel aus."
        elseif t == 35
            check(nrow(down) >= 2 && all(1 .<= down.sE .- down.sL .<= 2), "an vier sind es ein oder zwei Tage weniger")
            check(nrow(zero) >= 2, "damals wie heute nicht")
            check(share(x -> ratio(x) >= 3) >= 0.75, "meist mehr als dreimal so viele")
            same_txt = nrow(same_pos) == 0 ? "" : ", an $(num_de(nrow(same_pos))) gleich viele"
            "$head, an $(num_de(nrow(down))) sind es ein oder zwei Tage weniger. " *
            "(An $(num_de(nrow(zero))) gab es solche Tage damals wie heute nicht$same_txt.) " *
            "Wo es mehr wurden, sind es meist mehr als dreimal so viele. So sieht Klimawandel aus."
        else
            error("no country-wide wording for $t °C")
        end
    end
    (; late, late_span = "$(first(late))–$(last(late))", claims, more, n = n_all, n_short)
end

"""
How the country-wide sentence opens on a station page: "dasselbe" when this
station is one of the "mehr", "anders" when it is not — then the reader finds
their own station in the sentence's exception, on exactly the page where it
belongs. The decision uses the same windows and the same count (days) as the
sentence, and is asserted against it, so a page cannot contradict itself.
"""
function station_up(st, w, annual, t, nat)
    col = Symbol("days_ge_", t)
    if w.kind == :reference
        # 30 calendar years against 30: the country-wide sentence's own sum
        # rule, and asserted against its count.
        up = sum(annual[in.(annual.year, Ref(nat.late)), col]) > sum(w.e[!, col])
        (String(st.name) in nat.more[t]) == up ||
            error("opener disagrees with the country-wide count: $(st.name), $t °C")
        return up
    end
    # Fallback windows can hold very different numbers of years (Güssing: 35
    # early, 17 late), and a raw sum then calls a station with twice the days
    # per year "anders" (Enns, Horn, Güssing at 25 °C). Compare days per year.
    late = annual[in.(annual.year, Ref(nat.late)), :]
    sum(late[!, col]) / length(unique(late.year)) > sum(w.e[!, col]) / nrow(w.e)
end

function national_opener(st, w, annual, t, nat)
    w === nothing && return "Im restlichen Österreich:"
    station_up(st, w, annual, t, nat) ? "In ganz Österreich dasselbe:" :
        "Im restlichen Österreich sieht das anders aus:"
end

"""
Beat 1 of the flat story: the two window sums, plainly — „Von 1961–1990 gab
es 1 Tag ab 35 Grad. · Von 1997–2026 gab es keinen." The numbers are exactly
the two sums `station_up` compares (late = every row, the running year as
far as it goes), so the sentence cannot contradict the classification. The
spans wear the colours of their bands.
"""
function flat_beat1(w, annual, t, nat)
    col = Symbol("days_ge_", t)
    late = annual[in.(annual.year, Ref(nat.late)), :]
    x = Int(sum(w.e[!, col]))
    y = Int(sum(late[!, col]))
    # Unequal windows exaggerate a sum comparison when the late side is the
    # shorter one; with y = 0, more early years only weaken the claim. A
    # missing late year or two is the site's normal gap convention (Seckau:
    # 28 of 30 — honest), so the tripwire fires only on Güssing-scale
    # imbalance: word that case before it ships rather than mislead.
    y == 0 || length(unique(late.year)) >= 0.8 * nrow(w.e) ||
        error("flat beat 1 at $t °C compares unequal windows with a nonzero late sum: $(w.e_span) vs $(w.l_span)")
    plural, sing = reel_plural(t), reel_sing(t)
    e, l = hl("old", w.e_span), hl("hot", w.l_span)
    a = x == 0 ? "Von $e gab es keinen einzigen " * bb(sing) * "." :
        x == 1 ? "Von $e gab es " * bb("1 $sing") * "." :
                 "Von $e gab es " * bb("$x $plural") * "."
    b = y == 0 ? (x == 0 ? "⏎Von $l auch keinen." : "⏎Von $l gab es keinen.") :
        y == 1 ? "⏎Von $l gab es einen." :
                 "⏎Von $l gab es $y."
    (a, b, "")
end

tile(k, v, u; cls = "") =
    """<div class="stat $cls"><span class="k">$k</span><span class="v">$v</span><span class="u">$u</span></div>"""

function stat_block(st, w, annual, t, nat)
    col = Symbol("days_ge_", t)
    lauf = @subset(annual, :year == year(today()))
    run_days = nrow(lauf) == 1 ? only(lauf[!, col]) : nothing
    head = """<p class="statlead">$(day_term(t)) in $(st.name) — Tage, an denen es
              mindestens $t °C hatte</p>"""
    # The reel's last frame already says „So sieht Klimawandel aus." — the word
    # falls once per page, so the prose version here ends before it.
    claim = replace(nat.claims[t], " So sieht Klimawandel aus." => "")
    nat_p = """<p class="claim national">$(national_opener(st, w, annual, t, nat)) $claim</p>"""
    w === nothing && return head *
        """<p class="muted">Zu wenige vollständige Messjahre für einen Vergleich.</p>""" * nat_p
    s = station_stats(w, t)
    # Never reached at all: the chart panel says so in one sentence. No tiles,
    # no local sentence — but the country-wide one, which is this page's point.
    s.rec_days == 0 && something(run_days, 0) == 0 && return nat_p
    tiles = [tile("Ø $(s.e_span)", fmt_num(s.e_mean), "Tage pro Jahr"),
             tile("Ø $(s.l_span)", fmt_num(s.l_mean), "Tage pro Jahr"),
             tile("Höchstwert $(s.rec_year)", s.rec_days, "Tage")]
    if run_days !== nothing
        # Otherwise "Rekordjahr 2015: 43" next to "2026 bisher: 51" reads as the
        # page contradicting itself. The record counts finished years only.
        # Below the record, the rank — on the same rule as the chart's sorted
        # view (at or above the line, rank 2 … RANK_MAX), so tile and chart agree.
        rank = year_rank(run_days, annual[annual.year .!= year(today()), col])
        u = run_days > s.rec_days ? "Tage — mehr als in jedem vollen Jahr" :
            (run_days > race_line(w, t).line && 2 <= rank <= RANK_MAX) ?
                "Tage — die $(ordinal_de(rank))meisten seit $(minimum(annual.year))" : "Tage"
        push!(tiles, tile("$(year(today())) bisher", run_days, u; cls = "now"))
    end
    head * "<div class=\"stats\">" * join(tiles) * "</div>" *
        """<p class="claim local">$(local_claim(w, annual, t, nat.late))</p>""" * nat_p
end

source_note() = SOURCE_URL === nothing ?
    """<p>Der Quellcode der Auswertung — Datenabruf, Aufbereitung und das
       Zeichnen der Diagramme — wird als eigenes öffentliches Repository
       veröffentlicht, sobald er aufgeräumt ist.</p>""" :
    """<p>Quellcode der Auswertung: <a href="$SOURCE_URL">$SOURCE_URL</a>.</p>"""

const METHOD_HTML = """
<p>Ein Tag zählt, wenn das <em>Tagesmaximum der Lufttemperatur</em> die Schwelle
erreicht. In Österreich heißt ein Tag ab 25 °C <em>Sommertag</em>, ab 30 °C
<em>Hitzetag</em> und ab 35 °C <em>extrem heißer Tag</em> oder
<em>35-Grad-Tag</em>. Der geläufige <em>Wüstentag</em> ist keine amtliche
Bezeichnung. Beim Vergleich mit deutschen Zahlen aufpassen: dort heißt derselbe
Tag <em>sehr heißer Tag</em>, und <em>extrem heiß</em> beginnt erst bei 40 °C.</p>
<p>Die Messreihen sind zusammengeführte Langzeitreihen: Wird eine Station
verlegt, führt der Datenhub die alte und die neue Messung als eine Reihe
weiter. Das hält die Reihe lang, kann aber Sprünge verursachen.</p>
<p>Das Diagramm zeigt alle Messjahre, am Handy zunächst die ab 1961. Ein Jahr
zählt nur, wenn sein Sommer — Juni bis August — lückenlos gemessen ist: fast
alle Tage, die diese Seite zählt, fallen in diese Monate, und ein Loch im Juli
sähe wie ein kühles Jahr aus. Jahre ohne lückenlosen Sommer erscheinen als
schraffierte Messlücke, nicht als zu niedriger Balken. Das laufende Jahr ist
umrahmt und heißt „bisher": Es zählt, solange sein Sommer bisher keine Lücke
hat — ihm fehlen keine Daten, es ist nur noch nicht vorbei.</p>
<p>Die Angabe „Messbeginn" stammt aus den Metadaten des Datenhubs. Bei manchen
Stationen setzt die durchgehende Temperaturmessung später ein als der dort
genannte Beginn.</p>
"""

"""
The method block, with the paragraph the interpretation sentences need: which
windows, what "mehr" means, why 105 and not 138 — and, for the reader who
knows record statistics, why an "Ausnahmejahr" recurring twelve times means
something (under no change the record of thirty years is matched about once
in the next thirty).
"""
method_html(nat) = METHOD_HTML * """
<p>Die Zahlen unter dem Diagramm stellen $(first(REF_WINDOW))–$(last(REF_WINDOW)) — die
Vergleichsperiode der Wetterdienste — den letzten 30 Jahren gegenüber, derzeit
$(nat.late_span); das laufende Jahr zählt mit, soweit es schon da ist. Beide Zeiträume
brauchen mindestens $WINDOW_MIN vollständige Jahre — vollständig heißt: Juni bis August
lückenlos gemessen —, und die Durchschnitte zählen nur vollständige Jahre. Beginnt eine
Reihe erst nach 1961, rückt ihr früher Zeitraum entsprechend nach — längstens bis 1996 —,
damit es 30 Jahre werden; der Text nennt die Jahre. Wo das
Vergleichsfenster fehlt, vergleicht die Seite die spätesten vollständigen Jahre bis 1990
mit den verfügbaren Jahren seit $(first(nat.late)), und der Text nennt diese Jahre.
„Mehr" heißt: mehr Tage im späteren Zeitraum als im früheren.
Der Österreich-Satz zählt die $(nat.n) Stationen, die beide Zeiträume abdecken;
$(nat.n_short) weitere Reihen sind dafür zu kurz oder zu lückenhaft.</p>
<p>Zum Höchstwert: Bliebe alles beim Alten, wäre jedes Jahr gleich wahrscheinlich das
heißeste, und der Höchstwert aus dreißig Jahren würde in den folgenden dreißig im Schnitt
etwa einmal übertroffen. „Extremer" heißt: mehr solche Tage als im heißesten Jahr von
$(first(REF_WINDOW))–$(last(REF_WINDOW)); ein Jahr mit gleich vielen zählt nicht.</p>
<p>Der Rang eines Jahres zählt, wie viele Jahre der Messreihe mehr solche Tage hatten. Die
Stellen, die von „heuer" sprechen — die Kachel, der Block unter der Karte —, meinen ab
Juni das laufende Jahr, davor noch das Vorjahr.</p>
"""

const REEL_HINT = """
<p><strong>Ein Balken pro Jahr</strong> — so viele Tage mit mindestens so viel
Grad hatte das Jahr. Blau: das Jahr mit den meisten solchen Tagen im früheren
Zeitraum — meist 1961–1990, die Vergleichsperiode der Wetterdienste; die Achse
nennt die Jahre der Station. Die gestrichelte Linie liegt auf seiner Höhe — dem
Höchstwert von damals.</p>
<p><strong>Orange: jedes Jahr der letzten 30 Jahre, das über der Linie liegt</strong>
— extremer als das heißeste Jahr von damals. Grau: darunter, auch bei gleicher Höhe. Blass:
die Jahre außerhalb des Vergleichs, vor 1961 und zwischen den beiden Zeiträumen.
Das laufende Jahr ist umrahmt und heißt „bisher", weil es noch nicht vorbei ist.</p>
<p>Wo es zwischen 1961 und 1990 keinen einzigen solchen Tag gab — bei 35 Grad an
jeder zweiten Station —, gibt es keine Linie: orange ist dann jedes Jahr mit
mindestens einem.</p>
"""

# ------------------------------------------------------------ station page

function station_page(st, annual, retrieved, data_until, nat)
    yrs = annual.year
    span = isempty(yrs) ? "—" : "$(minimum(yrs))–$(maximum(yrs))"
    alt = ismissing(st.altitude) ? "" : " · $(round(Int, st.altitude)) m Seehöhe"
    w = windows(annual, nat.late)
    w === nothing && error("station_page: $(st.name) has fewer than 20 complete years")

    # The tiles and sentences go INSIDE the reel box, after its threshold
    # radios, so the same `#th-<t>:checked ~` switch drives them.
    statboxes = join(["<div class=\"statbox statbox-$t\">$(stat_block(st, w, annual, t, nat))</div>"
                      for t in THRESHOLDS], "\n")
    # Stations that do not show the country-wide pattern get the flat story
    # (Fabian, 2026-09-03 Abend): the finished chart from the start and two
    # text beats — the two window sums, then the Österreich sentence with
    # „früher" (no „damals": this story never establishes one) — and no
    # „So schaut Klimawandel aus." Same rule and numbers as the prose opener.
    ups = Dict(t => station_up(st, w, annual, t, nat) for t in THRESHOLDS)
    national = Dict(t => national_sentence(length(nat.more[t]), nat.n, t;
                                           frueher = !ups[t]) for t in THRESHOLDS)
    flat = Dict(t => flat_beat1(w, annual, t, nat) for t in THRESHOLDS if !ups[t])
    # The default tab must have a story: a summit station with no 30-degree day
    # ever recorded opens on Sommertage instead of an empty panel.
    live = [t for t in THRESHOLDS if any(>(0), annual[!, Symbol("days_ge_", t)])]
    default = DEFAULT_THRESHOLD in live ? DEFAULT_THRESHOLD :
              isempty(live) ? DEFAULT_THRESHOLD : first(live)
    reel = reel_box_html(annual, st.name; thresholds = THRESHOLDS, default,
                         late = nat.late, national, flat, tail = statboxes)

    uhi = st.name == "Wien Hohe Warte" ? """
        <p><strong>Stadtlage.</strong> Die Hohe Warte liegt im Wiener Stadtgebiet.
        Ein Teil des Anstiegs geht auf den städtischen Wärmeinseleffekt zurück —
        Beton und Asphalt speichern Wärme. Wer wissen will, was davon übrig
        bleibt, vergleicht mit einer Station im Umland; der Anstieg ist auch dort
        da. Die Werte der 1850er- und 1860er-Jahre wirken zudem auffällig hoch
        (frühe Aufstellung, andere Messhütte) und sollten nicht überinterpretiert
        werden.</p>""" : ""

    body = """
    <p class="kicker"><a href="../">← $KICKER</a></p>
    <h1>$(st.name)</h1>
    <p class="sub">$(st.state)$alt · Messreihe $span</p>
    $(stand_bar(data_until, retrieved))

    $reel

    <div class="details-wrap">
    $(collapsible("Wie lese ich das Diagramm?", REEL_HINT))
    $(collapsible("Daten, Methode und Vorbehalte", """
      <dl>
      <dt>Quelle</dt>
      <dd>GeoSphere Austria Data Hub, Datensatz <code>klima-v2-1d</code>,
          Parameter <code>tlmax</code> (Tagesmaximum der Lufttemperatur).</dd>
      <dt>Station</dt>
      <dd>$(st.name), ID $(st.station_id)$(ismissing(st.altitude) ? "" : ", $(round(Int, st.altitude)) m").</dd>
      <dt>Stand</dt>
      <dd>Daten bis $data_until, abgerufen am $(fmt_date(retrieved)).</dd>
      </dl>
      $(method_html(nat))
      $uhi"""))
    $(collapsible("Quellcode", source_note()))
    </div>
    """
    page("Hitzetage in $(st.name) — $HEADLINE", body;
         root = "../../", path = "/$TOPIC/$(st.slug)/",
         description = "Wie viele heiße Tage es an der Wetterstation $(st.name) " *
                       "gab — Messreihe $span, GeoSphere Austria.",
         script = reel_script())
end

# -------------------------------------------------------------- index page

"""
Progressive enhancement, and the only JavaScript on the index: the nearest
station cannot be pre-rendered. The block is `hidden` in the markup and only
unhidden by this script, so a browser without JS never sees a dead button.
Coordinates are compared in the browser; nothing is sent anywhere.
"""
function finder_script(stations)
    rows = join(["[$(r.lat),$(r.lon),\"$(r.name)\",\"$(r.slug)\"]"
                 for r in eachrow(stations)], ",")
    """
<script>
(function () {
  var S = [$rows];
  var box = document.getElementById("finder");
  if (!box || !document.getElementById("finder-q")) return;
  box.hidden = false;
  var out = document.getElementById("finder-out");
  var q = document.getElementById("finder-q");
  var list = document.getElementById("stationliste");

  function norm(s) {
    s = s.toLowerCase();
    var m = { "ä": "a", "ö": "o", "ü": "u", "ß": "ss", "é": "e", "è": "e", "á": "a" };
    var o = "";
    for (var i = 0; i < s.length; i++) o += (m[s[i]] || s[i]);
    return o;
  }
  function km(la1, lo1, la2, lo2) {
    var p = Math.PI / 180, R = 6371;
    var a = Math.sin((la2 - la1) * p / 2), b = Math.sin((lo2 - lo1) * p / 2);
    var h = a * a + Math.cos(la1 * p) * Math.cos(la2 * p) * b * b;
    return 2 * R * Math.asin(Math.sqrt(h));
  }
  function say(t) { out.textContent = t; }

  document.getElementById("finder-geo").onclick = function () {
    if (!navigator.geolocation) {
      say("Dein Browser kann den Standort nicht bestimmen — bitte in der Karte oder in der Liste wählen.");
      return;
    }
    say("Standort wird bestimmt …");
    navigator.geolocation.getCurrentPosition(function (pos) {
      var d = S.map(function (s) {
        return { d: km(pos.coords.latitude, pos.coords.longitude, s[0], s[1]), n: s[2], u: s[3] };
      });
      d.sort(function (a, b) { return a.d - b.d; });
      out.textContent = "";
      out.appendChild(document.createTextNode("Am nächsten: "));
      d.slice(0, 3).forEach(function (s, i) {
        if (i) out.appendChild(document.createTextNode(" · "));
        var a = document.createElement("a");
        a.href = s.u + "/";
        a.textContent = s.n + " (" + s.d.toFixed(1).replace(".", ",") + " km)";
        out.appendChild(a);
      });
    }, function (err) {
      say(err && err.code === 1
        ? "Kein Zugriff auf den Standort — bitte in der Karte oder in der Liste wählen."
        : "Standort nicht verfügbar — bitte in der Karte oder in der Liste wählen.");
    }, { timeout: 12000, maximumAge: 600000 });
  };

  // The datalist gives native autocomplete without any script; this turns a
  // completed name into a link, and Enter into a jump.
  function match(v) {
    var n = norm(v), pre = null;
    if (!n) return null;
    for (var i = 0; i < S.length; i++) {
      var k = norm(S[i][2]);
      if (k === n) return S[i];
      if (pre === null && k.indexOf(n) === 0) pre = S[i];
    }
    return pre;
  }
  function offer(s, exact) {
    out.textContent = "";
    var a = document.createElement("a");
    a.href = s[3] + "/";
    a.textContent = s[2] + " ansehen";
    out.appendChild(document.createTextNode(exact ? "→ " : "Meinst du: "));
    out.appendChild(a);
  }

  // The Bundesland is the group heading, not part of the item, so fold it into
  // each item's search key — the placeholder promises it is searchable.
  var grp = list ? list.getElementsByClassName("lgroup") : [];
  for (var g0 = 0; g0 < grp.length; g0++) {
    var h = grp[g0].getElementsByTagName("h3")[0];
    var gn = h ? " " + h.textContent : "";
    var li0 = grp[g0].getElementsByTagName("li");
    for (var j0 = 0; j0 < li0.length; j0++)
      li0[j0].setAttribute("data-k", norm(li0[j0].textContent + gn));
  }
  q.oninput = function () {
    var v = norm(q.value.trim());
    if (!list) return;
    list.open = v.length > 0;
    var groups = list.getElementsByClassName("lgroup");
    for (var g = 0; g < groups.length; g++) {
      var li = groups[g].getElementsByTagName("li"), shown = 0;
      for (var j = 0; j < li.length; j++) {
        var hit = v === "" || li[j].getAttribute("data-k").indexOf(v) >= 0;
        li[j].hidden = !hit;
        if (hit) shown++;
      }
      groups[g].hidden = shown === 0;
    }
    var m = match(q.value.trim());
    if (m && norm(m[2]) === v) offer(m, true); else out.textContent = "";
  };
  q.onkeydown = function (e) {
    if (e.key !== "Enter") return;
    var v = q.value.trim(), m = match(v);
    if (!m) return;
    e.preventDefault();
    // Only jump where the name is unambiguous; a prefix gets offered, not
    // followed — "wien" must not silently pick one of five Wien stations.
    if (norm(m[2]) === norm(v)) location.href = m[3] + "/";
    else offer(m, false);
  };
})();
</script>"""
end

"Every station with a page, grouped by Bundesland — the no-JavaScript path."
function station_list(paged)
    states = vcat([s for s in STATE_ORDER if s in paged.state],
                  sort(unique([s for s in paged.state if !(s in STATE_ORDER)])))
    join([begin
        g = sort(@subset(paged, :state == state), :name)
        """<div class="lgroup"><h3>$state</h3><ul>""" *
        join(["""<li><a href="$(r.slug)/">$(r.name)</a> <span>seit $(r.from_year)</span></li>"""
              for r in eachrow(g)]) * "</ul></div>"
    end for state in states], "\n")
end

"""
The sentence about the focus year, per threshold, above its ranking: at how
many of the compared stations it beat every complete year, and at how many it
sits among the five with the most. A weather sentence by design — the hook,
kept in the block that carries the year in its heading, away from the
30-year claim. Past tense once the year is over. Counts only; the one wording
branch is „an allen“.
"""
function focus_claim(annual_all, ok, focus, is_running, t)
    col = Symbol("days_ge_", t)
    plural = day_term_plain(t)
    n = n_rec = n_top5 = 0
    hist = @subset(annual_all, :year != focus)
    for r in eachrow(ok)
        h = hist[hist.station_name .== r.station_name, :]
        count(h.complete) >= 20 || continue
        rank = year_rank(r[col], h[h.complete, col])
        n += 1
        n_rec += rank == 1
        n_top5 += rank <= 5
    end
    n_top5 == 0 && return ""
    all5 = n_top5 == n ? "allen $n" : "$n_top5 von $n"
    if is_running
        lead = n_rec == 0 ? "" :
            "An $n_rec von $n Stationen hat $focus jetzt schon mehr $plural als jedes volle Jahr seit Messbeginn. "
        lead * "An $all5 gehört es zu den fünf Jahren mit den meisten — und es ist noch nicht vorbei."
    else
        lead = n_rec == 0 ? "" :
            "An $n_rec von $n Stationen hatte $focus mehr $plural als jedes andere volle Jahr seit Messbeginn. "
        lead * "An $all5 gehörte es zu den fünf Jahren mit den meisten."
    end
end

"""
This year's ranking below the map: the five stations with the most and the
five with the fewest hot days so far, per threshold (pill tabs, one radio
group, pure CSS). Only stations with (nearly) complete coverage this year
are compared — a station that reported 31 days cannot be "the coolest".
Ties at the cut are named, not hidden: with eight stations at zero, listing
five of them would be a coin flip presented as a ranking.
"""
function ranking_html(annual_all, mapst, has_page, running, data_until, nat)
    meta = Dict(String(r.name) => r for r in eachrow(mapst))

    function item(r, col; cls = "")
        m = get(meta, r.station_name, nothing)
        v = Int(r[col])
        who = m !== nothing && m.slug in has_page ?
              "<a href=\"$(m.slug)/\">$(r.station_name)</a>" : r.station_name
        where = m === nothing ? "" :
                "<span class=\"where\">$(m.state), $(round(Int, m.altitude)) m</span>"
        """<li class="$cls"><span class="n">$v <small>$(v == 1 ? "Tag" : "Tage")</small></span><span class="who">$who $where</span></li>"""
    end
    function column(rows, col, title; fewest = false)
        rows = sort(rows, [order(col; rev = !fewest), :station_name])
        shown = first(rows, 5)
        items = [item(r, col) for r in eachrow(shown)]
        # ties across the cut: say how many more share the last shown value
        if nrow(rows) > 5
            last_v = shown[end, col]
            rest = count(==(last_v), rows[6:end, col])
            rest > 0 && push!(items,
                """<li class="more"><span class="n">·</span><span class="who">… und $rest weitere
                   Station$(rest == 1 ? "" : "en") mit $(Int(last_v)) $(last_v == 1 ? "Tag" : "Tagen")</span></li>""")
        end
        "<div><h3>$title</h3><ol>" * join(items) * "</ol></div>"
    end

    inputs = join(["<input type=\"radio\" name=\"rk\" id=\"rk-$t\"$(t == DEFAULT_THRESHOLD ? " checked" : "")>"
                   for t in THRESHOLDS], "\n")
    tabs = join(["""<label for="rk-$t">$(day_term(t))<span>≥ $t °C</span></label>""" for t in THRESHOLDS], "\n")

    # The focus year's ranking — the "und heuer" hook, not the interpretation.
    # From June the running year, before that the previous one (`focus_year`).
    focus = focus_year()
    is_running = focus == running
    cur = @subset(annual_all, :year == focus)
    ranking = ""
    if nrow(cur) > 0
        maxobs = maximum(cur.n_observed)
        ok = @subset(cur, :n_observed >= 0.9 * maxobs)
        dropped = nrow(cur) - nrow(ok)
        focus_claims = join(["<div class=\"nclaim nclaim-$t\"><p class=\"claim\">$(focus_claim(annual_all, ok, focus, is_running, t))</p></div>"
                             for t in THRESHOLDS], "\n")
        ranks = join([begin
            col = Symbol("days_ge_", t)
            "<div class=\"rank rank-$t\">" *
            column(ok, col, t == 35 ? "Die meisten extrem heißen Tage" : "Die meisten $(day_term(t))") *
            column(ok, col, "Die wenigsten"; fewest = true) *
            "</div>"
        end for t in THRESHOLDS], "\n")
        note = "Daten bis $data_until. Verglichen werden die $(nrow(ok)) Stationen mit " *
               "lückenloser Messung " * (is_running ? "im laufenden Jahr" : "im Jahr $focus") *
               (dropped > 0 ? " ($dropped mit Messlücken ausgelassen)." : ".")
        ranking = """
        <h2>$focus$(is_running ? " bisher" : ""): wo es am heißesten war — und wo kaum</h2>
        <div class="tabs">$tabs</div>
        $focus_claims
        $ranks
        <p class="note">$note</p>
        """
    end
    # The comparison sentences („Seit 1997, verglichen mit …") moved into the
    # reel on every station page; the landing keeps only the focus-year ranking.
    isempty(ranking) && return ""
    """
    <section class="rankbox">
    $inputs
    $ranking
    </section>
    """
end

function index_page(map_stations, laender, border, has_page, annual_all, retrieved, data_until, nat)
    mapdf = DataFrame(map_stations)
    counts = @chain mapdf begin
        @groupby(:tier)
        @combine(:n = length(:tier))
    end
    n_by_tier = Dict(r.tier => r.n for r in eachrow(counts))
    legend = join(["""<span><span class="dot" style="background:$(TIER_STYLE[t][1])"></span>
        $(TIER_STYLE[t][3]) ($(get(n_by_tier, t, 0)))</span>""" for t in TIER_ORDER], "\n")

    paged = sort(@subset(mapdf, :slug in has_page), :name)
    oldest = minimum(mapdf.from_year)

    body = """
    <p class="kicker">$KICKER</p>
    <h1>$HEADLINE</h1>
    <p class="lead">$LEAD</p>
    $(stand_bar(data_until, retrieved))

    <section class="finder">
    <h2>Station wählen</h2>
    <p>Tipp auf einen Punkt in der Karte — oder such deine Station.</p>
    <div id="finder" hidden>
      <div class="row">
        <button id="finder-geo" type="button">Nächste Station finden</button>
        <input id="finder-q" type="search" autocomplete="off" list="stationopts"
               placeholder="Station oder Bundesland suchen …"
               aria-label="Station oder Bundesland suchen">
      </div>
      <p class="out" id="finder-out" role="status"></p>
      <p class="privacy">Der Standort wird nur im Browser verwendet und nirgendwohin übertragen.</p>
    </div>
    </section>
    <datalist id="stationopts">
    $(join(["""<option value="$(r.name)">$(r.state)</option>""" for r in eachrow(paged)], "\n"))
    </datalist>

    $(map_svg(map_stations, laender, border, has_page))
    <div class="legend">Messbeginn:&nbsp; $legend</div>

    $(ranking_html(annual_all, mapdf, has_page, year(today()), data_until, nat))

    <div class="details-wrap">
    <details class="box" id="stationliste">
    <summary>Alle $(nrow(paged)) Stationen als Liste</summary>
    <div class="boxbody" style="max-width:none">$(station_list(paged))</div>
    </details>
    $(collapsible("Welche Stationen sind das?", """
      <p>Jeder Punkt ist eine Wetterstation, die laut Metadaten spätestens 1970
      zu messen begonnen hat, noch aktiv ist und als zusammengeführte
      Langzeitreihe geführt wird — $(nrow(mapdf)) Stationen, die älteste seit
      $oldest. Die Farbe zeigt, wie weit die Reihe zurückreicht.</p>
      <p>Kurze Reihen sind bewusst nicht dabei: Ob es heißer wird, lässt sich
      erst über Jahrzehnte sagen, nicht über zehn Jahre.</p>"""))
    $(collapsible("Daten und Quellen", """
      <dl>
      <dt>Temperaturmessungen</dt>
      <dd>GeoSphere Austria Data Hub, Datensatz <code>klima-v2-1d</code>,
          Parameter <code>tlmax</code>. Daten bis $data_until,
          abgerufen am $(fmt_date(retrieved)).</dd>
      <dt>Grenzen</dt>
      <dd>geoBoundaries (CC BY 4.0), vereinfacht.</dd>
      </dl>
      $(method_html(nat))"""))
    $(collapsible("Quellcode", source_note()))
    </div>
    """
    page("$HEADLINE — $KICKER", body;
         root = "../", path = "/$TOPIC/",
         description = "Sommer, die früher extrem waren, sind heute normal: Hitzetage an " *
                       "$(nrow(paged)) österreichischen Wetterstationen, Jahr für Jahr seit Messbeginn.",
         script = finder_script(paged))
end

# ----------------------------------------------------------- site shell

"""
The page at the domain root. Until there is a second topic it only forwards to
the one that exists — a meta refresh, since GitHub Pages cannot redirect — with
a plain link for anyone whose browser waits. No counter here: the visit is
counted on the page it lands on.
"""
landing_page() = """
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=$TOPIC/">
<link rel="canonical" href="$SITE_URL/$TOPIC/">
<title>Schau ma amal — $DOMAIN</title>
</head>
<body>
<p><a href="$TOPIC/">Weiter zu $KICKER</a></p>
</body>
</html>
"""

"""
The topic index, the forwarding page above it and the two files GitHub Pages
needs: `.nojekyll` (so nothing is filtered) and `CNAME` (the custom domain,
read from the published branch).
"""
function write_site_shell(index_html)
    mkpath(joinpath(SITE, TOPIC))
    write(joinpath(SITE, TOPIC, "index.html"), index_html)
    write(joinpath(SITE, "index.html"), landing_page())
    write(joinpath(SITE, "CNAME"), DOMAIN * "\n")
    touch(joinpath(SITE, ".nojekyll"))
end

# ------------------------------------------------------------------ build

"""
"Daten bis" is the last day actually observed, not the day of retrieval. The
annual table has no dates, so it comes from the processed daily file's date
column (the focus stations; every station is fetched the same day).
"""
function data_until(annual_all)
    p = joinpath(PROC, "daily_tlmax.csv")
    isfile(p) || return string(maximum(annual_all.year))
    d = CSV.read(p, DataFrame; select = [:date])
    fmt_date(maximum(d.date))
end

function main()
    index_only = !isempty(get(ENV, "KLIMA_INDEX", ""))
    annual_all = CSV.read(joinpath(PROC, "heat_days.csv"), DataFrame)
    mapst   = CSV.read(joinpath(PROC, "map_stations.csv"), DataFrame)
    laender = CSV.read(joinpath(PROC, "austria_laender.csv"), DataFrame)
    border  = CSV.read(joinpath(PROC, "austria_border.csv"), DataFrame)
    retrieved = only(unique(mapst.retrieved))
    until_all = data_until(annual_all)
    # The late window ends with the last year complete anywhere; the country-wide
    # sentences and every station's windows use the same one.
    nat = national_claims(annual_all, mapst, late_window(annual_all))

    # Names go unescaped into a JS string literal, an <option value>, an
    # aria-label and a <meta content>. They arrive from the provider via the
    # scheduled refresh PRs, so a quote in a renamed station would break the
    # index script silently. Ambiguity is an error, in this repo's style.
    safe(c) = isletter(c) || isdigit(c) || c in " -–.()/&,'"
    unsafe = filter(n -> !all(safe, n), mapst.name)
    isempty(unsafe) ||
        error("Station names need escaping before they can be interpolated: $unsafe")

    only_slugs = Set(filter(!isempty, split(get(ENV, "KLIMA_ONLY", ""), ",")))
    drivers = @chain mapst begin
        @subset(:name in unique(annual_all.station_name))
        @subset(isempty(only_slugs) || :slug in only_slugs)
        sort(:name)
    end
    expected = Set(drivers.slug)

    # Slice for this process. Strided, not contiguous, so every slice gets a
    # mix of long and short records and they take similar time.
    chunk = get(ENV, "KLIMA_CHUNK", "")
    if !isempty(chunk)
        i, n = parse.(Int, split(chunk, "/"))
        (0 <= i < n) || error("KLIMA_CHUNK=i/n needs 0 <= i < n, got $chunk")
        drivers = drivers[(i + 1):n:end, :]
        @info "Chunk" i n stations = nrow(drivers)
    end

    set_theme!(klima_theme())
    # Only a whole-site build starts from scratch; a slice adds to what is there.
    isempty(chunk) && !index_only && rm(SITE; recursive = true, force = true)
    mkpath(SITE)
    write(joinpath(SITE, "style.css"), CSS)

    if index_only
        # The index links every station it lists, so it is built from the pages
        # that survived — and a slice that died must not pass silently.
        built = sort([d for d in readdir(joinpath(SITE, TOPIC))
                      if isfile(joinpath(SITE, TOPIC, d, "index.html"))])
        missing_pages = sort(collect(setdiff(expected, Set(built))))
        isempty(missing_pages) ||
            (@error "Station pages missing — refusing to publish" missing_pages; exit(1))
        write_site_shell(index_page(mapst, laender, border, Set(built), annual_all, retrieved, until_all, nat))
        @info "Index written" pages = length(built)
        return
    end

    failed, built = String[], String[]
    for (n, st) in enumerate(eachrow(drivers))
        annual = sort(@subset(annual_all, :station_name == st.name), :year)
        try
            dir = joinpath(SITE, TOPIC, st.slug)
            mkpath(dir)
            write(joinpath(dir, "index.html"), station_page(st, annual, retrieved, until_all, nat))
            push!(built, st.slug)
            @info "Page" station = st.name years = nrow(annual)
        catch err
            push!(failed, st.name)
            @warn "Page failed" station = st.name err
        end
        if n % 10 == 0
            GC.gc()
            # Sys.maxrss(), not gc_live_bytes(): the latter drifts upward across
            # a build and would mislead exactly when it is needed. RSS is what
            # the OOM killer counts.
            @info "Progress" done = n of = nrow(drivers) peak_rss_MB = round(Int, Sys.maxrss() / 2^20)
        end
    end

    # A slice leaves the index to the final pass; a whole-site build writes it
    # here, from the pages that actually exist — otherwise a station that failed
    # an SVG assertion keeps a clickable map dot pointing at a 404.
    if isempty(chunk)
        write_site_shell(index_page(mapst, laender, border, Set(built), annual_all, retrieved, until_all, nat))
    end
    @info "Built site" dir = SITE pages = length(built)
    if !isempty(failed)
        @error "Some pages failed — refusing to publish an incomplete site" failed
        exit(1)
    end
end

main()
