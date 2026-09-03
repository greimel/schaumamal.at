### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ 1efe96c5-5422-46d9-8bd1-9c7e44cad69d
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
# Das Reel — die Hitzetage-Grafik als Kurzvideo

Fabians Vorgabe (2026-09-03): Die Grafik soll wie ein Reel aussehen, der Text
wie dessen Untertitel. Die Geschichte in sieben Bildern, hier „Frames":

1. „‚Heiße Sommer hat's früher auch schon gegeben.' · ⏎ Stimmt." — auf leerer
   Karte. Entfällt, wo der Höchstwert unter fünf Tagen liegt (35 Grad fast
   überall).
2. „Schauen wir uns 1961–1990 an. · ⏎ Die meisten Hitzetage (22) gab es 1971
   und 1983." — der Chart zeichnet sich mit den ersten Worten: die Balken
   1961–1990 auf blassem Blau, das heißeste Jahr blau, die Linie auf seiner
   Höhe; beim zweiten Teil sein Label.
3. „Schauen wir uns die letzten 30 Jahre an." — 1997–2026 erscheinen grau
   auf blassem Orange, was über der Linie liegt, färbt sich orange; 2026
   umrahmt als „(bisher)".
4. „12 der letzten 30 Jahre waren extremer als 1971 und 1983."
5. „Was früher eine Ausnahme war, · ist heute nichts Besonderes mehr."
6. „An 98 von 104 Wetterstationen in Österreich · gibt es heute mehr
   Hitzetage als damals." — heute orange, damals blau.
7. „So schaut Klimawandel aus."

Der Punkt ist Fabians `\\pause`: der zweite Teil des Untertitels kommt
verzögert. Jahre außerhalb der beiden Vergleichsfenster — vor 1961 und
1991–1995 — stehen blass daneben; die Achse nennt die Zeiträume. Drei
Fassungen desselben Charts: „ab 1961" (440 px, Standard am Handy), alle
Jahre am Handy (440 px) und alle Jahre breit (900 px, Standard auf breiten
Bildschirmen — mehr Jahre brauchen mehr Platz); ein Knopf schaltet um.

Technik wie bei `bar_race.jl`: CairoMakie zeichnet einmal, ein Post-Pass
taggt Balken, Bänder, Linie und Beschriftungen über eindeutige Farben, und
ein CSS-Zustandsautomat auf versteckten Radios spielt die Frames — erst
automatisch, dann per Tippen (links zurück, rechts weiter, wie bei Stories),
Wischen oder Pfeiltasten. Die Untertitel sind HTML, nicht SVG: sie brauchen
Umbruch, Hervorhebung und große Schrift. Kein Julia im Browser.

