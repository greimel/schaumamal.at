#!/usr/bin/env julia
# Focus stations + map stations for the heat-days pages.
#
#     julia --project src/ingest/heat_days_stations.jl [--refresh]
#
# Resolves the six focus stations (two by exact name, four as "nearest
# qualifying station to a town"), downloads their full daily tlmax records,
# and writes everything the static build needs into data/processed/:
#
#     daily_tlmax.csv     one row per station-day (focus stations)
#     heat_days.csv       one row per station-year (focus stations)
#     stations.csv        focus-station metadata incl. slug
#     map_stations.csv    every qualifying station, with a quality tier
#     austria_border.csv  country outline for the map (world.geo.json, coarse)
#
# Needs the network (GeoSphere Data Hub + one GeoJSON download); everything
# downstream builds offline from data/processed/.

# The API helpers (metadata, resolve_station, fetch_station, daily_series,
# heat_days, select_stations) live in the geosphere notebook-script. A plain
# include runs only its unskipped cells, and its own entry point is guarded by
# PROGRAM_FILE, so nothing fetches at include time.
include(joinpath(@__DIR__, "geosphere.jl"))

# ---------------------------------------------------------------- selection

"Only stations this good make the map: merged long record, active, old enough."
const MAP_FROM_YEAR = 1970

"""
Quality tier by nominal record start (metadata `valid_from`). Quarter-century
boundaries on purpose; that gold is nearly empty (3 stations — few Austrian
records begin 1901–1925) is a fact about the network, not a reason to tune.
"""
tier(from_year::Int) =
    from_year <= 1900 ? "platin" :
    from_year <= 1925 ? "gold"   :
    from_year <= 1950 ? "silber" : "bronze"

const FOCUS_EXACT = ["Krems", "Wien Hohe Warte"]

# town => (lat, lon). Resolved to the nearest qualifying station at ingest
# time — the station name is derived, never hard-coded.
const FOCUS_NEAR = [
    "Baden bei Wien"   => (48.006, 16.231),
    "Deutschlandsberg" => (46.813, 15.216),
    "Liezen"           => (47.567, 14.240),
    "Zwettl"           => (48.603, 15.169),
    "Marz"             => (47.712, 16.417),
]

function haversine_km(lat1, lon1, lat2, lon2)
    a = sind((lat2 - lat1) / 2)^2 + cosd(lat1) * cosd(lat2) * sind((lon2 - lon1) / 2)^2
    12742 * asin(sqrt(a))
end

"""
Nearest qualifying station to a town. A cap keeps "around Zwettl" honest: if
the closest long-record station is 60 km away, that is an error to surface,
not a page to publish.
"""
function nearest_station(stations, town, lat, lon; max_km = 25)
    dists = [haversine_km(lat, lon, st.lat, st.lon) for st in stations]
    i = argmin(dists)
    dists[i] <= max_km || error(
        "Nearest qualifying station to $town is $(stations[i].name), " *
        "$(round(dists[i]; digits=1)) km away — too far for 'around $town'.")
    @info "Resolved" town station = String(stations[i].name) km = round(dists[i]; digits = 1)
    stations[i]
end

"Full slug: lowercase ASCII, umlauts transliterated, runs of other chars → '-'."
function slugify(name)
    s = lowercase(name)
    for (from, to) in ("ä" => "ae", "ö" => "oe", "ü" => "ue", "ß" => "ss")
        s = replace(s, from => to)
    end
    strip(replace(s, r"[^a-z0-9]+" => "-"), '-')
end

"""
Leading words people drop when they say the place: "Bad Ischl" → ischl,
"Wiener Neustadt Flugplatz" → neustadt, "Stift Zwettl" → zwettl.
"""
const SLUG_DROP_WORDS = Set(["bad", "wiener", "stift"])

"""
Leading words that never stand alone but belong to the name: the short slug
keeps the next word too — "St.Pölten Landhaus" → st-poelten, "Groß-Enzersdorf"
→ gross-enzersdorf, "Leiser Berge" → leiser-berge.
"""
const SLUG_PREFIX_WORDS = Set(["st", "sankt", "gross", "leiser"])

"""
Stations whose first word is unique on the site but names a *better-known*
place elsewhere in Austria; they keep the full slug so `/hall` is not Hall bei
Admont when the reader means Hall in Tirol.
"""
const SLUG_FULL_NAME = Set(["Hall bei Admont", "Bruck an der Mur", "Waidhofen an der Ybbs"])

