### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 2533912d-86df-4200-bd83-9e341b3002c1
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
# Sortierte Balken — die Hitzetage-Grafik der Site

Fabians Idee (2026-08-31), umgebaut am 2026-09-01 (Abend): Balken pro Jahr,
in Stufen animiert. Zuerst nur die Vergleichsjahre 1961–1990 mit dem
Ausnahmejahr in Farbe, dann eine Linie auf dessen Höhe, dann alle anderen
Jahre — farbig ist, was die Linie erreicht, die Farbe ist das Jahrzehnt.
Zum Schluss, wenn das laufende Jahr farbig, aber nicht das höchste ist, die
Umsortierung nach Höhe: der Rang von heuer. Chart, Kacheln und die Sätze
darunter teilen Fenster und Linie (`src/lib/windows.jl`).

Dieses Notebook **ist** der Chart der Stationsseiten: `build_prototype.jl`
inkludiert es und ruft `race_panel_html`, `race_css`, `race_nav`,
`race_script`. Alles hier ist CairoMakie-SVG plus CSS-Zustandsautomat auf
versteckten Radios — kein Julia im Browser, das kleine Script macht nur
Wischen, Pfeiltasten, ⏸ und die Übergabe nach dem Autoplay.

- **`bar_race_data`** — Werte, Jahrzehntklassen, Fenster/Linie/Fokusjahr
  (Metadaten), chronologische und sortierte x-Position.
- **`css_bar_race_svg`** — rendert einmal in den Endfarben und taggt
  Balken, Jahreslabels, Achsenlabels, Minorticks, Linie und Titel über
  eindeutige Farben; jede Stufe ist eine CSS-Variable pro Element.