`build_prototype.jl` inkludiert dieses Notebook und setzt `reel_box_html`,
`reel_css`, `reel_script` auf die Stationsseiten. Als Skript:
`julia --project notebooks/reel.jl` schreibt Vorschauseiten nach
`notebooks/out/reel_<station>.html`.
"""
  ╠═╡ =#

# ╔═╡ bb21ea12-eede-4b8d-9a3f-54c797bc6b85
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))
end

# ╔═╡ f1dae239-20f6-4ce3-9c3d-14baf5893ec1
# The chart notebook brings CairoMakie, the data libs, theme/terms/windows and
# the SVG helpers (attr_rgbpct, color_eq, csshex, strip_prolog, dedupe_glyphs).
# Its own entry point is guarded by PROGRAM_FILE, so nothing is generated here.
include(joinpath(@__DIR__, "bar_race.jl"))

# ╔═╡ b38b36c5-d595-4569-8858-314c307c0140
begin
    # Three views of the same chart: from the early window on (the reel), every
    # year on a phone canvas, every year on a wide canvas for big screens.
    const REEL_VIEWS = (reel = (440, 300), all = (440, 300), wide = (900, 320))
    const REEL_NF = 7                     # frame slots; a short story skips slot 1
    # seconds per frame; the auto-play timeline and the progress bar come from this
    # Paced for reading (15 characters per second plus half a second) and for
    # one change at a time: no text and no visual start within half a second
    # of each other, except inside a bar stagger. Timing review 2026-09-03.
    const FRAME_DUR = [4.6, 9.4, 6.2, 5.5, 5.4, 6.5, 2.8]
    # the delayed caption parts: `b` after the first part is half read, `c`
    # (slot 2's second line) once the line has been seen
    b_delay(k) = k == 1 ? 3.0 : k == 6 ? 3.2 : 2.4
    const C_DELAY = 5.4
    "Start times of the frames; the last entry is the end of the run."
    frame_starts() = round.(cumsum(vcat(0.0, FRAME_DUR)); digits = 2)
    # the site's phone breakpoint: below it the card shows „ab 1961" first
    const REEL_PHONE_MAX = 680
    # below this old record the opening beat (the concession „Heiße Sommer
    # hat's früher auch schon gegeben") is left out — three days at 35 °C are
    # not that memory; the story then opens on „Schauen wir uns 1961–1990 an"
    const REEL_SHORT_REC = 5

    # Tag colours — near-blacks the post-pass finds by fill/stroke; the CSS sets
    # the real colours. Every pair is > 0.6 % apart per channel.
    const RTAG = (bar = colorant"#161616", line = colorant"#1c1c1c", oldrec = colorant"#121212",
                  focus = colorant"#0e0e0e", hlbl = colorant"#1a1a1a", xlbl = colorant"#242424",
                  bandold = colorant"#282828", bandnew = colorant"#2c2c2c", gapfill = colorant"#303030")
    const REEL_TICK = colorant"#8f949c"    # y tick labels: drawn as is

    "The words the subtitles use: „Tage ab 35 Grad“ — „3 35-Grad-Tage“ stumbles."
    reel_plural(t) = t == 35 ? "Tage ab 35 Grad" : day_term_plain(t)
    reel_sing(t) = t == 35 ? "Tag ab 35 Grad" : day_term_sing(t)

    """
    Where a label fits above the record line in the all-years views: the
    widest run of years with no bar reaching the line and no year label
    nearby, trying `texts` longest first (a text may break lines with
    `\\\\n`); `nothing` when none fits — the legend still names the line.
    Pixel estimates: the plot is roughly `W - 56` wide, a glyph about 0.6 ×
    the font size.
    """
    function line_label_slot(d, rec, lo, hi, W; texts, fs = 10)
        pxy = (W - 56) / (hi - lo)
        labelled = d.year[.!isempty.(d.label)]
        tops = Set(d.year[d.value .>= rec])
        for txt in texts
            lw = 0.6 * fs * maximum(length, split(txt, '\n')) / pxy   # label width in years
            clear(y) = !(y in tops) && all(abs(y - l) > lw / 2 + 2 for l in labelled)
            best, run = (0, 0.0), 0
            for y in ceil(Int, lo):floor(Int, hi)
                run = clear(y) ? run + 1 : 0
                run > best[1] && (best = (run, y - (run - 1) / 2))
            end
            best[1] >= lw + 1 && return (txt, best[2], :center)
        end
        nothing
    end
end

# ╔═╡ 586386a8-8dc2-4a18-914b-97bce43fa21d
begin
    """
    One row per year of one station's annual frame, plus the reel's metadata
    under `reel_meta(df)`. Eras by the station's two comparison windows from
    `windows()` — 1961–1990 and the last 30 complete years site-wide, or the
    first and last 30 measured years where the reference window is missing:
    `:pre` (before the early window), `:old`, `:gap` (between the windows),
    `:new`, `:focus` (the year the story ends on, `focus_year()`, when it lies
    after the late window), `:post`. The reel view shows everything but
    `:pre`; the all-years views everything. Pre, gap and post are drawn
    faint: context, not comparison.

    The old record is `race_line`'s — the early window's, complete years only,
    the same number as the tiles and the sentences on the site. Only complete
    years are drawn and counted at all — a year without its fully measured
    summer shows as a hatched gap (the running year is complete when its
    summer has no hole *so far*). Colour: `cool` for a year of the early
    window at or above the record, `warm` for a year of the late window or
    the focus year strictly above it — the reel says „extremer als", so a
    tie stays grey and is not counted. A record of zero has no line and no
    record year; then
    „extremer" means having such a day at all. `short`: the record is under
    `REEL_SHORT_REC`, the opening beat is skipped.
    """
    function reel_data(annual::AbstractDataFrame; threshold = 30, late = late_window(annual))
        col = Symbol("days_ge_", threshold)
        laufend = year(today())
        df = sort(annual, :year)
        w = windows(annual, late)
        w === nothing && error("reel_data: fewer than 20 complete years")
        # A year without its fully measured summer is a measurement gap, not a
        # (too low) bar (Fabian, 2026-09-03). Ingest judges the running year
        # by its summer *so far*, so „2026 (bisher)" stays while a running
        # year with a hole in its measured summer is hatched like any other.
        span = extrema(Int.(df.year))
        df = df[Bool.(df.complete), :]
        nrow(df) > 0 || error("reel_data: no complete years")
        out = DataFrame(year = Int.(df.year), value = Float64.(df[!, col]), complete = Bool.(df.complete))
        out.running = out.year .== laufend
        focus = focus_year()
        e0, e1 = extrema(Int.(w.e.year))   # the years actually compared, both kinds
        l0, l1 = w.kind == :reference ? (first(late), last(late)) : extrema(Int.(w.l.year))
        rl = race_line(w, threshold)         # the site's rule: same record, same years
        rec, rec_years = rl.rec, rl.rec_years

        era(y) = y < e0 ? :pre : y <= e1 ? :old : y < l0 ? :gap : y <= l1 ? :new :
                 y == focus ? :focus : :post
        out.era = era.(out.year)
        out.cool = (out.era .== :old) .& (out.value .>= max(rec, 1))
        out.warm = in.(out.era, Ref((:new, :focus))) .& (out.value .> rec)
        out.top = out.cool .| out.warm
        out.oldrec = in.(out.year, Ref(Set(rec_years)))
        fi = findfirst(==(focus), out.year)
        out.label = [r.oldrec ? string(r.year) :
                     r.year == focus ? (r.running ? "$(r.year) (bisher)" : string(r.year)) : ""
                     for r in eachrow(out)]

        # stagger index within each era
        out.gi = zeros(Int, nrow(out)); out.gn = ones(Int, nrow(out))
        for e in (:pre, :old, :gap, :new, :post)
            idx = findall(==(e), out.era)
            out.gi[idx] .= 0:(length(idx) - 1)
            out.gn[idx] .= max(length(idx), 1)
        end

        inlate = out[out.era .== :new, :]
        pre_over = sort(out[(out.era .== :pre) .& (out.value .> rec), :], :value; rev = true)
        # runs of years with no row at all — hatched in the chart (Fabian,
        # 2026-09-03): a year without measurement is not a zero
        gaps = Tuple{Int,Int}[]
        for y in sort(setdiff(span[1]:span[2], out.year))
            !isempty(gaps) && gaps[end][2] == y - 1 ? (gaps[end] = (gaps[end][1], y)) : push!(gaps, (y, y))
        end
        metadata!(out, "reel", (; threshold, rec, rec_years, e0, e1, l0, l1, kind = w.kind,
                                  e_span = w.e_span, l_span = w.l_span, since = w.since,
                                  n_gt = count(>(rec), inlate.value),
                                  # reference: the 30 calendar years; fallback: the *available*
                                  # (measured) years since the cut — the captions say so
                                  n_late = w.kind == :reference ? l1 - l0 + 1 : nrow(inlate),
                                  focus, focus_present = fi !== nothing, focus_running = focus == laufend,
                                  y0 = span[1], ylast = span[2], short = rec < REEL_SHORT_REC, gaps,
                                  pre_over = collect(zip(pre_over.year, Int.(pre_over.value)))); style = :note)
        out
    end
    reel_meta(df) = metadata(df, "reel")
end

# ╔═╡ d36251bb-e3f0-4283-afd2-e14e496d47f8
begin
    hl(cls, s) = "<em class=\"$cls\">$s</em>"
    bb(s) = "<b>$s</b>"

    """
    The subtitles as `slot => (a, b, c)` triples — `b` is what comes after
    Fabian's `\\pause` and fades in later, `c` a second pause on a new line
    (empty where unused) — plus `prenote`, the sentence for
    below the card about the years before the early window that beat the old
    record. Numbers as digits: these are subtitles, not prose. `national` is
    the country-wide sentence of slot 6 as its two parts. A short story (old record under
    `REEL_SHORT_REC`) has no slot 1 and opens on „Schauen wir uns … an".

    Every case the data has is worded here — a record of zero, a tie of any
    size, none or one or two years above the record — so a station page never
    fails for want of words.
    """
    function reel_captions(m; national, flat = nothing)
        t = m.threshold
        plural, sing = reel_plural(t), reel_sing(t)
        n, N = m.n_gt, m.n_late   # N: the compared years — for a fallback
                                  # station only the available ones count
        # the skeptic's line on an empty canvas, conceded after a pause; then
        # the chart draws in and the year with the most days follows on a new
        # line (`b` and `c` fade in later)
        f1 = ("„Heiße Sommer hat's früher auch schon gegeben.“", "⏎Stimmt.", "")   # ⏎: on its own line
        look = "Schauen wir uns $(m.e_span) an."
        f3 = ("Schauen wir uns die letzten $N Jahre an.", "", "")
        if m.rec > 0
            yrs = join_de(m.rec_years)
            one = length(m.rec_years) == 1
            # no „Rekord" anywhere on the page (Fabian): the year with the most
            # days, its number in brackets, and „extremer als 1983"
            most = "Die meisten $plural " * bb("($(m.rec))") * "<br>gab es " * hl("old", yrs) * "."
            f2 = (look, "", most)
            cnt = n == 0 ? "Keines der letzten $N Jahre war extremer" :
                  n == 1 ? hl("hot", "Eines der letzten $N Jahre") * " war extremer" :
                           hl("hot", "$n der letzten $N Jahre") * " waren extremer"
            f4 = (cnt * " als " * hl("old", yrs) * ".", "", "")
            # Fabian's first draft read „Was früher normal war …" — no contrast
            # between the halves; the exception is the contrast
            were = one ? "wurde" : "wurden"
            f5 = n >= 8 ? ("Was früher eine Ausnahme war,", "ist heute nichts Besonderes mehr.", "") :
                 n >= 3 ? ("Was früher eine Ausnahme war,", "ist heute keine Seltenheit mehr.", "") :
                 n == 0 ? ("$yrs $were hier noch nicht übertroffen.", "", "") :
                 n == 1 ? ("$yrs $were hier", "erst einmal übertroffen.", "") :
                          ("$yrs $were hier", "erst zweimal übertroffen.", "")
        else
            none = "Zwischen $(m.e0) und $(m.e1) gab es keinen einzigen " * bb(sing) * "."
            f2 = (look, "", none)
            f4 = n == 0 ? ("Keines der letzten $N Jahre hatte einen.", "", "") :
                 n == 1 ? (hl("hot", "Eines der letzten $N Jahre") * " hatte einen $sing.", "", "") :
                          (hl("hot", "$n der letzten $N Jahre") * " hatten mindestens einen $sing.", "", "")
            f5 = n >= 8 ? ("Was es früher nie gab,", "ist heute nichts Besonderes mehr.", "") :
                 n >= 3 ? ("Was es früher nie gab,", "ist heute keine Seltenheit mehr.", "") :
                 n == 0 ? ("Hier gibt es das bis heute nicht.", "", "") :
                          ("Hier ist das bis heute die Ausnahme.", "", "")
        end
        # A flat story (Fabian, 2026-09-03 Abend): the finished chart from
        # the start, two text beats — the two window sums (`flat`, built by
        # the caller), then the Österreich sentence — and no closing line.
        frames = if flat !== nothing
            [6 => flat, 7 => (national[1], national[2], "")]
        else
            f6 = (national[1], national[2], "")
            f7 = ("So schaut Klimawandel aus.", "", "")
            fs = [1 => f1, 2 => f2, 3 => f3, 4 => f4, 5 => f5, 6 => f6, 7 => f7]
            m.short && popfirst!(fs)
            fs
        end
        k = length(m.pre_over)
        y, v = k == 0 ? (0, 0) : m.pre_over[1]
        prenote = k == 0 ? "" :
            m.rec > 0 ?
                (k == 1 ? "Auch vor $(m.e0) lag ein Jahr über dem Höchstwert von $(m.e_span): $y hatte $v $plural." :
                          "Auch vor $(m.e0) lagen $k Jahre über dem Höchstwert von $(m.e_span). $y hatte $v $plural.") :
                (k == 1 ? "Vor $(m.e0) gab es ein Jahr mit einem $sing: $y hatte $v." :
                          "Vor $(m.e0) gab es $k Jahre mit einem $sing. $y hatte $v.")
        (; frames, prenote)
    end

    "Plain text of a caption, for aria-labels."
    plain(c) = replace(strip(join(c, " ")), "<br>" => " ", r"<[^>]+>" => "", "⏎" => "")
end

# ╔═╡ 2771ac0c-dafe-4e52-bdbd-04e5cc3060cc
"""
Render one view of the chart — `:reel` (from the early window on), `:all`
(every year, phone canvas) or `:wide` (every year, 900 px) — and tag what the
CSS animates: the two window bands (`band old|new`), bars (`bar` + era +
`top cool|warm` + `running`, with `--i/--n` for the stagger), the record
line (`hline`), its label (`hlbl`), the year labels (`lbl oldrec`, `lbl
focus`) and the period labels on the x axis (`xlbl pre|old|new`). Colours
are all set by the stylesheet; the figure is transparent so the card paints
the background. The views share the state machine, so they carry the same
classes.
"""
function reel_svg(df; view = :reel, aria = "")
    m = reel_meta(df)
    W, H = REEL_VIEWS[view]
    d = view == :reel ? df[df.era .!= :pre, :] : df
    nrow(d) > 0 || error("reel_svg: nothing to draw")
    lo, hi = minimum(d.year) - 1.0, maximum(d.year) + 1.0
    # hatched years at the edges (an incomplete first or last year, a station
    # that paused recently) still get their column
    view == :reel || (lo = min(lo, m.y0 - 1.0))
    hi = max(hi, m.ylast + 1.0)
    ymax = max(maximum(d.value), m.rec, 1.0)
    pxy = (W - 56) / (hi - lo)                       # pixels per year, roughly
    xfs = view == :wide ? 12 : 11

    # the periods on the x axis; the years before the window get a label only
    # where it fits under them
    periods = Tuple{Float64,String,Symbol}[]
    if view != :reel && m.y0 < m.e0 && (m.e0 - m.y0) >= 0.62 * xfs * 9 / pxy + 2
        push!(periods, ((m.y0 + m.e0 - 1) / 2, "$(m.y0)–$(m.e0 - 1)", :pre))
    end
    push!(periods, ((m.e0 + m.e1) / 2, m.e_span, :old))
    push!(periods, ((m.l0 + m.l1) / 2, m.l_span, :new))

    set_theme!(klima_theme())
    fig = Figure(; size = (W, H), backgroundcolor = :transparent)
    ax = Axis(fig[1, 1]; backgroundcolor = :transparent,
        leftspinevisible = false, bottomspinevisible = false,
        xticksvisible = false, yticksvisible = false, xgridvisible = false,
        ygridvisible = true, ygridcolor = (:white, 0.10),
        yticklabelcolor = REEL_TICK, yticklabelsize = view == :wide ? 11 : 10,
        xticks = ([p[1] for p in periods], [p[2] for p in periods]),
        xticklabelcolor = RTAG.xlbl, xticklabelsize = xfs)
    # the two windows as bands, under everything else
    vspan!(ax, m.e0 - 0.5, m.e1 + 0.5; color = RTAG.bandold, strokewidth = 0)
    vspan!(ax, m.l0 - 0.5, m.l1 + 0.5; color = RTAG.bandnew, strokewidth = 0)
    # measurement holes as hatched columns, over the bands, under the bars —
    # the CSS swaps the tag colour for the stripe pattern
    vgaps = [(s, e) for (s, e) in m.gaps if e >= lo && s <= hi]
    for (s, e) in vgaps
        vspan!(ax, s - 0.5, e + 0.5; color = RTAG.gapfill, strokewidth = 0)
    end
    barplot!(ax, Float64.(d.year), d.value; color = RTAG.bar, width = 0.8, strokewidth = 0)
    m.rec > 0 && hlines!(ax, [Float64(m.rec)]; color = RTAG.line, linewidth = 1.2, linestyle = :dash)
    # year labels above their bars; near the edges they hang inwards, and a
    # label that would overprint an earlier one at the same height moves up a line
    labelled = findall(!isempty, d.label)
    placed = NTuple{4,Float64}[]
    for i in labelled
        y, txt = d.year[i], d.label[i]
        x, al = y > hi - 7 ? (y + 0.45, :right) : y < lo + 7 ? (y - 0.45, :left) : (Float64(y), :center)
        lw = 0.6 * 10.5 * length(txt) / pxy
        x0, x1 = al == :right ? (x - lw, x) : al == :left ? (x, x + lw) : (x - lw / 2, x + lw / 2)
        ypx = d.value[i] / (1.2 * ymax) * (H - 60)
        dy = 0.0
        for (px0, px1, pypx, pdy) in placed
            (x0 < px1 && x1 > px0 && abs(ypx - pypx) < 14) && (dy = max(dy, pdy + 13))
        end
        push!(placed, (x0, x1, ypx, dy))
        text!(ax, Point2f(x, d.value[i] + 0.025 * ymax); text = txt, align = (al, :bottom),
              fontsize = 10.5, color = y == m.focus ? RTAG.focus : RTAG.oldrec, offset = (0.0, dy))
    end
    # the line's label: at its right end while that side is still empty (the
    # reel view fades it out when the new years come); in the all-years views in
    # the widest stretch above the line that no bar and no year label reaches
    hlbl_drawn = m.rec > 0
    if m.rec > 0 && view == :reel
        text!(ax, Point2f(hi - 0.4, m.rec + 0.02 * ymax); text = "Höchstwert $(m.e_span): $(m.rec) $(m.rec == 1 ? "Tag" : "Tage")",
              align = (:right, :bottom), fontsize = 10, color = RTAG.hlbl)
    elseif m.rec > 0
        slot = line_label_slot(d, m.rec, lo, hi, W;
                               texts = ["Höchstwert $(m.e_span): $(m.rec) $(m.rec == 1 ? "Tag" : "Tage")", "Höchstwert $(m.e_span)", "Höchstwert\n$(m.e_span)"])
        hlbl_drawn = slot !== nothing
        hlbl_drawn && text!(ax, Point2f(slot[2], m.rec + 0.02 * ymax); text = slot[1],
                            align = (slot[3], :bottom), fontsize = 10, color = RTAG.hlbl)
    end
    xlims!(ax, lo, hi)
    ylims!(ax, 0, ymax * 1.2)
    top = ceil(Int, ymax * 1.2)                      # days are integers: no "0.5"
    step = ymax < 8 ? 1 : ymax < 16 ? 2 : ymax < 30 ? 5 : ymax <= 60 ? 10 : 25
    ax.yticks = 0:step:top

    isassigned(SVG_SCRATCH) || (SVG_SCRATCH[] = joinpath(mktempdir(), "race.svg"))
    save(SVG_SCRATCH[], fig)
    svg = strip_prolog(read(SVG_SCRATCH[], String))
    vb = match(r"viewBox=\"0 0 ([\d.]+) ([\d.]+)\"", svg)
    (vb !== nothing && parse(Float64, vb[1]) == W && parse(Float64, vb[2]) == H) ||
        error("SVG viewBox is not 0 0 $W $H")

    nz = findall(>(0), d.value)            # zero-height bars emit no path
    kbar, nhl, nbo, nbn, nga = 0, 0, 0, 0, 0
    svg = replace(svg, r"<path [^>]*/>" => function (tag)
        if color_eq(attr_rgbpct(tag, "stroke"), RTAG.line)
            nhl += 1
            return replace(tag, "<path " => "<path class=\"hline\" "; count = 1)
        end
        f = attr_rgbpct(tag, "fill")
        if color_eq(f, RTAG.bandold)
            nbo += 1
            return replace(tag, "<path " => "<path class=\"band old\" "; count = 1)
        elseif color_eq(f, RTAG.bandnew)
            nbn += 1
            return replace(tag, "<path " => "<path class=\"band new\" "; count = 1)
        elseif color_eq(f, RTAG.gapfill)
            nga += 1
            return replace(tag, "<path " => "<path class=\"gapspan\" "; count = 1)
        end
        color_eq(f, RTAG.bar) || return tag
        kbar += 1
        kbar <= length(nz) || error("more bar paths than non-zero bars")
        r = d[nz[kbar], :]
        cls = "bar $(r.era)" * (r.top ? " top" : "") * (r.cool ? " cool" : r.warm ? " warm" : "") *
              (r.running ? " running" : "")
        replace(tag, "<path " => "<path class=\"$cls\" style=\"--i:$(r.gi);--n:$(r.gn)\" "; count = 1)
    end)
    kbar == length(nz) || error("Expected $(length(nz)) bar paths, found $kbar")
    nhl == (m.rec > 0) || error("Record line: expected $(m.rec > 0 ? "one" : "none"), tagged $nhl")
    (nbo == 1 && nbn == 1) || error("Window bands: expected one each, tagged $nbo and $nbn")
    nga == length(vgaps) || error("Gap spans: expected $(length(vgaps)), tagged $nga")

    # text: one <g fill=…> per text run; the fill says which label it is
    text_re = r"<g fill=\"[^\"]+\"[^>]*>\s*<use [^>]*? x=\"[-\d.]+\""
    nt = Dict(:oldrec => 0, :focus => 0, :hlbl => 0)
    xs_xlbl = Float64[]
    svg = replace(svg, text_re => function (g)
        f = attr_rgbpct(g, "fill")
        cls = color_eq(f, RTAG.oldrec) ? "lbl oldrec" :
              color_eq(f, RTAG.focus) ? "lbl focus" :
              color_eq(f, RTAG.hlbl) ? "hlbl" : nothing
        if cls === nothing
            color_eq(f, RTAG.xlbl) && push!(xs_xlbl, parse(Float64, match(r" x=\"([-\d.]+)\"", g)[1]))
            return g
        end
        nt[Symbol(split(cls)[end])] += 1
        replace(g, "<g " => "<g class=\"$cls\" "; count = 1)
    end)
    (nt[:oldrec] > 0) == (m.rec > 0) || error("old record label: expected $(m.rec > 0), tagged $(nt[:oldrec])")
    (nt[:hlbl] > 0) == hlbl_drawn || error("line label: expected $hlbl_drawn, tagged $(nt[:hlbl])")
    want_focus = m.focus_present && m.focus in d.year
    (nt[:focus] > 0) == want_focus || error("focus label: expected $want_focus, tagged $(nt[:focus])")
    # the period labels share one colour (one <g> per text run, more if a run
    # splits): split the groups at the K-1 largest gaps, left to right
    K = length(periods)
    length(xs_xlbl) >= K || error("period labels: only $(length(xs_xlbl)) glyph groups for $K labels")
    s = sort(xs_xlbl)
    cuts = K == 1 ? Float64[] : sort([(s[g] + s[g + 1]) / 2 for g in sortperm(diff(s); rev = true)[1:(K - 1)]])
    hit = zeros(Int, K)
    svg = replace(svg, text_re => function (g)
        color_eq(attr_rgbpct(g, "fill"), RTAG.xlbl) || return g
        x = parse(Float64, match(r" x=\"([-\d.]+)\"", g)[1])
        k = count(<(x), cuts) + 1
        hit[k] += 1
        replace(g, "<g " => "<g class=\"xlbl $(periods[k][3])\" "; count = 1)
    end)
    all(>(0), hit) || error("period labels untagged: $(periods[hit .== 0])")

    out = replace(svg,
        r"<svg ([^>]*?)width=\"[^\"]*\" height=\"[^\"]*\" " =>
        SubstitutionString("<svg class=\"chart svg-$view\" role=\"img\" aria-label=\"$aria\" \\1"))
    occursin("class=\"chart", out) || error("SVG root not rewritten")
    out
end

# ╔═╡ fe271bac-5298-42a4-8367-7f75678fe1c7
"""
The reel's stylesheet: the card, the progress segments, the subtitles, the
auto-play timeline (`#ra` checked on load), the manual frames `#r1 … #r7`,
the tap zones, and the view switch (`#all`): on a phone the „ab 1961" chart
shows first and the checkbox brings every year on the phone canvas; on a
wide screen the wide all-years chart shows first, in a wide card, and the
checkbox brings the „ab 1961" chart in a narrow one. The views are switched
with `display`, so a switch during the auto-play restarts it (the script
does that officially).