"""
Short, sayable slugs: `/krems`, `/aigen`, `/ischl`, `/st-poelten` — the head of
the name (its first word after `SLUG_DROP_WORDS`, plus one more after
`SLUG_PREFIX_WORDS`) when no other station shares it. Where several do
("Wien …" three times, "Innsbruck …" twice) the station with the longest record
takes the bare head and the others keep their full slug: `wien` is Hohe Warte,
`wien-mariabrunn` stays as it is. An equal record start among rivals is an
error, not a coin toss.
"""
function short_slugs(names, from_years)
    full = slugify.(names)
    function head(s)
        w = split(s, '-')
        length(w) > 1 && w[1] in SLUG_DROP_WORDS && (w = w[2:end])
        join(w[1:min(end, w[1] in SLUG_PREFIX_WORDS ? 2 : 1)], '-')
    end
    heads = head.(full)
    groups = Dict{String,Vector{Int}}()
    for (i, h) in enumerate(heads)
        push!(get!(groups, h, Int[]), i)
    end
    slugs = copy(full)
    for (h, idx) in groups
        length(idx) == 1 && (slugs[only(idx)] = h; continue)
        best = minimum(from_years[i] for i in idx)
        winners = [i for i in idx if from_years[i] == best]
        length(winners) == 1 || error(
            "Short slug '$h' is ambiguous: $(join(names[winners], ", ")) all start in $best.")
        slugs[only(winners)] = h
    end
    for (i, n) in enumerate(names)
        n in SLUG_FULL_NAME && (slugs[i] = full[i])
    end
    length(unique(slugs)) == length(slugs) || error("Station slugs are not unique.")
    slugs
end

# ---------------------------------------------------------------- border

# Borders from geoBoundaries (gbOpen, CC-BY): the API hands out the current
# download URL, we take the simplified geometry and thin it further — a
# station picker needs a recognisable Austria, not cartography. ADM0 is the
# country outline, ADM1 the Bundesländer.
geoboundaries_api(level) = "https://www.geoboundaries.org/api/current/gbOpen/AUT/$level/"

function fetch_geojson(level; refresh::Bool = false)
    mkpath(RAW_DIR)
    path = joinpath(RAW_DIR, "austria_$(lowercase(level)).geo.json")
    if refresh || !isfile(path)
        api = JSON3.read(read(Downloads.download(geoboundaries_api(level)), String))
        url = api.simplifiedGeometryGeoJSON
        @info "Downloading geoBoundaries $level" url
        Downloads.download(url, path)
    end
    JSON3.read(read(path, String))
end

feature_rings(geom) =
    geom.type == "Polygon"      ? [geom.coordinates[1]] :
    geom.type == "MultiPolygon" ? [poly[1] for poly in geom.coordinates] :
    error("Unexpected geometry type $(geom.type)")

"One row per boundary point; `unit` is \"AUT\" (ADM0) or the Bundesland name."
function boundaries_df(gj; max_points = 2500)
    df = DataFrame(unit = String[], ring = Int[], lon = Float64[], lat = Float64[])
    total = sum(sum(length, feature_rings(f.geometry)) for f in gj.features)
    step = max(1, ceil(Int, total / max_points))
    r = 0
    for f in gj.features, ring in feature_rings(f.geometry)
        r += 1
        for (i, pt) in enumerate(ring)
            (i % step == 0 || i == 1 || i == length(ring)) &&
                push!(df, (String(f.properties.shapeName), r, Float64(pt[1]), Float64(pt[2])))
        end
    end
    df
end

austria_border(; refresh::Bool = false)  = boundaries_df(fetch_geojson("ADM0"; refresh); max_points = 1500)
austria_laender(; refresh::Bool = false) = boundaries_df(fetch_geojson("ADM1"; refresh); max_points = 2500)

# ---------------------------------------------------------------- run

