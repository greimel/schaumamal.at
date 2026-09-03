# The comparison windows every number on the site shares — the tiles, the
# sentences under them, the chart's line, the country-wide count. One place,
# so a page cannot disagree with itself. Needs DataFrames, DataFrameMacros
# and Dates in scope.

const REF_WINDOW = 1961:1990   # the weather services' reference period
const WINDOW_MIN = 25          # complete years a window needs

"""
The two 30-year windows a station compares. `:reference`: 1961–1990 against
the last 30 years site-wide (`late`, currently 1997–2026), both with at
least `WINDOW_MIN` complete years — the windows the country-wide sentence
counts. `e`/`l` hold the complete years of each window. Otherwise `:fallback`: the station's first and last 30
complete years (fewer for short records), and the sentences name those
years. `nothing` under 20 complete years. Complete years only; the running
year is not missing data, it is simply not over.
"""
function windows(annual, late)
    running = year(today())
    d = sort(@subset(annual, :complete && :year != running), :year)
    nrow(d) < 20 && return nothing
    e = @subset(d, :year in REF_WINDOW)
    l = @subset(d, :year in late)
    if nrow(e) >= WINDOW_MIN && nrow(l) >= WINDOW_MIN
        # A series that starts after 1961 (or has holes) must not claim the
        # full reference period (Fabian: Langenlois starts 1965 and said
        # „1961–1990" regardless): the window slides past 1990 — never past
        # 1996 — until it holds 30 complete years. The span names the years
        # actually compared.
        if nrow(e) < 30
            ext = @subset(d, :year > last(REF_WINDOW) && :year < first(late))
            e = vcat(e, first(ext, 30 - nrow(e)))
        end
        return (; e, l, kind = :reference, all = d,
                  e_span = "$(minimum(e.year))–$(maximum(e.year))",
                  l_span = "$(first(late))–$(last(late))", since = first(late))
    end
    # The fallback windows keep the reference divide (Fabian, 2026-09-03):
    # early = the latest up-to-30 complete years ending 1990 at the latest,
    # late = the available complete years of the site-wide late window — a
    # station with a hole through the 80s and 90s (Güssing: 1983–2007) must
    # not stretch "die letzten Jahre" across it. The sentences then count the
    # *available* years („9 der letzten (verfügbaren) 17 Jahre").
    pre = @subset(d, :year <= last(REF_WINDOW))
    l = @subset(d, :year in late)
    (nrow(pre) == 0 || nrow(l) == 0) && return nothing
    # The latest 30 complete years up to 1990 — widened in steps of ten
    # complete years while any older year still beats one of the window's
    # records (Fabian: no bar may tower just outside the window, but the
    # period must not grow for nothing). Robustness checks every threshold:
    # the window is shared by all three tabs.
    cols = filter(c -> startswith(c, "days_ge_"), names(d))
    robust(e) = all(maximum(e[!, c]) >= maximum(pre[!, c]) for c in cols)
    n = min(30, nrow(pre))
    while n < nrow(pre) && !robust(last(pre, n))
        n = min(n + 10, nrow(pre))
    end
    e = last(pre, n)
    (; e, l, kind = :fallback, all = d,
       e_span = "$(minimum(e.year))–$(maximum(e.year))",
       l_span = "$(minimum(l.year))–$(maximum(l.year))", since = minimum(l.year))
end

"""
Site-wide late window: the 30 years ending with the focus year — the running
year from June on (Fabian, 2026-09-03: „the later period should be
1997–2026"). The running year counts as far as it goes; means over the
window use its complete years only (`windows`), sums and counts every row.
"""
late_window(annual_all) = (focus_year() - 29):focus_year()

"""
The reel's line and the tiles' rule, from the early window: the record — the
most such days in a complete year of the window — and its year(s). A year is
„extremer" when it has *more* days than that; a tie is not. Form `:A` when
there is a record at all, `:C` when the window had no such day (then no line
is drawn, and „extremer" means having such a day). Ties of any size are
form A; the sentences name them.
"""
function race_line(w, threshold)
    col = Symbol("days_ge_", threshold)
    ev = w.e[!, col]
    rec = Int(maximum(ev))
    rec_years = rec > 0 ? Int.(w.e.year[ev .== rec]) : Int[]
    (; form = rec > 0 ? :A : :C, line = Float64(rec), rec, rec_years)
end

"""
The year the "and this year" pieces talk about — the rank in the sorted view,
the tile, the block under the map: the running year from June on, the
previous one before that (Fabian, 2026-09-01: 2026 stays the year until at
least May 2027).
"""
focus_year(d = today()) = month(d) >= 6 ? year(d) : year(d) - 1

"Rank of a value among years: one plus the number of years with more; ties share the better rank."
year_rank(v, values) = 1 + count(>(v), values)

"A rank worth a sentence — beyond this, nobody says „die elftmeisten“."
const RANK_MAX = 10