- **`race_headline`** — die Titel sind Befunde („Seit 1996 zwölf Jahre wie
  das Ausnahmejahr 1983"), keine Beschreibungen.
- **`dedupe_glyphs`** — Cairos Glyphen-`<defs>` einmal pro Seite statt pro SVG.

Als Skript: `julia --project notebooks/bar_race.jl` schreibt die
Vorschauseite `notebooks/out/bar_race_krems_interaktiv.html` (beide
Größenvarianten, Media-Query wie auf der Site). Das Video (`record_bar_race`)
bleibt als Option für Social-Media-Schnipsel, wird aber nicht mehr gebaut.
"""
  ╠═╡ =#

# ╔═╡ b020f744-ab95-4b09-9423-4a0bda37118c
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))
end

# ╔═╡ 00222757-a3aa-4c5b-9bc7-a5cd1a076978
begin
    using CairoMakie
    using CSV, DataFrames, DataFrameMacros, Chain
    using Dates, Statistics, Printf
    using Makie.Colors: RGB, hex, weighted_color_mean, @colorant_str
    # RGBAf comes from Makie itself (re-exported by CairoMakie)
end

# ╔═╡ c7c96eba-3c2f-4120-9bff-f3cefa36fd07
begin
    include(joinpath(@__DIR__, "..", "src", "lib", "theme.jl"))
    include(joinpath(@__DIR__, "..", "src", "lib", "terms.jl"))
    include(joinpath(@__DIR__, "..", "src", "lib", "windows.jl"))
end

# ╔═╡ fa9d6e56-1e88-4d48-8068-6a876a459c67
begin
    const DATADIR = normpath(joinpath(@__DIR__, "..", "data", "processed"))
    const OUTDIR  = normpath(joinpath(@__DIR__, "out"))
    const UNIFORM = colorant"#e39264"      # pre-recolor bar colour
    const GRAY    = colorant"#dcdcdc"      # non-top bars after the gray-out

    # Plasma, cut before its pale end: ordered, perceptually uniform, and the
    # dark end is blue, not black. The race shows bars, not thin lines, so it
    # can afford more of the bright end than the line charts did (0.9 vs 0.7);
    # text gets a darkened variant, 13 px labels on white need the contrast.
    const CMAP = Makie.to_colormap(:plasma)
    const CMAP_TOP = 0.90
    function decade_colors(n; top = CMAP_TOP)
        n <= 1 && return [RGBAf(CMAP[1])]
        at(x) = CMAP[clamp(round(Int, 1 + x * (length(CMAP) - 1)), 1, length(CMAP))]
        [RGBAf(at(x)) for x in range(0.0, top; length = n)]
    end
    label_colors(cols; f = 0.78) = [RGBAf(c.r * f, c.g * f, c.b * f, 1) for c in cols]

    # Tag colours: every element the CSS must address gets its own near-black
    # (visually just black or dark grey, > 0.6 % channel distance from every
    # other tag colour). The post-pass finds them by fill/stroke.
    const TITLE1_COLOR  = colorant"#161616"   # "Hitzetage (≥ X °C) pro Jahr in S"
    const TITLE2_COLOR  = colorant"#1c1c1c"   # the finding, shown from the gray-out on
    const TITLE2B_COLOR = colorant"#575757"   # its second line: tag colour IS the grey
    const LABEL_COLOR   = colorant"#121212"   # year labels on the top bars
    const TICK_COLOR    = colorant"#0a0b0c"   # decade labels on the x axis
    const MTICK_COLOR   = colorant"#0e0e0e"   # decade-boundary minor ticks (stroke)
    const TITLE3_COLOR  = colorant"#1a1a1a"   # the rank of this year, sorted view only
    const LINE_COLOR    = colorant"#202020"   # the record line (stroke)
    const LINELBL_COLOR = colorant"#242424"   # its label, one line under the title

    # Decade classes a station can have at most: "vor 1960" + 1960er … 2020er.
    # The site's stylesheet is one file for every station, so the auto-play
    # timeline is laid out for this many recolour steps.
    const RACE_ND = 8

    const SVG_SCRATCH = Ref{String}()
end

# ╔═╡ 9f8aa9c0-9dc4-45a5-9c97-908d1953253a
begin
    """
    One row per year of one station's annual frame (`heat_days.csv` rows), plus
    the chart's metadata under `race_meta(df)`: value, decade class + colour,
    chronological and sorted-by-height x on a shared axis span, and the flags
    the stages need — `win` (in the early window), `rec` (its record year),
    `top` (at or above the line, so coloured), `label`.

    The line comes from `race_line`, the same rule as the sentence under the
    tiles: form A (25/30 °C, a real record) — the record of 1961–1990, every
    year at or above it coloured; form C (always at 35 °C) — one day, not
    drawn, coloured is every year that had such a day. The windows are
    `windows()`. Chart, tiles and sentences therefore cannot disagree.

    All available years, incomplete ones included: a year with gaps can only
    be too low, never too high, so it cannot cross the line by mistake. The
    running year is framed and always labelled.

    `label_max`: the phone canvas cannot fit fifty rotated labels; above the
    cap only the record year(s) and the running year keep theirs.
    """
    function bar_race_data(annual::AbstractDataFrame; threshold = 30, late = late_window(annual),
                           label_max = typemax(Int), cmap_top = CMAP_TOP)
        col = Symbol("days_ge_", threshold)
        laufend = year(today())
        df = sort(annual, :year)
        nrow(df) > 0 || error("bar_race_data: empty annual frame")
        w = windows(annual, late)
        w === nothing && error("bar_race_data: fewer than 20 complete years, no comparison window")
        out = DataFrame(year = Int.(df.year), value = Float64.(df[!, col]))
        out.running = out.year .== laufend
        out.decade = 10 .* fld.(out.year, 10)
        n = nrow(out)

        ord = sortperm(collect(zip(out.value, out.year)))    # ties break by year
        out.rank = invperm(ord)
        y0, y1 = extrema(out.year)
        out.x_chrono = Float64.(out.year)
        out.x_sorted = n == 1 ? copy(out.x_chrono) :
                       y0 .+ (out.rank .- 1) ./ (n - 1) .* (y1 - y0)

        rl = race_line(w, threshold)
        out.win = in.(out.year, Ref(Set(Int.(w.e.year))))
        out.rec = in.(out.year, Ref(Set(rl.form == :A ? rl.rec_years : Int[])))
        out.top = out.value .>= rl.line
        out.label = count(out.top) > label_max ? out.rec .| out.running : out.top .| out.running
        # stagger index within the window and outside it
        out.gi = zeros(Int, n)
        out.gn = ones(Int, n)
        for grp in (out.win, .!out.win)
            idx = findall(grp)
            out.gi[idx] .= 0:(length(idx) - 1)
            out.gn[idx] .= max(length(idx), 1)
        end

        # The "and this year" beat: the sorted view exists when the focus year
        # is coloured but not the tallest bar — then its rank is the point.
        focus = focus_year()
        fi = findfirst(==(focus), out.year)
        frank = fi === nothing ? 0 : year_rank(out.value[fi], out.value)
        sortable = fi !== nothing && out.top[fi] && 2 <= frank <= RANK_MAX

        # Colour classes: decades from 1960 on individually, everything earlier
        # merged into "vor 1960" — one axis label, one legend entry, one colour.
        # (If the label merges, the colour must merge too, or the label lies.)
        out.cclass = [d < 1960 ? "vor 1960" : "$(d)er" for d in out.decade]
        classes = unique(out.cclass)                 # chronological: out is year-sorted
        length(classes) <= RACE_ND ||
            error("$(length(classes)) decade classes, the timeline is laid out for $RACE_ND")
        bycol = Dict(c => col for (c, col) in zip(classes, decade_colors(length(classes); top = cmap_top)))
        out.crank = [findfirst(==(c), classes) - 1 for c in out.cclass]
        out.decade_color = [bycol[c] for c in out.cclass]

        lv = w.l[!, col]
        metadata!(out, "race", (; rl.form, rl.line, rl.rec, rl.rec_years, window = w, y0, y1,
                                  n_since = count(>=(rl.line), lv), n_late = length(lv),
                                  focus, focus_rank = frank, focus_running = focus == laufend,
                                  sortable); style = :note)
        out
    end
    "The chart's metadata — line, windows, counts, the focus year."
    race_meta(df) = metadata(df, "race")

    "Same, for a station by name — reads `heat_days.csv`. For Pluto and the preview page."
    function bar_race_data(station::AbstractString; kwargs...)
        annual = @chain joinpath(DATADIR, "heat_days.csv") begin
            CSV.read(DataFrame)
            @subset(:station_name == station)
        end
        nrow(annual) > 0 || error("No rows for station $station — check the name against heat_days.csv")
        bar_race_data(annual; kwargs...)
    end

    "True when the threshold was never reached — there is nothing to race."
    race_empty(df) = all(iszero, df.value)
end

# ╔═╡ 720912c1-56cd-4986-82d5-a63992d9653c
begin
    "The five stages on one timeline, in seconds — the video's timeline."
    const STAGES = (
        appear  = (0.2, 3.0),    # per-bar staggered inside this window
        recolor = (3.5, 4.7),
        gray    = (5.2, 6.2),
        labels  = (6.2, 7.0),
        sort    = (7.6, 9.4),
        stop    = 10.8,
    )

    smoothstep(t) = t <= 0 ? 0.0 : t >= 1 ? 1.0 : t * t * (3 - 2t)
    "Progress of a stage at time `t`: 0 before, 1 after, eased in between."
    progress(t, (t0, t1)) = smoothstep((t - t0) / (t1 - t0))
    "Linear colour interpolation, `s` = 0 → a, 1 → b."
    lerpc(a, b, s) = RGBAf(weighted_color_mean(1 - s, RGBAf(a), RGBAf(b)))
end

# ╔═╡ 09033923-0a17-4f2b-ae79-c7f74d8eb31c
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## A — Makie `record` (Video, optional)

Kept for a social-media clip. Observables make *per-frame updates* automatic,
but every *transition* — easing, staggering, the position lerp — is
hand-rolled below; Makie has no staged-transition layer. Not built by default
(`generate(video = true)`).
"""
  ╠═╡ =#

# ╔═╡ 3730929a-5791-4ee1-a699-bee50ca2fa5a
"""
Render the five-stage animation to `path` (mp4). Fully self-driving:
one loop over timestamps updates colour, position and label observables.
"""
function record_bar_race(df; path, station, threshold, framerate = 30)
    n = nrow(df)
    y0, y1 = extrema(df.year)
    ymax = max(maximum(df.value), 1.0)

    xs = Observable(copy(df.x_chrono))
    cs = Observable([RGBAf(UNIFORM.r, UNIFORM.g, UNIFORM.b, 0.0) for _ in 1:n])

    set_theme!(klima_theme())
    fig = Figure(size = (860, 430))
    ax = Axis(fig[1, 1];
        title = "$station — $(day_term(threshold)) (≥ $threshold °C), die heißesten Jahre sind jung",
        ylabel = "Tage pro Jahr")
    barplot!(ax, xs, df.value; color = cs, width = 0.8,
        strokewidth = [r ? 1.5 : 0.0 for r in df.running], strokecolor = :black)
    xlims!(ax, y0 - 1.5, y1 + 1.5)
    ylims!(ax, 0, ymax * 1.25)

    topidx = findall(df.top)
    lpos = Observable([Point2f(df.x_chrono[i], df.value[i] + 0.025 * ymax) for i in topidx])
    lcol = Observable(fill(RGBAf(0, 0, 0, 0), length(topidx)))
    text!(ax, lpos; text = [df.running[i] ? "$(df.year[i]) bisher" : string(df.year[i]) for i in topidx],
        rotation = pi / 2, align = (:left, :center), fontsize = 9, color = lcol)

    ts = 0:(1 / framerate):STAGES.stop
    record(fig, path, ts; framerate) do t
        rec = progress(t, STAGES.recolor)
        gry = progress(t, STAGES.gray)
        for i in 1:n
            a0 = STAGES.appear[1] + (i - 1) / n * (STAGES.appear[2] - STAGES.appear[1] - 0.4)
            alpha = progress(t, (a0, a0 + 0.4))
            c = lerpc(UNIFORM, df.decade_color[i], rec)
            df.top[i] || (c = lerpc(c, GRAY, gry))
            cs.val[i] = RGBAf(c.r, c.g, c.b, alpha)
        end
        notify(cs)

        s = progress(t, STAGES.sort)
        xs[] = (1 - s) .* df.x_chrono .+ s .* df.x_sorted
        ax.xticklabelcolor = RGBAf(0, 0, 0, 1 - s)   # year ticks stop meaning anything
        ax.xtickcolor = RGBAf(0, 0, 0, 0.4 * (1 - s))

        lt = progress(t, STAGES.labels)
        lcol[] = fill(RGBAf(0, 0, 0, lt), length(topidx))
        lpos[] = [Point2f((1 - s) * df.x_chrono[i] + s * df.x_sorted[i],
                          df.value[i] + 0.025 * ymax) for i in topidx]
    end
    path
end

# ╔═╡ cc787e0e-2950-4e65-b25a-b8315b8724db
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## B — CSS auf getaggtem SVG (die Site)

Same pipeline as the site always used: CairoMakie writes presentation
attributes, a post-pass tags elements by colour. Per-bar custom properties
carry everything the stages need — `--i` (chronological index), `--d`
(decade rank), `--cd` (decade colour), `--dx` (shift to the sorted position,
known at build time, as a percentage of the viewBox width — px transforms on
SVG elements are mis-scaled by Safari's page zoom). Labels get `--fx/--fy`
flight vectors into the axislegend column, in the same units. Zero JS in the chart itself, crisp SVG, replays on
reload.

Traps encoded below: zero-height bars emit no path; horizontal text splits
into glyph groups at *different* x while rotated text shares one x per
label; edge labels poke across their boundary interval. Counts are asserted
at every step — a Makie upgrade that changes SVG structure fails the build.
"""
  ╠═╡ =#

# ╔═╡ 9e6f8958-7cc3-4034-bad3-5c177d5deb23
begin
    pctc(c) = (Float64(c.r), Float64(c.g), Float64(c.b)) .* 100

    function attr_rgbpct(tag, attr)
        m = match(Regex(" $attr=\"rgb\\(([\\d.]+)%, ?([\\d.]+)%, ?([\\d.]+)%\\)\""), tag)
        m === nothing ? nothing : parse.(Float64, (m[1], m[2], m[3]))
    end
    color_eq(p, c; tol = 0.6) = p !== nothing && all(abs.(p .- pctc(RGBAf(c))) .< tol)
    csshex(c) = "#" * hex(RGB(RGBAf(c).r, RGBAf(c).g, RGBAf(c).b))

    "Cairo's XML prolog is invalid inside an HTML document (parsed as a bogus comment)."
    strip_prolog(svg) = replace(svg, r"^\s*<\?xml[^>]*\?>\s*" => "")
end

# ╔═╡ 4f1caa55-cc0d-4dee-adf7-ce3d15502f3f
"""
The chart's texts: `t1` over the window (stages 1 and 2), `line_lbl` for the
line (stage 2, one line under the title), `t2` the finding once the other
years are in (stage 3), `t3` the rank of the focus year in the sorted view
(stage 4), `t2b` the colour key under t2 and t3. The wording follows the
sentence under the tiles (DIARY 2026-09-01, Abend); `short` drops the station
name and shortens the line label for the phone canvas.
"""
function race_headline(df; station, threshold, short = false)
    m = race_meta(df)
    term, plural, sing = day_term(threshold), day_term_plain(threshold), day_term_sing(threshold)
    wo = short ? "" : " in $station"
    w = m.window
    t1 = "$term pro Jahr$wo, $(w.e_span)"
    if m.form == :A
        yrs = join_de(m.rec_years)
        one = length(m.rec_years) == 1
        line_lbl = (one ? "Ausnahmejahr $yrs" : "Ausnahmejahre $yrs") * ": $(m.rec) Tage" *
                   (short ? "" : " — kein Jahr $(w.e_span) hatte mehr")
        # the phone canvas has no room for "wie die Ausnahmejahre 1971 und 1983";
        # the line label of stage 2 has introduced the word there
        like = short ? "wie $yrs" : one ? "wie das Ausnahmejahr $yrs" : "wie die Ausnahmejahre $yrs"
        n = m.n_since
        t2 = n == 0 ? "Seit $(w.since) kein Jahr $like" :
             n == 1 ? "Seit $(w.since) ein Jahr $like" :
                      "Seit $(w.since) $(num_de(n)) Jahre $like"
        t2b = "farbig: Jahre mit mindestens $(m.rec) $(day_term_dat(threshold))"
    else
        line_lbl = ""
        n = m.n_since
        t2 = n == 0 ? "Seit $(w.since) kein Jahr mit einem $sing" :
             n == 1 ? "Seit $(w.since) in einem einzigen Jahr ein $sing" :
             n == m.n_late ? "Seit $(w.since) in jedem Jahr ein $sing" :
                      "Seit $(w.since) in $n von $(m.n_late) Jahren ein $sing"
        t2b = "farbig: Jahre mit mindestens einem $sing"
    end
    t3 = m.sortable ?
        "$(m.focus)$(m.focus_running ? " bisher" : ""): die $(ordinal_de(m.focus_rank))meisten $plural seit $(m.y0)" : ""
    (; t1, t2, t2b, t3, line_lbl)
end

# ╔═╡ 13a1b7ad-f599-41de-aca1-3e180a908b54
"""
Render the bar chart once (final colours), tag bars/labels/ticks/line/titles
with their per-element variables, and return the SVG string.

`label_fs` is the rotated year labels' size, `title_fs` the in-axis title's.
Year labels alternate between two heights by sorted rank, so neighbours in the
sorted view (which are *always* adjacent) do not overprint — on a 440 px canvas
the bar pitch is under 5 px.
"""
function css_bar_race_svg(df; station, threshold, size = (860, 430),
                          label_fs = 9, title_fs = 15, short = false)
    m = race_meta(df)
    n = nrow(df)
    y0, y1 = extrema(df.year)
    ymax = max(maximum(df.value), m.line, 1.0)

    # Decade labels sit BETWEEN the (minor) ticks at decade boundaries — the
    # calday_ticks trick from heat_days.jl, applied to years. Everything
    # before 1960 is one slot, "vor 1960", matching the merged colour class.
    # One slot per class PRESENT, not per decade in the year range: eight
    # stations have gaps of whole decades (Bludenz: five classes across eight
    # decades), and a label for a decade without data would be a lie.
    classes = unique(df.cclass)
    K = length(classes)
    class_color = Dict(zip(df.cclass, df.decade_color))
    lo, hi = y0 - 1.5, y1 + 1.5
    bounds = [Float64(b) for b in 1960:10:2020 if y0 < b <= y1]
    span(c) = c == "vor 1960" ? (lo, min(1960.0, hi)) :
              (d = parse(Float64, c[1:4]); (max(d, lo), min(d + 10.0, hi)))
    mids = [(a + b) / 2 for (a, b) in span.(classes)]
    issorted(mids) || error("decade label slots out of order: $classes")

    set_theme!(klima_theme())
    fig = Figure(; size)
    ax = Axis(fig[1, 1];
        ylabel = "Tage pro Jahr",
        xticks = (mids, classes),
        xticksvisible = false,
        xminorticks = bounds,
        xminorticksvisible = true,
        xminortickcolor = MTICK_COLOR,
        xticklabelcolor = TICK_COLOR,
        xticklabelsize = short ? 12 : 13)
    barplot!(ax, df.x_chrono, df.value; color = df.decade_color, width = 0.8)
    # The line: the early window's record (form A only), in its tag colour;
    # CSS shows it from stage 2 on.
    m.form == :A && hlines!(ax, [m.line]; color = LINE_COLOR, linewidth = 1.2, linestyle = :dash)
    # The titles, all at the same anchor INSIDE the axis (top-left, over the
    # short bars), each in its own taggable colour; CSS cross-fades them with
    # the state. All but the first start hidden via a presentation attribute,
    # which any stylesheet rule can override. Second line: colour key / line label.
    hl = race_headline(df; station, threshold, short)
    anchor = Point2f(0.02, 0.985)
    sub_dy = -(title_fs + 6.0)                       # one line below, in pixels
    function title!(txt, color; fs = title_fs, dy = 0.0, bold = true)
        isempty(txt) && return
        text!(ax, anchor; text = txt, space = :relative, align = (:left, :top),
              font = bold ? :bold : :regular, fontsize = fs, color, offset = (0.0, dy))
    end
    title!(hl.t1, TITLE1_COLOR)
    title!(hl.t2, TITLE2_COLOR)
    title!(hl.t3, TITLE3_COLOR)
    title!(hl.t2b, TITLE2B_COLOR; fs = title_fs - 2, dy = sub_dy, bold = false)
    title!(hl.line_lbl, LINELBL_COLOR; fs = title_fs - 2, dy = sub_dy, bold = false)
    topidx = findall(df.label)
    # Stagger: labels of even sorted rank sit one label-length higher. The
    # offset is in pixels, so it survives every canvas size.
    stagger_px = 2.6 * label_fs + 3
    for i in topidx
        text!(ax, Point2f(df.x_chrono[i], df.value[i] + 0.025 * ymax);
            text = df.running[i] ? "$(df.year[i]) bisher" : string(df.year[i]),
            rotation = pi / 2, align = (:left, :center), fontsize = label_fs,
            offset = (0.0, iseven(df.rank[i]) ? stagger_px : 0.0),
            color = LABEL_COLOR)
    end
    xlims!(ax, lo, hi)
    ylims!(ax, 0, ymax * 1.25)
    ymax < 8 && (ax.yticks = 0:1:ceil(Int, ymax * 1.25))   # days are integers: no "0.5"

    # data-units → pixels, knowable only after layout. Every shift the CSS
    # applies is emitted as a PERCENTAGE of the viewBox, not in px: Safari
    # scales px transforms on SVG elements by the page zoom a second time
    # (measured 2026-09-01 at 125 % zoom: 249.6 for 200), while percentages
    # of the view-box reference box come out right there, in Chrome and in
    # headless WebKit alike.
    Makie.update_state_before_display!(fig)
    vp = ax.scene.viewport[]
    sx = vp.widths[1] / ax.finallimits[].widths[1]
    W, H = size
    pctw(px) = round(px / W * 100; digits = 3)
    pcth(px) = round(px / H * 100; digits = 3)
    dxpct = pctw.((df.x_sorted .- df.x_chrono) .* sx)
    # expected pixel x of each label anchor (Cairo SVG shares Makie's x axis)
    vx0 = vp.origin[1]
    lim0 = ax.finallimits[].origin[1]
    xpix = vx0 .+ (df.x_chrono .- lim0) .* sx
    # decade-label anchors, and where they fly to: an axislegend-style
    # vertical column, top-left inside the plot — empty in both orderings,
    # because the short bars sit left. Labels are centre-anchored, so a
    # centred column costs no width estimation. (SVG y runs downward.)
    midpx = vx0 .+ (mids .- lim0) .* sx
    x_col = vx0 + (short ? 50 : 56)
    # the axislegend column starts BELOW both in-axis title lines
    y_top = H - (vp.origin[2] + vp.widths[2]) + (short ? 58 : 66)
    step = short ? 15.0 : 17.0
    sloty = [y_top + (k - 1) * step for k in 1:K]

    # one scratch file for the whole build: a mktempdir() per render leaves
    # thousands of directories behind until the process exits
    isassigned(SVG_SCRATCH) || (SVG_SCRATCH[] = joinpath(mktempdir(), "race.svg"))
    save(SVG_SCRATCH[], fig)
    svg = strip_prolog(read(SVG_SCRATCH[], String))
    # the percentages above assume the viewBox IS the figure size
    vb = match(r"viewBox=\"0 0 ([\d.]+) ([\d.]+)\"", svg)
    (vb !== nothing && parse(Float64, vb[1]) == W && parse(Float64, vb[2]) == H) ||
        error("SVG viewBox is not 0 0 $W $H — percentage shifts would be off")

    nz = findall(>(0), df.value)          # zero-height bars emit no path
    kbar, nmt, nhl = 0, 0, 0
    svg = replace(svg, r"<path [^>]*/>" => function (tag)
        s = attr_rgbpct(tag, "stroke")
        if color_eq(s, MTICK_COLOR)
            nmt += 1
            return replace(tag, "<path " => "<path class=\"mtick\" "; count = 1)
        elseif color_eq(s, LINE_COLOR)
            nhl += 1
            return replace(tag, "<path " => "<path class=\"hline\" opacity=\"0\" "; count = 1)
        end
        f = attr_rgbpct(tag, "fill")
        f === nothing && return tag
        any(color_eq(f, c) for c in unique(df.decade_color)) || return tag
        kbar += 1
        i = nz[kbar]
        cls = "bar " * (df.win[i] ? "win" : "out") * (df.top[i] ? " top" : " rest") *
              (df.rec[i] ? " rec" : "") * (df.running[i] ? " running" : "")
        replace(tag, "<path " => "<path class=\"$cls\" style=\"--i:$(df.gi[i]);--n:$(df.gn[i]);" *
            "--d:$(df.crank[i]);--dx:$(dxpct[i])%;--cd:$(csshex(df.decade_color[i]))\" "; count = 1)
    end)
    kbar == length(nz) || error("Expected $(length(nz)) bar paths, found $kbar")
    (nmt > 0) == !isempty(bounds) ||
        error("Minor ticks: expected $(isempty(bounds) ? "none" : "some"), tagged $nmt")
    (nhl > 0) == (m.form == :A) ||
        error("Record line: expected $(m.form == :A ? "one" : "none"), tagged $nhl")

    # Rotated label text splits into one <g> per glyph, but the groups come
    # in draw order — consecutive per label — and rotation = π/2 means every
    # glyph of a label shares its x. So: cluster consecutive matches by x;
    # the k-th cluster is the k-th drawn label (topidx is chronological, as
    # is the text! loop). Nearest-anchor matching broke on the phone size,
    # where neighbouring top years sit ~4 px apart.
    klbl, prevx = 0, -1e9
    svg = replace(svg,
        r"<g fill=\"[^\"]+\"[^>]*>\s*<use [^>]*? x=\"[-\d.]+\"" => function (m_)
        f = attr_rgbpct(m_, "fill")
        color_eq(f, LABEL_COLOR) || return m_
        gx = parse(Float64, match(r" x=\"([-\d.]+)\"", m_)[1])
        abs(gx - prevx) > 2.0 && (klbl += 1)
        prevx = gx
        klbl <= length(topidx) || error("More label clusters than labels at x=$gx")
        i = topidx[klbl]
        abs(gx - xpix[i]) <= 14 ||
            error("Label cluster $klbl (year $(df.year[i])) at x=$gx, anchor $(round(xpix[i]; digits=1)) — order assumption broken?")
        replace(m_, "<g " =>
            "<g class=\"lbl2$(df.rec[i] ? " rec" : "")\" style=\"--dx:$(dxpct[i])%\" "; count = 1)
    end)
    klbl == length(topidx) || error("Expected $(length(topidx)) label clusters, found $klbl")
    # Decade labels: horizontal text splits into glyph groups at *different*
    # x, and an edge label can poke across its boundary interval, so neither
    # nearest-slot nor interval lookup is safe at phone widths. But there are
    # exactly K labels: collect every tick-coloured glyph x, sort, and split
    # at the K-1 largest gaps — within-label spacing is always tighter than
    # the space between labels. Clusters left→right are slots 1..K.
    dlabel_re = r"<g fill=\"[^\"]+\"[^>]*>\s*<use [^>]*? x=\"[-\d.]+\" y=\"[-\d.]+\""
    is_tick(m_) = color_eq(attr_rgbpct(m_, "fill"), TICK_COLOR)
    gxs = sort([parse(Float64, match(r" x=\"([-\d.]+)\"", mm.match)[1])
                for mm in eachmatch(dlabel_re, svg) if is_tick(mm.match)])
    length(gxs) >= K || error("Only $(length(gxs)) decade-label glyph groups for $K labels")
    gaps = sortperm(diff(gxs); rev = true)[1:(K - 1)]
    bcuts = sort([(gxs[g] + gxs[g + 1]) / 2 for g in gaps])
    slot_of(x) = count(<(x), bcuts) + 1
    hitd = zeros(Int, K)
    svg = replace(svg, dlabel_re => function (m_)
        is_tick(m_) || return m_
        gx = parse(Float64, match(r" x=\"([-\d.]+)\"", m_)[1])
        gy = parse(Float64, match(r" y=\"([-\d.]+)\"", m_)[1])
        k = slot_of(gx)
        hitd[k] += 1
        fx = pctw(x_col - midpx[k])
        fy = pcth(sloty[k] - gy)
        lc = label_colors([class_color[classes[k]]])[1]   # darker: it is 13 px text
        replace(m_, "<g " => "<g class=\"dlabel\" style=\"--d:$(k - 1);" *
            "--cd:$(csshex(lc));--fx:$(fx)%;--fy:$(fy)%\" "; count = 1)
    end)
    all(>(0), hitd) || error("Some decade labels untagged: $(classes[hitd .== 0])")
    # The title texts and the line label: tag every glyph group; all but t1
    # start hidden.
    nt = Dict(:t1 => 0, :t2 => 0, :t2b => 0, :t3 => 0, :hlbl => 0)
    svg = replace(svg, r"<g fill=\"[^\"]+\"[^>]*>" => function (tag)
        f = attr_rgbpct(tag, "fill")
        cls = color_eq(f, TITLE1_COLOR) ? :t1 :
              color_eq(f, TITLE2_COLOR) ? :t2 :
              color_eq(f, TITLE2B_COLOR) ? :t2b :
              color_eq(f, TITLE3_COLOR) ? :t3 :
              color_eq(f, LINELBL_COLOR) ? :hlbl : nothing
        cls === nothing && return tag
        nt[cls] += 1
        cls == :t1 ? replace(tag, "<g " => "<g class=\"t1\" "; count = 1) :
                     replace(tag, "<g " => "<g class=\"$cls\" opacity=\"0\" "; count = 1)
    end)
    (nt[:t1] > 0 && nt[:t2] > 0 && nt[:t2b] > 0) || error("Title tagging failed: $nt")
    (nt[:t3] > 0) == m.sortable ||
        error("Rank title: expected $(m.sortable ? "some" : "none"), tagged $(nt[:t3])")
    (nt[:hlbl] > 0) == (m.form == :A) ||
        error("Line label: expected $(m.form == :A ? "some" : "none"), tagged $(nt[:hlbl])")

    flags = (m.form == :A ? " hasline" : "") * (m.sortable ? " sortable" : "")
    out = replace(svg,
        r"<svg ([^>]*?)width=\"[^\"]*\" height=\"[^\"]*\" " =>
        SubstitutionString("<svg class=\"chart$flags\" style=\"--n:$n\" role=\"img\" " *
                           "aria-label=\"$(hl.t2). $(uppercasefirst(hl.t2b)).\" \\1"))
    occursin("class=\"chart", out) ||
        error("SVG root not rewritten — did Cairo change its attribute order?")
    out
end

# ╔═╡ 00c19079-e4ea-4f39-81f2-befb103dbf1f
"""
Cairo embeds every glyph outline it uses as `<g id="glyph-…"><path d=…/></g>`
in each SVG's `<defs>` — about 85 KB per chart, and six charts on a station
page share nearly all of them. Move the outlines into one hidden `<svg>` per
page, keyed by outline, and rewrite the `<use>` references. Returns the
rewritten SVGs and the shared defs block (place it anywhere in the same
document — `href="#id"` resolves document-wide).
"""
function dedupe_glyphs(svgs::AbstractVector{<:AbstractString})
    shared = Dict{String,String}()               # outline => shared id
    defs = String[]
    # a space glyph is an EMPTY group — no <path> at all — hence the optional part
    glyph_re = r"<g id=\"(glyph-[^\"]+)\">\s*(?:<path d=\"([^\"]*)\"/>)?\s*</g>\s*"
    out = map(svgs) do svg
        local_ids = Dict{String,String}()
        for m in eachmatch(glyph_re, svg)
            d = something(m[2], "")
            sid = get!(shared, d) do
                s = "gl$(length(defs))"
                push!(defs, isempty(d) ? "<g id=\"$s\"></g>" : "<g id=\"$s\"><path d=\"$d\"/></g>")
                s
            end
            local_ids[m[1]] = sid
        end
        stripped = replace(svg, glyph_re => "")
        nuse, nmiss = 0, 0
        stripped = replace(stripped, r"xlink:href=\"#(glyph-[^\"]+)\"" => function (m)
            id = match(r"#(glyph-[^\"]+)", m)[1]
            nuse += 1
            haskey(local_ids, id) || (nmiss += 1; return m)
            "xlink:href=\"#$(local_ids[id])\""
        end)
        nmiss == 0 || error("dedupe_glyphs: $nmiss <use> references to unknown glyphs")
        nuse > 0 || error("dedupe_glyphs: no glyph references found — SVG structure changed?")
        occursin("id=\"glyph-", stripped) && error("dedupe_glyphs: glyph definitions left behind")
        stripped
    end
    block = "<svg class=\"glyphs\" aria-hidden=\"true\" focusable=\"false\" " *
            "xmlns=\"http://www.w3.org/2000/svg\"><defs>" * join(defs) * "</defs></svg>"
    (; svgs = out, defs = block)
end

# ╔═╡ 6a780ea1-beaa-4ce4-a9d6-36e49e6c2659
begin
    "One timing table shared by the CSS and the pause logic in the JS."
    function race_times()
        t_win, win_span = 0.2, 1.6                                # window bars, staggered
        t_reclbl = round(t_win + win_span + 0.2; digits = 2)      # the record year's label
        t_line = round(t_reclbl + 0.8; digits = 2)                # the line
        # REST on the line: its label is a sentence, and this is the moment
        # the memory is conceded — the reader must get to read it (Fabian)
        t_rest, rest_span = round(t_line + 3.4; digits = 2), 2.0  # every other year
        t_lbl = round(t_rest + rest_span + 0.2; digits = 2)       # their year labels
        t_end3 = round(t_lbl + 0.8 + 1.5; digits = 2)             # a chart without stage 4 ends here
        t_move = round(t_lbl + 0.8 + 2.0; digits = 2)             # REST in place, then sort
        t_arr = round(t_move + 2.0; digits = 2)
        (; t_win, win_span, t_reclbl, t_line, t_rest, rest_span, t_lbl, t_end3, t_move, t_arr)
    end

    """
    The chart's stylesheet: auto-play timeline, the manual state machine, the
    arrows, the stacked threshold panels. Station-independent — the site
    serves it once for every page — so it assumes the container `.racebox`,
    the state radios `sa s1 s2 s3 s4`, the threshold radios `th-<t>`, and per
    threshold the racebox flags `empty-<t>` (nothing to race), `noline-<t>`
    (form C: no stage 2) and `nosort-<t>` (no stage 4). The SVG itself
    carries `hasline`/`sortable`, so its keyframes only exist where they mean
    something.

    Stages: 1 the early window, its record year coloured and labelled — 2 the
    line at the record — 3 every other year, coloured where it reaches the
    line, year labels, decade labels take colour — 4 (if the focus year is
    coloured but not the tallest) sort by height, decade labels fly into the
    axislegend column.

    Auto-play first, then hand control to the user. A hidden radio `sa`
    ("auto", checked on load) scopes the timed keyframe timeline. The first
    arrow click (or swipe, or the script's handover at the end) checks a
    manual state radio: the keyframes vanish with `#sa:checked`, the state
    rules take over, and CSS transitions interpolate from the before-change
    style — which by spec includes animation effects — so the handoff is
    seamless, and every manual move plays forwards or backwards.

    The threshold panels are STACKED in one grid cell and hidden with
    `visibility`, not `display`: a hidden panel keeps its box, so its
    animations and transitions run on the same clock as the visible one, and
    a threshold switch shows the other data at the very same step — during
    auto-play, in a manual state, afterwards. Comparing, not watching.
    """
    function race_css(; thresholds = [25, 30, 35], gray = csshex(GRAY))
        T = race_times()
        ease = "cubic-bezier(.4, 0, .2, 1)"
        t2_in = round(T.t_rest + 0.3; digits = 2)
        t3_in = round(T.t_move + 0.3; digits = 2)
        """
        /* ------------------------------------------------ bar race */
        .racebox { --gray: $gray; }
        .racebox > input { position: absolute; opacity: 0; pointer-events: none; }
        .racenav { position: relative; display: flex; align-items: center;
          justify-content: center; margin: 4px 0 6px; min-height: 38px; }
        .racenav label { display: none; position: absolute; top: 2px; width: 34px;
          height: 34px; border: 1px solid var(--rule, #d0d0d0); border-radius: 50%;
          cursor: pointer; font-size: 20px; line-height: 31px; text-align: center;
          background: var(--paper, #fff); user-select: none; }
        .racenav label.prev { left: 0; }
        .racenav label.next { right: 0; }
        .racenav label.again, .racenav label.pause { left: 50%; margin-left: -17px; }
        .racenav label:hover { background: var(--soft, #f2f2f2); }
        .panels { display: grid; position: relative; }
        .panel { grid-area: 1 / 1; visibility: hidden; }
        .glyphs { position: absolute; width: 0; height: 0; overflow: hidden; }
        $(join(["#th-$t:checked ~ .panels .panel-$t { visibility: visible; }\n" for t in thresholds]))
        /* a threshold the station never reached: the panel is a sentence, so
           nothing to play or step through — the racebox carries `empty-<t>` */
        $(join(["""
        .empty-$t > #th-$t:checked ~ .racenav, .empty-$t > #th-$t:checked ~ .cap,
        .empty-$t > #th-$t:checked ~ .vsnote { display: none; }
        """ for t in thresholds]))
        .chart { width: 100%; height: auto; display: block; }

        .chart .bar { fill: var(--gray); opacity: 0;
          transition: opacity 0.5s ease-out, transform 1.6s $ease; }
        .chart .bar.top { fill: var(--cd); }
        .chart .bar.running { stroke: #333; stroke-width: 1.5px; }
        .chart .lbl2 { opacity: 0;
          transition: opacity 0.6s ease-out, transform 1.6s $ease; }
        .chart .dlabel {
          transition: fill 0.6s ease-in-out, transform 1.6s $ease; }
        .chart .mtick { transition: opacity 0.6s ease-in-out; }
        .chart .hline { transition: opacity 0.6s ease-in-out; }
        .chart .t1, .chart .t2, .chart .t2b, .chart .t3, .chart .hlbl { transition: opacity 0.5s ease-in-out; }

        /* ---------- auto-play (default state) ---------- */
        #sa:checked ~ .panels .bar.win { animation: appear 0.5s ease-out forwards;
          animation-delay: calc(var(--i) / var(--n) * $(T.win_span)s + $(T.t_win)s); }
        #sa:checked ~ .panels .bar.out { animation: appear 0.5s ease-out forwards;
          animation-delay: calc(var(--i) / var(--n) * $(T.rest_span)s + $(T.t_rest)s); }
        #sa:checked ~ .panels .sortable .bar.win {
          animation: appear 0.5s ease-out forwards, move 1.8s $ease forwards;
          animation-delay: calc(var(--i) / var(--n) * $(T.win_span)s + $(T.t_win)s), $(T.t_move)s; }
        #sa:checked ~ .panels .sortable .bar.out {
          animation: appear 0.5s ease-out forwards, move 1.8s $ease forwards;
          animation-delay: calc(var(--i) / var(--n) * $(T.rest_span)s + $(T.t_rest)s), $(T.t_move)s; }
        #sa:checked ~ .panels .lbl2 { animation: fadein 0.8s ease-out $(T.t_lbl)s forwards; }
        #sa:checked ~ .panels .lbl2.rec { animation: fadein 0.6s ease-out $(T.t_reclbl)s forwards; }
        #sa:checked ~ .panels .sortable .lbl2 {
          animation: fadein 0.8s ease-out $(T.t_lbl)s forwards, move 1.8s $ease $(T.t_move)s forwards; }
        #sa:checked ~ .panels .sortable .lbl2.rec {
          animation: fadein 0.6s ease-out $(T.t_reclbl)s forwards, move 1.8s $ease $(T.t_move)s forwards; }
        #sa:checked ~ .panels .hline { animation: fadein 0.6s ease-in-out $(T.t_line)s forwards; }
        #sa:checked ~ .panels .hlbl {
          animation: fadein 0.5s ease-out $(T.t_line)s forwards, fadeout 0.4s ease-out $(T.t_rest)s forwards; }
        #sa:checked ~ .panels .dlabel { animation: recolor-lbl 0.5s ease-in-out forwards;
          animation-delay: calc($(T.t_rest)s + var(--d) * 0.15s); }
        #sa:checked ~ .panels .sortable .dlabel {
          animation: recolor-lbl 0.5s ease-in-out forwards, fly 1.6s $ease forwards;
          animation-delay: calc($(T.t_rest)s + var(--d) * 0.15s), $(T.t_move)s; }
        #sa:checked ~ .panels .sortable .mtick { animation: fadeout 0.6s ease-in-out $(T.t_move)s forwards; }
        #sa:checked ~ .panels .t1 { animation: fadeout 0.5s ease-out $(T.t_rest)s forwards; }
        #sa:checked ~ .panels .t2, #sa:checked ~ .panels .t2b { animation: fadein 0.5s ease-out $(t2_in)s forwards; }
        #sa:checked ~ .panels .sortable .t2 {
          animation: fadein 0.5s ease-out $(t2_in)s forwards, fadeout 0.5s ease-out $(T.t_move)s forwards; }
        #sa:checked ~ .panels .t3 { animation: fadein 0.5s ease-out $(t3_in)s forwards; }
        /* when the run is over: the back arrow and ⟳ appear (the script hands
           over to the last state at the same moment; without it these rules do the job) */
        #sa:checked ~ .racenav .prev[data-at="a"] { display: block; opacity: 0;
          animation: fadein 0.4s ease-out $(T.t_arr)s forwards; }
        #sa:checked ~ .racenav .again { display: block; opacity: 0; pointer-events: none;
          animation: fadein 0.4s ease-out $(T.t_arr)s forwards, arm 0s linear $(T.t_arr)s forwards; }
        .js > #sa:checked ~ .racenav .pause { display: block;
          animation: fadeout 0.3s ease-out $(T.t_arr)s forwards, disarm 0s linear $(T.t_arr)s forwards; }
        /* no stage 4 for this threshold: the run ends earlier, and the back
           arrow leads to stage 2 — or to stage 1 without a line */
        $(join(["""
        .nosort-$t > #th-$t:checked ~ #sa:checked ~ .racenav .prev[data-at="a"] { display: none; }
        .nosort-$t > #th-$t:checked ~ #sa:checked ~ .racenav .prev[data-at="a3"] { display: block; opacity: 0;
          animation: fadein 0.4s ease-out $(T.t_end3)s forwards; }
        .nosort-$t.noline-$t > #th-$t:checked ~ #sa:checked ~ .racenav .prev[data-at="a3"] { display: none; }
        .nosort-$t.noline-$t > #th-$t:checked ~ #sa:checked ~ .racenav .prev[data-at="a3s"] { display: block; opacity: 0;
          animation: fadein 0.4s ease-out $(T.t_end3)s forwards; }
        .nosort-$t > #th-$t:checked ~ #sa:checked ~ .racenav .again { animation-delay: $(T.t_end3)s, $(T.t_end3)s; }
        .js.nosort-$t > #th-$t:checked ~ #sa:checked ~ .racenav .pause { animation-delay: $(T.t_end3)s, $(T.t_end3)s; }
        """ for t in thresholds]))

        @keyframes appear      { to { opacity: 1; } }
        @keyframes recolor-lbl { to { fill: var(--cd); } }
        @keyframes move        { to { transform: translateX(var(--dx)); } }
        @keyframes fly         { to { transform: translate(var(--fx), var(--fy)); } }
        @keyframes fadein      { to { opacity: 1; } }
        @keyframes fadeout     { to { opacity: 0; } }
        @keyframes arm         { to { pointer-events: auto; } }
        @keyframes disarm      { to { pointer-events: none; } }

        /* ---------- manual states ---------- */
        #s1:checked ~ .panels .bar.win, #s2:checked ~ .panels .bar.win,
        #s3:checked ~ .panels .bar, #s4:checked ~ .panels .bar { opacity: 1; }
        #s3:checked ~ .panels .bar.out { transition-delay: calc(var(--i) / var(--n) * 0.8s), 0s; }
        #s1:checked ~ .panels .lbl2.rec, #s2:checked ~ .panels .lbl2.rec,
        #s3:checked ~ .panels .lbl2, #s4:checked ~ .panels .lbl2 { opacity: 1; }
        #s3:checked ~ .panels .lbl2 { transition-delay: 0.9s, 0s; }
        #s2:checked ~ .panels .hline, #s3:checked ~ .panels .hline,
        #s4:checked ~ .panels .hline { opacity: 1; }
        #s2:checked ~ .panels .hlbl { opacity: 1; }
        #s3:checked ~ .panels .dlabel, #s4:checked ~ .panels .dlabel { fill: var(--cd);
          transition-delay: calc(var(--d) * 0.12s), 0s; }
        #s4:checked ~ .panels .sortable .bar,
        #s4:checked ~ .panels .sortable .lbl2   { transform: translateX(var(--dx)); }
        #s4:checked ~ .panels .sortable .dlabel { transform: translate(var(--fx), var(--fy)); }
        #s4:checked ~ .panels .sortable .mtick  { opacity: 0; }
        #s3:checked ~ .panels .t1, #s4:checked ~ .panels .t1 { opacity: 0; }
        #s3:checked ~ .panels .t2, #s4:checked ~ .panels .t2,
        #s3:checked ~ .panels .t2b, #s4:checked ~ .panels .t2b { opacity: 1; }
        #s4:checked ~ .panels .sortable .t2 { opacity: 0; }
        #s4:checked ~ .panels .t3 { opacity: 1; }

        /* arrows per state; the per-threshold flags reroute them */
        #s1:checked ~ .racenav .next[data-at="1"],
        #s2:checked ~ .racenav .prev[data-at="2"], #s2:checked ~ .racenav .next[data-at="2"],
        #s3:checked ~ .racenav .prev[data-at="3"], #s3:checked ~ .racenav .next[data-at="3"],
        #s4:checked ~ .racenav .prev[data-at="4"],
        #s1:checked ~ .racenav .again, #s2:checked ~ .racenav .again,
        #s3:checked ~ .racenav .again, #s4:checked ~ .racenav .again { display: block; }
        $(join(["""
        .noline-$t > #th-$t:checked ~ #s1:checked ~ .racenav .next[data-at="1"] { display: none; }
        .noline-$t > #th-$t:checked ~ #s1:checked ~ .racenav .next[data-at="1s"] { display: block; }
        .noline-$t > #th-$t:checked ~ #s3:checked ~ .racenav .prev[data-at="3"] { display: none; }
        .noline-$t > #th-$t:checked ~ #s3:checked ~ .racenav .prev[data-at="3s"] { display: block; }
        .nosort-$t > #th-$t:checked ~ #s3:checked ~ .racenav .next[data-at="3"] { display: none; }
        .nosort-$t > #th-$t:checked ~ #s4:checked ~ .racenav .prev[data-at="4"] { display: none; }
        .nosort-$t > #th-$t:checked ~ #s4:checked ~ .racenav .prev[data-at="3"] { display: block; }
        .nosort-$t.noline-$t > #th-$t:checked ~ #s4:checked ~ .racenav .prev[data-at="3"] { display: none; }
        .nosort-$t.noline-$t > #th-$t:checked ~ #s4:checked ~ .racenav .prev[data-at="3s"] { display: block; }
        """ for t in thresholds]))

        @media (prefers-reduced-motion: reduce) {
          .chart .bar, .chart .lbl2, .chart .dlabel, .chart .mtick, .chart .hline,
          .chart .t1, .chart .t2, .chart .t2b, .chart .t3, .chart .hlbl { animation: none; transition: none; }
          #sa:checked ~ .panels .bar, #sa:checked ~ .panels .lbl2, #sa:checked ~ .panels .hline { opacity: 1; }
          #sa:checked ~ .panels .dlabel { fill: var(--cd); }
          #sa:checked ~ .panels .t1 { opacity: 0; }
          #sa:checked ~ .panels .t2, #sa:checked ~ .panels .t2b { opacity: 1; }
          #sa:checked ~ .panels .sortable .bar, #sa:checked ~ .panels .sortable .lbl2 { transform: translateX(var(--dx)); }
          #sa:checked ~ .panels .sortable .dlabel { transform: translate(var(--fx), var(--fy)); }
          #sa:checked ~ .panels .sortable .mtick { opacity: 0; }
          #sa:checked ~ .panels .sortable .t2 { opacity: 0; }
          #sa:checked ~ .panels .t3 { opacity: 1; }
          #sa:checked ~ .racenav .prev[data-at="a"], #sa:checked ~ .racenav .prev[data-at="a3"],
          #sa:checked ~ .racenav .prev[data-at="a3s"] { animation: none; opacity: 1; }
          #sa:checked ~ .racenav .again { opacity: 1; pointer-events: auto; animation: none; }
          .js > #sa:checked ~ .racenav .pause { display: none; }
        }
        """
    end

    "Page chrome for the standalone preview: the site brings its own."
    race_page_css() = """
        body { font-family: system-ui, sans-serif; margin: 0; color: #222; background: #fff; }
        main { max-width: 960px; margin: 0 auto; padding: 24px 16px 64px; }
        .note { font-size: 14px; color: #555; line-height: 1.55; }
        .tabs { display: flex; gap: 6px; margin: 0 0 2px; }
        .tabs label { padding: 5px 13px; border: 1px solid #d0d0d0; border-radius: 999px;
          cursor: pointer; font-size: 14px; background: #fff; user-select: none; }
        .tabs label:hover { background: #f2f2f2; }
        $(join(["#th-$t:checked ~ .tabs label[for=\"th-$t\"] { background: #1b6ca8; border-color: #1b6ca8; color: #fff; }\n"
                for t in [25, 30, 35]]))
        .vs { display: none; }
        @media (max-width: 680px) { .vl { display: none; } .vs { display: block; } }
        """
end

# ╔═╡ 7f0cbe6b-f943-4408-a0a7-efcd95d6c85f
begin
    "The state radios. `sa` (auto-play) is checked on load."
    race_state_inputs() = """
        <input type="radio" name="s" id="sa" checked>
        <input type="radio" name="s" id="s1">
        <input type="radio" name="s" id="s2">
        <input type="radio" name="s" id="s3">
        <input type="radio" name="s" id="s4">"""

    """
    Arrows between the resting states, ⟳ (replay = re-check `sa`), ⏸ (only
    when JS runs; settles at the NEAREST resting state, never mid-transition).
    Which pair shows depends on the checked state and the racebox flags, via
    `data-at`: `1s`/`3s` skip the line stage, `a`/`a3`/`a3s` are the back
    arrow after the auto-play (from stage 4, 3, or 3 without a line).
    """
    race_nav() = """
        <div class="racenav">
        <label class="prev" title="Zurück" for="s1" data-at="2">‹</label>
        <label class="prev" title="Zurück" for="s2" data-at="3">‹</label>
        <label class="prev" title="Zurück" for="s1" data-at="3s">‹</label>
        <label class="prev" title="Zurück" for="s3" data-at="4">‹</label>
        <label class="prev" title="Zurück" for="s3" data-at="a">‹</label>
        <label class="prev" title="Zurück" for="s2" data-at="a3">‹</label>
        <label class="prev" title="Zurück" for="s1" data-at="a3s">‹</label>
        <label class="again" for="sa" title="Neu abspielen">⟳</label>
        <label class="pause" title="Am nächsten Ruhepunkt halten">⏸</label>
        <label class="next" title="Weiter" for="s2" data-at="1">›</label>
        <label class="next" title="Weiter" for="s3" data-at="1s">›</label>
        <label class="next" title="Weiter" for="s3" data-at="2">›</label>
        <label class="next" title="Weiter" for="s4" data-at="3">›</label>
        </div>"""

    """
    The stacked panels, one per threshold, from `threshold => inner html`
    pairs. Glyph outlines are deduplicated across every SVG in `panels`.
    """
    function race_panels(panels::AbstractVector{<:Pair})
        # pull every <svg …>…</svg> out, dedupe, put back
        svg_re = r"<svg class=\"chart.*?</svg>"s
        allsvgs = String[m.match for (_, html) in panels for m in eachmatch(svg_re, html)]
        isempty(allsvgs) && return "<div class=\"panels\">" *
            join(["<div class=\"panel panel-$t\">$html</div>" for (t, html) in panels], "\n") * "</div>"
        dd = dedupe_glyphs(allsvgs)
        k = 0
        rewritten = [t => replace(html, svg_re => (_ -> dd.svgs[k += 1])) for (t, html) in panels]
        k == length(allsvgs) || error("race_panels: replaced $k of $(length(allsvgs)) SVGs")
        "<div class=\"panels\">\n" * dd.defs * "\n" *
        join(["<div class=\"panel panel-$t\">$html</div>" for (t, html) in rewritten], "\n") *
        "\n</div>"
    end

    """
    The deliberate exception to the no-JS rule: swipes, arrow keys, ⏸ and the
    handover after the auto-play are not expressible in CSS. Everything only
    checks the same radios the buttons use; without JS the arrows still work,
    ⏸ never appears and ⟳ fades in by itself. The per-threshold flags on the
    racebox (`noline-<t>`, `nosort-<t>`) decide which stages exist, read at
    the moment of the move — the user can switch thresholds mid-run. Scoped
    to the `.racebox` element, and arrow keys are ignored while a form field
    has focus.
    """
    function race_script()
        T = race_times()
        m1 = round((T.t_reclbl + T.t_line) / 2; digits = 2)          # s1|s2 midpoint
        m2 = round((T.t_line + T.t_rest) / 2; digits = 2)            # s2|s3 midpoint
        m3 = round((T.t_lbl + 0.8 + T.t_move) / 2; digits = 2)       # s3|s4 midpoint
        """
        <script>
        (function () {
          var box = document.querySelector(".racebox");
          if (!box) return;
          var el = function (id) { return box.querySelector("#" + id); };
          var hand = [], t0 = performance.now();
          function flags() {
            var th = box.querySelector('input[name="th"]:checked');
            var t = th ? th.id.replace("th-", "") : "";
            return { noline: box.classList.contains("noline-" + t),
                     nosort: box.classList.contains("nosort-" + t) };
          }
          function armHandover() {          // the run ends in its last state: make it official
            hand.forEach(clearTimeout);
            hand = [
              setTimeout(function () { if (el("sa").checked && flags().nosort) el("s3").click(); }, $(T.t_end3) * 1000),
              setTimeout(function () { if (el("sa").checked) el(flags().nosort ? "s3" : "s4").click(); }, $(T.t_arr) * 1000)
            ];
          }
          armHandover();
          el("sa").addEventListener("change", function () { t0 = performance.now(); armHandover(); });   // ⟳ resets the clock
          var order = ["s1", "s2", "s3", "s4"];
          function nav(fwd) {
            var f = flags();
            var cur = order.findIndex(function (id) { return el(id).checked; });
            if (cur < 0) cur = f.nosort ? 2 : 3;      // auto-play ends in the last state
            if (cur === 3 && f.nosort) cur = 2;       // stage 4 reached via a threshold switch
            var t = null;
            if (fwd) {
              if (cur === 0) t = f.noline ? "s3" : "s2";
              else if (cur === 1) t = "s3";
              else if (cur === 2 && !f.nosort) t = "s4";
            } else {
              if (cur === 3) t = "s3";
              else if (cur === 2) t = f.noline ? "s1" : "s2";
              else if (cur === 1) t = "s1";
            }
            if (t) el(t).click();
          }
          box.classList.add("js");             // reveals ⏸ only when JS runs
          box.querySelector(".pause").addEventListener("click", function () {
            var e = (performance.now() - t0) / 1000, f = flags();
            el(e < $m1 ? "s1" : e < $m2 ? (f.noline ? "s1" : "s2") :
               e < $m3 ? "s3" : (f.nosort ? "s3" : "s4")).click();
          });
          var x0 = null;
          box.addEventListener("touchstart", function (e) {
            x0 = e.touches[0].clientX;
          }, { passive: true });
          box.addEventListener("touchend", function (e) {
            if (x0 === null) return;
            var dx = e.changedTouches[0].clientX - x0;
            x0 = null;
            if (Math.abs(dx) < 40) return;
            nav(dx < 0);                       // swipe left = forward
          }, { passive: true });
          document.addEventListener("keydown", function (e) {
            if (e.target && e.target.closest && e.target.closest("input, textarea, select, button")) return;
            if (e.key === "ArrowRight") nav(true);
            else if (e.key === "ArrowLeft") nav(false);
          });
        })();
        </script>"""
    end
end

# ╔═╡ f7aa03c0-7329-49d5-8a0e-361410830235
begin
    """
    Two pre-rendered sizes per chart, switched by media query (the site's
    `.vs`/`.vl` convention). The canvas is what matters: an 860 px figure
    scaled into a 360 px phone renders 9 px labels at about 4 px. Both sizes
    colour the same years; the phone canvas labels them only up to
    `label_max`, beyond that just the record year and the running one.
    """
    const RACE_VARIANTS = [
        (; cls = "vs", size = (440, 340), label_max = 14, label_fs = 8, title_fs = 12, short = true),
        (; cls = "vl", size = (860, 430), label_max = 60, label_fs = 9, title_fs = 15, short = false),
    ]

    "The sentence a panel shows when the threshold was never reached."
    race_empty_html(threshold) = """<p class="muted">An dieser Station wurde in der
        ganzen Messreihe noch kein Tag mit mindestens $threshold °C gemessen.</p>"""

    """
    Per threshold, what the racebox must know as classes: `empty` (nothing to
    race), `noline` (form C: no stage 2), `nosort` (no stage 4).
    """
    race_flags(annual, thresholds; late = late_window(annual)) =
        Dict(t => begin
                 df = bar_race_data(annual; threshold = t, late)
                 m = race_meta(df)
                 (; empty = race_empty(df), noline = m.form != :A, nosort = !m.sortable)
             end for t in thresholds)

    "The racebox class string from `race_flags`: ` empty-35 noline-35 nosort-30 …`."
    race_classes(flags) = join([" $k-$t" for (t, f) in sort(collect(flags); by = first)
                                for (k, v) in pairs(f) if v])

    """
    The inner HTML of one threshold panel for a station: both size variants,
    or a sentence when the threshold was never reached.
    """
    function race_panel_html(annual, station, threshold; late = late_window(annual), variants = RACE_VARIANTS)
        race_empty(bar_race_data(annual; threshold, late)) && return race_empty_html(threshold)
        join([begin
            df = bar_race_data(annual; threshold, late, label_max = v.label_max)
            "<div class=\"$(v.cls)\">" *
            css_bar_race_svg(df; station, threshold, size = v.size, label_fs = v.label_fs,
                             title_fs = v.title_fs, short = v.short) * "</div>"
        end for v in variants])
    end

    "Standalone preview page — open directly, no server needed."
    function css_bar_race_interactive(annual; path, station, thresholds = [25, 30, 35], default = 30)
        late = late_window(annual)
        panels = [t => race_panel_html(annual, station, t; late) for t in thresholds]
        thinputs = join(["<input type=\"radio\" name=\"th\" id=\"th-$t\"$(t == default ? " checked" : "")>"
                         for t in thresholds], "\n")
        tabs = join(["<label for=\"th-$t\">$(day_term(t)) ≥ $t °C</label>" for t in thresholds], "\n")
        html = """
        <!doctype html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>$station — sortierte Balken (Vorschau)</title>
        <style>$(race_page_css())$(race_css(; thresholds))</style>
        </head>
        <body>
        <main>
        <h1>$station</h1>
        <div class="racebox$(race_classes(race_flags(annual, thresholds; late)))">
        $thinputs
        $(race_state_inputs())
        <div class="tabs">$tabs</div>
        $(race_nav())
        $(race_panels(panels))
        </div>
        $(race_script())
        <p class="note">Alle Messjahre. $(year(today())) läuft noch, ist umrahmt, sein Wert
        kann nur steigen. Quelle: GeoSphere Austria Data Hub, Datensatz klima-v2-1d,
        Parameter tlmax. Vorschau aus notebooks/bar_race.jl — die Site baut dieselben
        Funktionen.</p>
        </main>
        </body>
        </html>
        """
        write(path, html)
        path
    end
end

# ╔═╡ 36cbf40d-c0d8-44bc-a48b-41b75551eeb0
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## Erzeugen

Im Skriptmodus läuft die Zelle unten automatisch. In Pluto: auskommentierte
Zeile ausführen. `video = true` rendert zusätzlich das mp4 (langsam).
"""
  ╠═╡ =#

# ╔═╡ 339650d1-b017-4278-9173-5e902279753f
function generate(; station = "Krems", threshold = 30, video = false)
    mkpath(OUTDIR)
    slug = lowercase(replace(station, r"[^A-Za-z0-9]+" => "-"))
    annual = @chain joinpath(DATADIR, "heat_days.csv") begin
        CSV.read(DataFrame)
        @subset(:station_name == station)
    end
    nrow(annual) > 0 || error("No rows for station $station")
    inter = css_bar_race_interactive(annual;
        path = joinpath(OUTDIR, "bar_race_$(slug)_interaktiv.html"), station, default = threshold)
    mp4 = nothing
    if video
        df = bar_race_data(annual; threshold)
        mp4 = record_bar_race(df; path = joinpath(OUTDIR, "bar_race_$(slug)_$(threshold).mp4"),
                              station, threshold)
    end
    @info "Generated" inter mp4 years = nrow(annual)
    (; inter, mp4)
end

# ╔═╡ c1826165-687c-493c-a5e3-734b76e62ab1
# ╠═╡ skip_as_script = true
#=╠═╡
# generate()   # run manually in Pluto; the script entry point below does it in CI/shell
  ╠═╡ =#

# ╔═╡ 1ce7f9e4-dd23-47dc-b778-2034911c7b56
if abspath(PROGRAM_FILE) == @__FILE__
    generate()
end

# ╔═╡ 75f9ad23-c198-462c-a1ef-e8b0624e0849
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## Befund Makie vs. CSS (2026-09-01)

- **Makie:** alles machbar, nichts geschenkt. Observables + `record` tragen
  die Mechanik, aber Staffelung, Easing und die Sortier-Interpolation sind
  handgeschrieben (~60 Zeilen). Ergebnis ist ein Video: überall abspielbar,
  auch als Social-Media-Schnipsel, aber Pixel statt Vektor und kein Replay
  per Schwellen-Wechsel.
- **CSS:** dieselbe Timeline deklarativ, weil *beide* Anordnungen zur
  Bauzeit bekannt sind — `--dx` pro Balken ist der ganze Trick. Fügt sich
  direkt in die bestehende Tagging-Pipeline der Site ein (gleiche
  Bau-Assertions), bleibt scharf, und mit Transitions statt Keyframes ist
  Rückwärtsspielen gratis.
- Vorsicht Cross-Browser: der nahtlose Übergang Keyframes → Transitions
  (Transition startet laut Spec vom animierten Vorzustand) ist in Chrome
  verifiziert, in Safari/Firefox nicht.
"""
  ╠═╡ =#

# ╔═╡ Cell order:
# ╟─2533912d-86df-4200-bd83-9e341b3002c1
# ╠═b020f744-ab95-4b09-9423-4a0bda37118c
# ╠═00222757-a3aa-4c5b-9bc7-a5cd1a076978
# ╠═c7c96eba-3c2f-4120-9bff-f3cefa36fd07
# ╠═fa9d6e56-1e88-4d48-8068-6a876a459c67
# ╠═9f8aa9c0-9dc4-45a5-9c97-908d1953253a
# ╠═720912c1-56cd-4986-82d5-a63992d9653c
# ╟─09033923-0a17-4f2b-ae79-c7f74d8eb31c
# ╠═3730929a-5791-4ee1-a699-bee50ca2fa5a
# ╟─cc787e0e-2950-4e65-b25a-b8315b8724db
# ╠═9e6f8958-7cc3-4034-bad3-5c177d5deb23
# ╠═4f1caa55-cc0d-4dee-adf7-ce3d15502f3f
# ╠═13a1b7ad-f599-41de-aca1-3e180a908b54
# ╠═00c19079-e4ea-4f39-81f2-befb103dbf1f
# ╠═6a780ea1-beaa-4ce4-a9d6-36e49e6c2659
# ╠═7f0cbe6b-f943-4408-a0a7-efcd95d6c85f
# ╠═f7aa03c0-7329-49d5-8a0e-361410830235
# ╟─36cbf40d-c0d8-44bc-a48b-41b75551eeb0
# ╠═339650d1-b017-4278-9173-5e902279753f
# ╟─c1826165-687c-493c-a5e3-734b76e62ab1
# ╠═1ce7f9e4-dd23-47dc-b778-2034911c7b56
# ╟─75f9ad23-c198-462c-a1ef-e8b0624e0849