function run_ingest(; refresh::Bool = false)
    meta = metadata(; refresh)
    check_parameter(meta)

    qualifying = select_stations(meta; from_year = MAP_FROM_YEAR)
    @info "Qualifying stations (COMBINED, active, record starts ≤ $MAP_FROM_YEAR)" n = length(qualifying)

    focus = vcat(
        [resolve_station(meta, name) for name in FOCUS_EXACT],
        [nearest_station(qualifying, town, lat, lon) for (town, (lat, lon)) in FOCUS_NEAR],
    )
    names_by_id = Dict(st.id => String(st.name) for st in focus)

    # Slugs are assigned over the whole map set so that "the Wien with the
    # longest record" means the same thing on the map and on the focus pages.
    from_year(st) = year(Date(String(st.valid_from)[1:10]))
    map_slugs = short_slugs([String(st.name) for st in qualifying],
                            [from_year(st) for st in qualifying])
    slug_of_id = Dict(st.id => map_slugs[i] for (i, st) in enumerate(qualifying))
    slug_by_id = Dict(st.id => (haskey(slug_of_id, st.id) ? slug_of_id[st.id] :
                                error("Focus station $(st.name) is not a map station; no slug."))
                      for st in focus)

    # Full daily records for the focus stations (cached chunk-wise in data/raw/).
    daily = reduce(vcat, [daily_series(fetch_station(st; refresh)) for st in focus];
                   cols = :union)
    daily.station_name = [names_by_id[id] for id in daily.station_id]
    select!(daily, :date, :station_id, :station_name, :substation_id, :tlmax)
    sort!(daily, [:station_name, :date])

    mkpath(PROC_DIR)
    CSV.write(joinpath(PROC_DIR, "daily_tlmax.csv"), daily)
    @info "Wrote $(nrow(daily)) station-days" file = "daily_tlmax.csv"

    annual = heat_days(daily, names_by_id)
    CSV.write(joinpath(PROC_DIR, "heat_days.csv"), annual)
    @info "Wrote $(nrow(annual)) station-years" file = "heat_days.csv"

    smeta = DataFrame(
        station_id = [st.id for st in focus],
        name       = [String(st.name) for st in focus],
        slug       = [slug_by_id[st.id] for st in focus],
        state      = [String(get(st, :state, "")) for st in focus],
        lat        = [st.lat for st in focus],
        lon        = [st.lon for st in focus],
        altitude   = [get(st, :altitude, missing) for st in focus],
        valid_from = [String(st.valid_from) for st in focus],
        valid_to   = [String(st.valid_to) for st in focus],
        retrieved  = today(),
    )
    CSV.write(joinpath(PROC_DIR, "stations.csv"), smeta)

    mapdf = DataFrame(
        station_id = [st.id for st in qualifying],
        name       = [String(st.name) for st in qualifying],
        state      = [String(get(st, :state, "")) for st in qualifying],
        lat        = [st.lat for st in qualifying],
        lon        = [st.lon for st in qualifying],
        altitude   = [get(st, :altitude, missing) for st in qualifying],
        from_year  = [from_year(st) for st in qualifying],
        tier       = [tier(from_year(st)) for st in qualifying],
        slug       = map_slugs,
        focus      = [haskey(slug_by_id, st.id) for st in qualifying],
        retrieved  = today(),
    )
    sort!(mapdf, :name)
    CSV.write(joinpath(PROC_DIR, "map_stations.csv"), mapdf)
    @info "Wrote map stations" file = "map_stations.csv" n = nrow(mapdf)

    CSV.write(joinpath(PROC_DIR, "austria_border.csv"), austria_border(; refresh))
    CSV.write(joinpath(PROC_DIR, "austria_laender.csv"), austria_laender(; refresh))
    @info "Wrote borders (ADM0 + Bundesländer)"

    (; daily, annual, stations = smeta, map_stations = mapdf)
end

"""
Full history for every qualifying station, then annual counts for all of them.

The daily panel (~4–5 M rows) goes to data/raw/ (gitignored — far past what
belongs in a reviewable diff); only the small annual `heat_days.csv` is
committed. `run_ingest` must have run first (it writes the focus-station
files this replaces nothing of).
"""
function run_ingest_all(; refresh::Bool = false)
    meta = metadata(; refresh)
    qualifying = select_stations(meta; from_year = MAP_FROM_YEAR)
    from_all = minimum(year(Date(String(st.valid_from)[1:10])) for st in qualifying)
    @info "Fetching full history for all qualifying stations" n = length(qualifying) from = from_all

    daily = daily_all(qualifying; refresh, from_year = from_all)
    dropmissing!(daily, :station_name)

    names_all = Dict(st.id => String(st.name) for st in qualifying)
    annual = heat_days(daily, names_all)
    CSV.write(joinpath(PROC_DIR, "heat_days.csv"), annual)
    @info "Wrote all-station annual counts" file = "heat_days.csv" rows = nrow(annual)
    annual
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_ingest(; refresh = "--refresh" in ARGS)
    "--all" in ARGS && run_ingest_all(; refresh = "--refresh" in ARGS)
end