A short story (`short-<t>` on the box) skips slot 1: the timeline shifts by
one frame through `--shift`, so everything of slot 1 is simply there from
the start, and the first progress segment is hidden. Station-independent.
"""
function reel_css(; thresholds = [25, 30, 35])
    F = frame_starts()
    nf = REEL_NF
    from(k, sel) = join(["#r$j:checked ~ .card $sel" for j in k:nf], ", ")
    per_t(f) = join([f(t) for t in thresholds], "\n")
    at(x) = "calc($(round(x; digits = 2))s + var(--shift))"          # a delay on the shifted clock
    """
    /* ------------------------------------------------ reel */
    .reelbox { --bg: #15171c; --faint: #2b2e35; --gray: #4b4f57; --old: #5ab0f0; --hot: #ff7043;
      --fg: #f3f3f3; --mute: #9aa0a8; position: relative; }
    .reelbox > input { position: absolute; opacity: 0; pointer-events: none; }
    .card { --shift: 0s; position: relative; max-width: 440px; margin: 0 auto; background: var(--bg);
      color: var(--fg); border-radius: 18px; overflow: hidden;
      box-shadow: 0 12px 32px rgba(0, 0, 0, .28); user-select: none; }
    $(per_t(t -> ".short-$t > #th-$t:checked ~ .card { --shift: -$(F[2])s; }"))
    .progress { display: flex; gap: 3px; padding: 10px 12px 0; }
    .progress .seg { flex: 1; height: 3px; background: rgba(255, 255, 255, .22); border-radius: 2px; overflow: hidden; }
    .progress .seg i { display: block; height: 100%; width: 0; background: #fff; }
    $(per_t(t -> ".short-$t > #th-$t:checked ~ .card .seg:nth-child(1) { display: none; }"))
    /* flat story (station against the trend): the clock jumps to slot 6, so
       every earlier animation has a negative delay and lands in its end
       state — the finished chart from the start, only the text plays */
    $(per_t(t -> ".flat-$t > #th-$t:checked ~ .card { --shift: -$(F[6])s; }"))
    $(per_t(t -> ".flat-$t > #th-$t:checked ~ .card .seg:nth-child(-n+5) { display: none; }"))
    /* an empty threshold has no story: no progress, no taps, no replay, no view switch */
    $(per_t(t -> ".empty-$t > #th-$t:checked ~ .card .progress, .empty-$t > #th-$t:checked ~ .card .tap, .empty-$t > #th-$t:checked ~ .card .head .again { display: none !important; }"))
    $(per_t(t -> ".empty-$t > #th-$t:checked ~ .allbtn { display: none; }"))
    .head { display: flex; justify-content: space-between; align-items: center; min-height: 30px;
      padding: 8px 14px 0; font-size: 11px; letter-spacing: .1em; text-transform: uppercase;
      color: var(--mute); font-weight: 600; }
    .head .h { display: none; }
    $(per_t(t -> "#th-$t:checked ~ .card .head .h-$t { display: block; }"))
    .head .again { display: block; position: relative; z-index: 3; cursor: pointer; font-size: 18px;
      line-height: 1; color: var(--fg); opacity: .8; letter-spacing: 0; }
    .head .again:hover { opacity: 1; }
    .panels { display: grid; }
    .panel { grid-area: 1 / 1; visibility: hidden; }
    .panel .muted { margin: 0; padding: 72px 24px; color: var(--mute); }
    $(per_t(t -> "#th-$t:checked ~ .card .panel-$t { visibility: visible; }"))
    .glyphs { position: absolute; width: 0; height: 0; overflow: hidden; }
    .chart { width: 100%; height: auto; display: none; opacity: 0; transition: opacity .5s ease-out; }
    /* which view shows: phones start from the early window, wide screens with every year */
    @media (max-width: $(REEL_PHONE_MAX)px) {
      .svg-reel { display: block; }
      #all:checked ~ .card .svg-reel { display: none; }
      #all:checked ~ .card .svg-all { display: block; }
      .allbtn .off { display: none; }
      #all:checked ~ .allbtn .on { display: none; }
      #all:checked ~ .allbtn .off { display: inline; }
    }
    @media (min-width: $(REEL_PHONE_MAX + 1)px) {
      .card { max-width: 900px; }
      .svg-wide { display: block; }
      #all:checked ~ .card { max-width: 440px; }
      #all:checked ~ .card .svg-wide { display: none; }
      #all:checked ~ .card .svg-reel { display: block; }
      .allbtn .on { display: none; }
      #all:checked ~ .allbtn .on { display: inline; }
      #all:checked ~ .allbtn .off { display: none; }
    }
    .rcaps { position: relative; min-height: 186px; }
    .capset { position: absolute; inset: 0; visibility: hidden; }
    $(per_t(t -> "#th-$t:checked ~ .card .capset-$t { visibility: visible; }"))
    .rcap { position: absolute; left: 0; right: 0; top: 50%; transform: translateY(-50%); margin: 0 auto;
      max-width: 640px; padding: 0 24px; text-align: center; font-weight: 700;
      font-size: clamp(17px, 4.8vw, 21px); line-height: 1.3; opacity: 0;
      transition: opacity .3s ease-out; text-wrap: balance; }
    .rcap .b, .rcap .c { opacity: 0; transition: opacity .35s ease-out; }
    .rcap em { font-style: normal; }
    .rcap em.old { color: var(--old); }
    .rcap em.hot { color: var(--hot); }
    .rcap b { color: #fff; }
    .allbtn { display: block; width: max-content; margin: 14px auto 0; padding: 8px 18px;
      border: 1px solid var(--rule, #d0d0d0); border-radius: 999px; cursor: pointer;
      font-size: 14px; font-weight: 600; background: var(--paper, #fff); user-select: none; }
    .allbtn:hover { background: var(--soft, #f2f2f2); }
    .reelnote { max-width: 640px; margin: 10px auto 0; font-size: 13px; color: var(--muted, #666); }
    .reelnote p { margin: 0 0 4px; }
    .reelnote .pn { display: none; }
    $(per_t(t -> "#th-$t:checked ~ .reelnote .pn-$t { display: block; }"))
    .reelnote i { display: inline-block; width: 10px; height: 10px; border-radius: 2px;
      vertical-align: -1px; margin-right: 4px; }
    .reelnote .li { white-space: nowrap; margin-right: 10px; }   /* breaks only between legend items */

    /* the chart's parts: hidden until their frame */
    .chart .band { opacity: 0; transition: opacity .6s ease-in-out; }
    .chart .band.old { fill: var(--old); fill-opacity: .11; }
    .chart .band.new { fill: var(--hot); fill-opacity: .10; }
    .chart .gapspan { fill: url(#reelhatch); }   /* no measurement — not a zero */
    .hatchline { stroke: #fff; stroke-opacity: .12; stroke-width: 2; }   /* stripe faintness lives here */
    .chart .bar { fill: var(--gray); opacity: 0; transition: opacity .4s ease-out, fill .5s ease-in-out; }
    .chart .bar.pre, .chart .bar.gap, .chart .bar.post { fill: var(--faint); }
    .chart .bar.top.cool { fill: var(--old); }
    .chart .bar.top.warm { fill: var(--hot); }
    .chart .bar.new.top { fill: var(--gray); }        /* orange only from slot 3 on, after they appeared */
    .chart .bar.running { stroke: #fff; stroke-width: 1.2px; }
    .chart .hline { stroke: var(--fg); opacity: 0; transition: opacity .5s ease-in-out; }
    .chart .hlbl, .chart .xlbl { fill: var(--mute); opacity: 0; transition: opacity .4s ease-out; }
    .chart .lbl { opacity: 0; transition: opacity .4s ease-out; }
    .chart .lbl.oldrec { fill: var(--old); }
    .chart .lbl.focus { fill: var(--fg); }
    .chart .lbl, .chart .hlbl { paint-order: stroke; stroke: var(--bg); stroke-width: 3px; stroke-linejoin: round; }

    /* ---------- auto-play, on the shifted clock: slot 1 is the empty canvas,
       the chart draws in with „Schau ma uns" (slot 2, second part) ---------- */
    /* slot 2: the sentence first, the chart once it is half read, the line
       alone, then the second line of text, then the labels that echo it.
       Delays always as longhands: older Safari drops an animation whose
       shorthand contains var()/calc() (the stagger rules already do this). */
    #ra:checked ~ .card .chart { animation: fadein .5s ease-out forwards; animation-delay: $(at(F[2] + 2.0)); }
    #ra:checked ~ .card .band.old { animation: fadein .6s ease-in-out forwards; animation-delay: $(at(F[2] + 2.0)); }
    #ra:checked ~ .card .xlbl.old, #ra:checked ~ .card .xlbl.pre { animation: fadein .5s ease-out forwards; animation-delay: $(at(F[2] + 2.4)); }
    #ra:checked ~ .card .bar.old, #ra:checked ~ .card .bar.pre { animation: fadein .45s ease-out forwards;
      animation-delay: calc(var(--i) / var(--n) * 1.2s + $(F[2] + 2.5)s + var(--shift)); }
    #ra:checked ~ .card .hline { animation: fadein .5s ease-in-out forwards; animation-delay: $(at(F[2] + 4.6)); }
    #ra:checked ~ .card .hlbl, #ra:checked ~ .card .lbl.oldrec { animation: fadein .5s ease-out forwards; animation-delay: $(at(F[2] + 7.4)); }
    #ra:checked ~ .card .svg-reel .hlbl { animation: fadein .5s ease-out forwards, fadeout .4s ease-out forwards;
      animation-delay: $(at(F[2] + 7.4)), $(at(F[3] + 2.0)); }
    /* slot 3: the sentence, the orange band, the bars with 2026 last, its
       label, then the flip to orange — and rest before the next sentence */
    #ra:checked ~ .card .band.new { animation: fadein .6s ease-in-out forwards; animation-delay: $(at(F[3] + 2.0)); }
    #ra:checked ~ .card .xlbl.new { animation: fadein .5s ease-out forwards; animation-delay: $(at(F[3] + 2.2)); }
    #ra:checked ~ .card .bar.new, #ra:checked ~ .card .bar.gap, #ra:checked ~ .card .bar.post {
      animation: fadein .45s ease-out forwards;
      animation-delay: calc(var(--i) / var(--n) * 1.2s + $(F[3] + 2.2)s + var(--shift)); }
    #ra:checked ~ .card .bar.new.top { animation: fadein .45s ease-out forwards, heat .6s ease-in-out forwards;
      animation-delay: calc(var(--i) / var(--n) * 1.2s + $(F[3] + 2.2)s + var(--shift)), $(at(F[3] + 4.9)); }
    /* 2026 is not its own beat (Fabian, 2026-09-03): its bar sits at the end
       of the stagger like any other year, and the label comes with it */
    #ra:checked ~ .card .bar.focus { animation: fadein .5s ease-out forwards; animation-delay: $(at(F[3] + 3.4)); }
    #ra:checked ~ .card .lbl.focus { animation: fadein .5s ease-out forwards; animation-delay: $(at(F[3] + 3.4)); }
    $(join(["""
    #ra:checked ~ .card .rcap[data-f="$k"] { animation: fadein .35s ease-out forwards$(k < nf ? ", fadeout .25s ease-in forwards" : "");
      animation-delay: $(at(F[k] + 0.15))$(k < nf ? ", $(at(F[k + 1] - 0.25))" : ""); }
    #ra:checked ~ .card .rcap[data-f="$k"] .b { animation: fadein .35s ease-out forwards; animation-delay: $(at(F[k] + b_delay(k))); }
    #ra:checked ~ .card .rcap[data-f="$k"] .c { animation: fadein .35s ease-out forwards; animation-delay: $(at(F[k] + C_DELAY)); }
    #ra:checked ~ .card .seg:nth-child($k) i { animation: grow $(FRAME_DUR[k])s linear forwards; animation-delay: $(at(F[k])); }
    """ for k in 1:nf]))
    /* the run is over: without the script, a back zone arms (⟳ always shows) */
    #ra:checked ~ .card .tap.prev[data-at="a"] { display: block;
      animation: arm 0s linear forwards; animation-delay: $(at(F[nf + 1] + 0.2)); pointer-events: none; }
    .js > #ra:checked ~ .card .tap[data-at="a"] { display: none; }
    .js > #ra:checked ~ .card .tap.auto { display: block; }

    @keyframes fadein  { to { opacity: 1; } }
    @keyframes fadeout { to { opacity: 0; } }
    @keyframes heat    { to { fill: var(--hot); } }
    @keyframes grow    { to { width: 100%; } }
    @keyframes arm     { to { pointer-events: auto; } }

    /* ---------- manual frames, by slot ---------- */
    $(from(2, ".chart")), $(from(2, ".band.old")), $(from(2, ".bar.old")), $(from(2, ".bar.pre")), $(from(2, ".hline")),
    $(from(2, ".xlbl.old")), $(from(2, ".xlbl.pre")), $(from(2, ".svg-all .hlbl")), $(from(2, ".svg-wide .hlbl")) { opacity: 1; }
    #r2:checked ~ .card .svg-reel .hlbl { opacity: 1; }
    $(from(2, ".lbl.oldrec")) { opacity: 1; }
    #r2:checked ~ .card .lbl.oldrec, #r2:checked ~ .card .svg-all .hlbl, #r2:checked ~ .card .svg-wide .hlbl,
    #r2:checked ~ .card .svg-reel .hlbl { transition-delay: 2.4s; }
    $(from(3, ".band.new")), $(from(3, ".bar.new")), $(from(3, ".bar.gap")), $(from(3, ".bar.post")), $(from(3, ".xlbl.new")) { opacity: 1; }
    $(from(3, ".bar.new")), $(from(3, ".bar.gap")), $(from(3, ".bar.post")) {
      transition-delay: calc(var(--i) / var(--n) * 0.9s), 0s; }
    $(from(3, ".bar.new.top")) { fill: var(--hot); transition-delay: calc(var(--i) / var(--n) * 0.9s), 1.3s; }
    $(from(3, ".bar.focus")), $(from(3, ".lbl.focus")) { opacity: 1; transition-delay: 0.9s; }
    $(join(["""
    #r$k:checked ~ .card .rcap[data-f="$k"] { opacity: 1; }
    #r$k:checked ~ .card .rcap[data-f="$k"] .b { opacity: 1; transition-delay: 1.4s; }
    #r$k:checked ~ .card .rcap[data-f="$k"] .c { opacity: 1; transition-delay: 2.4s; }
    #r$k:checked ~ .card .seg:nth-child(-n+$k) i { width: 100%; }
    """ for k in 1:nf]))

    /* ---------- tap zones: left third back, the rest forward, like stories ---------- */
    .tap { position: absolute; top: 44px; bottom: 0; display: none; cursor: pointer; margin: 0;
      z-index: 2; -webkit-tap-highlight-color: transparent; }
    .tap.prev { left: 0; width: 36%; }
    .tap.next { right: 0; width: 64%; }
    .tap::after { position: absolute; bottom: 10px; font-size: 28px; line-height: 1;
      color: rgba(255, 255, 255, .4); }
    .tap.prev::after { content: "‹"; left: 16px; }
    .tap.next::after { content: "›"; right: 16px; }
    .tap:hover::after { color: rgba(255, 255, 255, .85); }
    $(join([(k > 1 ? "#r$k:checked ~ .card .tap.prev[data-at=\"$k\"] { display: block; }\n" : "") *
            (k < nf ? "#r$k:checked ~ .card .tap.next[data-at=\"$k\"] { display: block; }\n" : "") for k in 1:nf]))
    $(per_t(t -> ".short-$t > #th-$t:checked ~ #r2:checked ~ .card .tap.prev[data-at=\"2\"] { display: none; }"))
    $(per_t(t -> ".flat-$t > #th-$t:checked ~ #r6:checked ~ .card .tap.prev[data-at=\"6\"] { display: none; }"))

    /* Reduced motion: the story still plays — same timeline, same frames, but
       every change is an instant step instead of a fade. The reel has no
       spatial motion (nothing slides, zooms or scrolls); what the setting
       asks us to drop is the easing, not the narrative. Durations go to zero,
       the delays — the timeline — stay. */
    @media (prefers-reduced-motion: reduce) {
      .reelbox *, .reelbox *::before, .reelbox *::after {
        animation-duration: 0s !important; transition-duration: 0s !important; }
    }
    """
end

# ╔═╡ bc50d48f-d6c1-485b-bcdf-5c330c4d1cfe
begin
    "The sentence a panel shows when the threshold was never reached."
    reel_empty_html(threshold) = """<p class="muted">An dieser Station wurde in der
        ganzen Messreihe noch kein Tag mit mindestens $threshold °C gemessen.</p>"""

    """
    The reel box for one station: threshold radios, frame radios (`ra` checked
    on load), the view checkbox, the tabs, the card, the button, the note with
    the legend — and `tail`, whatever the page wants after them inside the
    box, so `#th-<t>:checked ~ …` keeps working there (the site's tiles).
    `national` gives slot 6's sentence per threshold. The box carries
    `short-<t>` for every threshold whose story skips the opening beat, and
    `empty-<t>` for every threshold the station never reached — that tab
    shows only the sentence: no progress bar, taps, replay or view switch.
    """
    function reel_box_html(annual, station; thresholds = [25, 30, 35], default = 30,
                           late = late_window(annual), national::AbstractDict,
                           flat::AbstractDict = Dict{Int,Any}(), tail = "")
        dfs = Dict(t => reel_data(annual; threshold = t, late) for t in thresholds)
        live = [t for t in thresholds if !all(iszero, dfs[t].value)]
        caps = Dict(t => reel_captions(reel_meta(dfs[t]); national = national[t],
                                       flat = get(flat, t, nothing)) for t in live)
        aria = Dict(t => join([plain(f) for (_, f) in caps[t].frames], " ") for t in live)
        keys_ = [(t, v) for t in live for v in (:reel, :all, :wide)]
        dd = dedupe_glyphs([reel_svg(dfs[t]; view = v, aria = aria[t]) for (t, v) in keys_])
        svgd = Dict(k => s for (k, s) in zip(keys_, dd.svgs))
        m0 = reel_meta(dfs[first(thresholds)])
        flags = join([t in keys(flat) ? " flat-$t" :
                      reel_meta(dfs[t]).short ? " short-$t" : "" for t in live]) *
                join([" empty-$t" for t in thresholds if !(t in live)])
        # the stripe pattern the gap columns reference, and its legend entry
        hatchdef = """<svg class="glyphs" aria-hidden="true"><defs><pattern id="reelhatch" width="6" height="6" \
patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line class="hatchline" x1="3" y1="0" x2="3" y2="6"/></pattern></defs></svg>"""
        hatchkey = isempty(m0.gaps) ? "" :
            """ <span class="li"><i style="background:repeating-linear-gradient(45deg,#15171c 0 2.5px,rgba(255,255,255,.3) 2.5px 3.5px)"></i> Messlücke</span>"""

        thinputs = join(["<input type=\"radio\" name=\"th\" id=\"th-$t\"$(t == default ? " checked" : "")>"
                         for t in thresholds], "\n")
        tabs = join(["""<label for="th-$t">$(day_term(t))<span>≥ $t °C</span></label>""" for t in thresholds], "\n")
        rinputs = "<input type=\"radio\" name=\"r\" id=\"ra\" checked>\n" *
                  join(["<input type=\"radio\" name=\"r\" id=\"r$k\">" for k in 1:REEL_NF], "\n") *
                  "\n<input type=\"checkbox\" id=\"all\">"
        heads = join(["<span class=\"h h-$t\">$station · $(day_term(t)) pro Jahr</span>" for t in thresholds])
        panels = join(["<div class=\"panel panel-$t\">" *
                       (t in live ? svgd[(t, :reel)] * svgd[(t, :all)] * svgd[(t, :wide)] : reel_empty_html(t)) * "</div>"
                       for t in thresholds], "\n")
        # a part beginning with ⏎ starts on its own line
        part(cls, txt) = isempty(txt) ? "" :
            startswith(txt, "⏎") ? "<br><span class=\"$cls\">$(txt[nextind(txt, 1):end])</span>" :
                                   " <span class=\"$cls\">$txt</span>"
        capp(k, f) = """<p class="rcap" data-f="$k">$(f[1])$(part("b", f[2]))$(isempty(f[3]) ? "" : part("c", "⏎" * f[3]))</p>"""
        capsets = join(["<div class=\"capset capset-$t\">" *
                        (t in live ? join([capp(k, f) for (k, f) in caps[t].frames]) : "") * "</div>"
                        for t in thresholds], "\n")
        taps = join([(k > 1 ? "<label class=\"tap prev\" data-at=\"$k\" for=\"r$(k - 1)\" title=\"Zurück\"></label>\n" : "") *
                     (k < REEL_NF ? "<label class=\"tap next\" data-at=\"$k\" for=\"r$(k + 1)\" title=\"Weiter\"></label>\n" : "")
                     for k in 1:REEL_NF]) *
               "<label class=\"tap prev\" data-at=\"a\" for=\"r$(REEL_NF - 1)\" title=\"Zurück\"></label>\n" *
               "<span class=\"tap prev auto\" title=\"Zurück\"></span>\n<span class=\"tap next auto\" title=\"Weiter\"></span>"
        gap = m0.e1 + 1 > m0.l0 - 1 ? "" :
              m0.e1 + 1 == m0.l0 - 1 ? " und $(m0.e1 + 1)" : " und $(m0.e1 + 1)–$(m0.l0 - 1)"
        notes = join(["<p class=\"pn pn-$t\">$(caps[t].prenote)</p>" for t in live if !isempty(caps[t].prenote)], "\n")
        """
        <div class="reelbox$flags">
        $thinputs
        $rinputs
        <div class="tabs">$tabs</div>
        <div class="card">
        <div class="progress">$(join(["<span class=\"seg\"><i></i></span>" for _ in 1:REEL_NF]))</div>
        <div class="head"><span>$heads</span><label class="again" for="ra" title="Neu abspielen">⟳</label></div>
        <div class="panels">$hatchdef$(dd.defs)
        $panels
        </div>
        <div class="rcaps">
        $capsets
        </div>
        $taps
        </div>
        <label class="allbtn" for="all"><span class="on">Alle Jahre anzeigen</span><span class="off">Nur ab $(m0.e0) anzeigen</span></label>
        <div class="reelnote">
        <p><span class="li"><i style="background:#5ab0f0"></i> Höchstwert $(m0.e_span)</span> <span class="li"><i style="background:#ff7043"></i> seit $(m0.l0) darüber</span>
           <span class="li"><i style="background:#4b4f57"></i> darunter</span> <span class="li"><i style="background:#2b2e35;border:1px solid #bbb"></i> außerhalb des Vergleichs:</span> <span class="li">vor $(m0.e0)$gap</span>$hatchkey</p>
        $notes
        </div>
        $tail
        </div>
        """
    end

    """
    Taps during the auto-play, swipes, arrow keys, the handover at the end
    and the restart when the view or the threshold switches mid-run — all of
    it only checks the radios the labels use. Without the script the frames still work by
    tapping once the run is over. A short story (box class `short-<t>` for
    the checked threshold) begins at slot 2 and ends one frame earlier.
    """
    function reel_script()
        F = frame_starts()
        """
        <script>
        (function () {
          var box = document.querySelector(".reelbox");
          if (!box) return;
          var S = [$(join(F, ","))], NF = $(REEL_NF);
          var el = function (id) { return box.querySelector("#" + id); };
          function has(p) {
            var th = box.querySelector('input[name="th"]:checked');
            return !!th && box.classList.contains(p + th.id.replace("th-", ""));
          }
          function shift() { return has("flat-") ? S[5] : has("short-") ? S[1] : 0; }
          function first() { return has("flat-") ? 6 : has("short-") ? 2 : 1; }
          var t0 = performance.now(), hand = null;
          function arm() {
            clearTimeout(hand);
            var end = S[NF] + 0.2 - shift();
            hand = setTimeout(function () { if (el("ra").checked) el("r" + NF).click(); }, end * 1000);
          }
          arm();
          el("ra").addEventListener("change", function () { t0 = performance.now(); arm(); });
          // a switch that swaps the chart or the story mid-run shows animations
          // that start from zero: replay (the view checkbox and the threshold tabs)
          function replay() {
            if (!el("ra").checked) return;
            el("ra").checked = false;
            void box.offsetWidth;
            el("ra").click();
          }
          el("all").addEventListener("change", replay);
          Array.prototype.forEach.call(box.querySelectorAll('input[name="th"]'), function (th) {
            th.addEventListener("change", replay);
          });
          // ⟳ always shows; during the run its label is a no-op (ra already
          // checked, no change event) — restart the animations by hand
          box.querySelector(".again").addEventListener("click", function (e) {
            if (el("ra").checked) { e.preventDefault(); replay(); }
          });
          function cur() {
            for (var k = 1; k <= NF; k++) if (el("r" + k).checked) return k;
            var e = (performance.now() - t0) / 1000 + shift(), j = first();
            while (j < NF && e >= S[j]) j++;
            return j;
          }
          function go(k) { if (k >= first() && k <= NF) el("r" + k).click(); }
          function nav(fwd) { go(cur() + (fwd ? 1 : -1)); }
          box.classList.add("js");
          Array.prototype.forEach.call(box.querySelectorAll(".tap.auto"), function (z) {
            z.addEventListener("click", function () { nav(z.classList.contains("next")); });
          });
          var card = box.querySelector(".card"), x0 = null;
          card.addEventListener("touchstart", function (e) { x0 = e.touches[0].clientX; }, { passive: true });
          card.addEventListener("touchend", function (e) {
            if (x0 === null) return;
            var dx = e.changedTouches[0].clientX - x0;
            x0 = null;
            if (Math.abs(dx) < 40) return;
            nav(dx < 0);
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

# ╔═╡ 81465341-ea5e-4b2a-9275-10d8c83a02e1
begin
    "Page chrome for the preview — the site's look, cut down."
    reel_page_css(; thresholds = [25, 30, 35]) = """
        :root { --ink: #1c1b19; --muted: #6d6a64; --rule: #e6e1d8; --paper: #fff; --soft: #faf8f4; --link: #1b6ca8; }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--paper); color: var(--ink); line-height: 1.55;
          font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; -webkit-text-size-adjust: 100%; }
        main { max-width: 960px; margin: 0 auto; padding: 36px 16px 80px; }
        a { color: var(--link); }
        .kicker { margin: 0 0 6px; font-size: 12px; letter-spacing: .12em; text-transform: uppercase;
          color: var(--muted); font-weight: 600; }
        h1 { margin: 0 0 8px; font-size: clamp(1.9rem, 5.5vw, 2.9rem); line-height: 1.12; letter-spacing: -.02em; }
        .sub { margin: 0 0 22px; color: var(--muted); font-size: 15px; }
        .tabs { display: flex; gap: 8px; margin: 0 0 12px; flex-wrap: wrap; justify-content: center; }
        .tabs label { padding: 7px 14px; border: 1px solid var(--rule); border-radius: 10px; cursor: pointer;
          font-size: 14px; font-weight: 600; background: var(--paper); user-select: none; line-height: 1.25; text-align: center; }
        .tabs label span { display: block; font-size: 11.5px; font-weight: 500; opacity: .65; }
        .tabs label:hover { background: var(--soft); }
        $(join(["#th-$t:checked ~ .tabs label[for=\"th-$t\"] { background: var(--ink); border-color: var(--ink); color: #fff; }\n"
                for t in thresholds]))
        .note { max-width: 640px; margin: 18px auto 0; font-size: 13.5px; color: var(--muted); }
        .note p { margin: 0 0 .6em; }
        """

    "The station's preview page — the reel, the button, the legend, the source."
    function reel_page(annual, station; late, national, others = [])
        yrs = annual.year
        span = "$(minimum(yrs))–$(maximum(yrs))"
        links = isempty(others) ? "" :
            "<p>" * join(["<a href=\"$u\">$n</a>" for (n, u) in others], " · ") * "</p>"
        """
        <!doctype html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>$station — Reel (Vorschau)</title>
        <style>$(reel_page_css())$(reel_css())</style>
        </head>
        <body>
        <main>
        <p class="kicker">Hitzetage in Österreich · Vorschau</p>
        <h1>$station</h1>
        <p class="sub">Messreihe $span</p>
        $(reel_box_html(annual, station; late, national))
        <div class="note">
        <p>Höchstwert: das Jahr mit den meisten solchen Tagen zwischen 1961 und 1990, der
        Vergleichsperiode der Wetterdienste. Die letzten 30 Jahre: $(first(late))–$(last(late)),
        das laufende Jahr eingeschlossen. $(year(today())) läuft noch, ist umrahmt, sein Wert
        kann nur steigen.</p>
        <p>Quelle: GeoSphere Austria Data Hub, Datensatz klima-v2-1d, Parameter tlmax.
        Vorschau aus notebooks/reel.jl.</p>
        $links
        </div>
        </main>
        $(reel_script())
        </body>
        </html>
        """
    end
end

# ╔═╡ 04fb63d0-19e6-4247-ba5b-e35e70a34a18
begin
    """
    Per threshold, the sentence of slot 6: at how many of the stations with
    both windows there are more such days in the last 30 years than in
    1961–1990 — the count behind the site's country-wide sentence, by days,
    over the same windows. `build_prototype.jl` derives the same sentence
    from its `national_claims`; this is for the standalone preview.
    """
    function national_lines(annual_all, late)
        running = year(today())
        Dict(t => begin
            col = Symbol("days_ge_", t)
            up = n = 0
            for g in groupby(annual_all, :station_name)
                c = g[g.complete .& (g.year .!= running), :]
                (count(in(REF_WINDOW), c.year) >= WINDOW_MIN && count(in(late), c.year) >= WINDOW_MIN) || continue
                n += 1
                # the late sum takes every row, the running year as far as it goes
                up += sum(g[in.(g.year, Ref(late)), col]) > sum(c[in.(c.year, Ref(REF_WINDOW)), col])
            end
            national_sentence(up, n, t)
        end for t in (25, 30, 35))
    end

    """
    „An 98 von 104 Wetterstationen in Österreich · gibt es heute mehr Hitzetage
    als damals.“ — two parts with a pause after Österreich; „heute" in orange
    and „damals" in blue, the colours of the two 30-year periods. In the flat
    story (a station against the trend) the closing word is „früher": that
    story never establishes a „damals".
    """
    national_sentence(up, n, t; frueher = false) =
        ("An $up von $n Wetterstationen in Österreich",
         "gibt es " * hl("hot", "heute") * " mehr $(reel_plural(t)) als " *
         hl("old", frueher ? "früher" : "damals") * ".")
end

# ╔═╡ 464acbaa-999d-42a5-997e-ae568a64400b
"Write the preview pages."
function generate_reel(; stations = ["Krems", "Wien Hohe Warte", "Kremsmünster"])
    mkpath(OUTDIR)
    annual_all = CSV.read(joinpath(DATADIR, "heat_days.csv"), DataFrame)
    late = late_window(annual_all)
    nat = national_lines(annual_all, late)
    slug(s) = replace(lowercase(replace(s, "ä" => "ae", "ö" => "oe", "ü" => "ue", "ß" => "ss")), r"[^a-z0-9]+" => "-")
    pages = [s => "reel_$(slug(s)).html" for s in stations]
    out = String[]
    for (s, file) in pages
        annual = @subset(annual_all, :station_name == s)
        nrow(annual) > 0 || error("No rows for station $s")
        others = [(n, f) for (n, f) in pages if n != s]
        path = joinpath(OUTDIR, file)
        write(path, reel_page(annual, s; late, national = nat, others))
        push!(out, path)
        @info "Reel" station = s path
    end
    out
end

# ╔═╡ 2bb4917d-94b4-467f-a252-116a5a62005a
# ╠═╡ skip_as_script = true
#=╠═╡
# generate_reel()   # in Pluto by hand; the script entry point below does it in the shell
  ╠═╡ =#

# ╔═╡ 8854a9fc-e4da-4614-9102-632d9c0c55ca
if abspath(PROGRAM_FILE) == @__FILE__
    generate_reel()
end

# ╔═╡ Cell order:
# ╟─1efe96c5-5422-46d9-8bd1-9c7e44cad69d
# ╠═bb21ea12-eede-4b8d-9a3f-54c797bc6b85
# ╠═f1dae239-20f6-4ce3-9c3d-14baf5893ec1
# ╠═b38b36c5-d595-4569-8858-314c307c0140
# ╠═586386a8-8dc2-4a18-914b-97bce43fa21d
# ╠═d36251bb-e3f0-4283-afd2-e14e496d47f8
# ╠═2771ac0c-dafe-4e52-bdbd-04e5cc3060cc
# ╠═fe271bac-5298-42a4-8367-7f75678fe1c7
# ╠═bc50d48f-d6c1-485b-bcdf-5c330c4d1cfe
# ╠═81465341-ea5e-4b2a-9275-10d8c83a02e1
# ╠═04fb63d0-19e6-4247-ba5b-e35e70a34a18
# ╠═464acbaa-999d-42a5-997e-ae568a64400b
# ╟─2bb4917d-94b4-467f-a252-116a5a62005a
# ╠═8854a9fc-e4da-4614-9102-632d9c0c55ca
