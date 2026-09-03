### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# ╔═╡ c2e6c834-a532-11f1-badf-7d7af810d34c
begin
    using Downloads
    using JSON3
    using CSV
    using DataFrames
    using Dates
    using Printf
end

# ╔═╡ c2e614b8-a532-11f1-b06d-1b4444990c4f
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
# GeoSphere-Ingest — Hitzetage

Lädt Tagesmaxima der Lufttemperatur (`tlmax`) aus dem GeoSphere Austria Data
Hub und verdichtet sie zu Hitzetagen pro Station, Jahr und Schwelle.

Diese Datei ist **zugleich Notebook und Skript**. Als Skript:

```
julia --project src/ingest/geosphere.jl            # nutzt data/raw/ als Cache
julia --project src/ingest/geosphere.jl --refresh  # lädt alles neu
```

Die Zellen, die nur der Erkundung dienen, sind *skip as script* — sie laufen
in Pluto, aber nicht im Skript und nicht in der CI.

!!! note "Paketverwaltung"
    Dieses Notebook nutzt Plutos eigene Paketverwaltung; die Versionen stehen
    unten in der Datei. Im Skriptmodus zählt stattdessen `Project.toml` des
    Repos — die Pakete hier (CSV, DataFrames, JSON3) sind dort schon drin.
"""
  ╠═╡ =#

# ╔═╡ c2e6cbba-a532-11f1-af76-bf06a4a7c8f1
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## Konfiguration
"""
  ╠═╡ =#

# ╔═╡ c2e6cf48-a532-11f1-b360-5503608b398e
const API = "https://dataset.api.hub.geosphere.at/v1"

# ╔═╡ c2e6d484-a532-11f1-bdd7-af34c7cc0969
const DATASET = "station/historical/klima-v2-1d"

# ╔═╡ c2e6df60-a532-11f1-8939-6588d002fa1a
const PARAM = "tlmax"           # daily maximum air temperature, °C

# ╔═╡ c2e6e186-a532-11f1-b863-c1dbf66e0309
const THRESHOLDS = [25.0, 30.0, 35.0]

# ╔═╡ c2e6e3ca-a532-11f1-957e-3b2f482315b6
# Official station names, matched exactly against the COMBINED series (see
# `resolve_station`). Keep this list short — every station is a separate API
# call and a separate line of explanation on the page.
const WANTED = [
    "Krems",
    "Wien Hohe Warte",
]

# ╔═╡ c2e6e7da-a532-11f1-a070-f94f487c9a84
const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# ╔═╡ c2e703f2-a532-11f1-be6e-0545d79ee56b
const RAW_DIR = joinpath(ROOT, "data", "raw")

# ╔═╡ c2e708fa-a532-11f1-b137-f91dd905d51c
const PROC_DIR = joinpath(ROOT, "data", "processed")

# ╔═╡ c2e70c06-a532-11f1-acad-954131d695e0
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## Metadaten

Stations- und Parameterliste des Datensatzes. Wird unter `data/raw/`
zwischengespeichert.
"""
  ╠═╡ =#

# ╔═╡ c2e70f26-a532-11f1-b19f-a96ec86cab8c
"Fetch (and cache) the dataset metadata: available parameters and stations."
function metadata(; refresh::Bool=false)
    mkpath(RAW_DIR)
    path = joinpath(RAW_DIR, "klima-v2-1d-metadata.json")
    if refresh || !isfile(path)
        @info "Fetching dataset metadata"
        Downloads.download("$API/$DATASET/metadata", path)
    end
    JSON3.read(read(path, String))
end

# ╔═╡ c2e714a0-a532-11f1-be39-afe85e711cc4
"Check that PARAM exists in the dataset; list the alternatives if it does not."
function check_parameter(meta)
    names = [String(p.name) for p in meta.parameters]
    if PARAM ∉ names
        error("""
              Parameter "$PARAM" is not in dataset $DATASET.
              Available: $(join(sort(names), ", "))
              """)
    end
    idx = findfirst(==(PARAM), names)
    @info "Using parameter" name=PARAM long=meta.parameters[idx].long_name unit=meta.parameters[idx].unit
    return PARAM
end

# ╔═╡ c2e72470-a532-11f1-ba2b-6119f9ba4d0a
"""
Resolve a station name to a single station record.

Matching is exact (case-insensitively) and restricted to `COMBINED` stations.
The Data Hub lists both the merged long records (`COMBINED`) and every
`INDIVIDUAL` instrument record they are stitched from, so substring matching
over the whole list is hopelessly ambiguous: "krems" alone hits eight stations,
Kremsmünster among them, and "wien hohe warte" hits five. Ambiguity is an error
rather than a silent first-match, because picking the wrong Vienna station
changes the answer.
"""
function resolve_station(meta, name)
    needle = lowercase(strip(name))
    hits = filter(meta.stations) do st
        String(st.type) == "COMBINED" && lowercase(String(st.name)) == needle
    end
    if isempty(hits)
        near = sort!([String(st.name) for st in meta.stations
                      if String(st.type) == "COMBINED" &&
                         occursin(needle, lowercase(String(st.name)))])
        error("""
              No COMBINED station is named exactly "$name".
              $(isempty(near) ? "Nothing similar either." : "Close: " * join(near, ", "))
              """)
    end
    if length(hits) > 1
        listing = join(["  $(st.id)  $(st.name)" for st in hits], "\n")
        error("Station name \"$name\" is ambiguous:\n$listing")
    end
    only(hits)
end

# ╔═╡ c2e727ec-a532-11f1-b1f0-839adb3e056b
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
### Erkundung

Ab hier nur Entwicklung — diese Zellen laufen nicht im Skript.
"""
  ╠═╡ =#

# ╔═╡ c2e729fc-a532-11f1-af68-9b195a4dee2f
# ╠═╡ skip_as_script = true
#=╠═╡
meta = metadata()
  ╠═╡ =#

# ╔═╡ c2e72f92-a532-11f1-b89d-13cf12a9555c
# ╠═╡ skip_as_script = true
#=╠═╡
check_parameter(meta)
  ╠═╡ =#

# ╔═╡ c2e74130-a532-11f1-a4c4-1de4e2353d2e
# ╠═╡ skip_as_script = true
#=╠═╡
# Which stations does WANTED actually resolve to?
DataFrame(
    wanted = WANTED,
    id     = [resolve_station(meta, n).id for n in WANTED],
    name   = [String(resolve_station(meta, n).name) for n in WANTED],
    from   = [String(resolve_station(meta, n).valid_from)[1:10] for n in WANTED],
    state  = [String(resolve_station(meta, n).state) for n in WANTED],
)
  ╠═╡ =#

# ╔═╡ c2e74482-a532-11f1-aa49-6d093180d44c
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## Rohdaten holen und verdichten
"""
  ╠═╡ =#

# ╔═╡ c2e748c4-a532-11f1-911c-7db24957ab3a
"""
Download daily values for one station, in chunks. The API rejects very long
ranges, and chunking also means a failed year does not cost the whole record.
"""
function fetch_station(station; refresh::Bool=false)
    id = station.id
    from = Date(String(station.valid_from)[1:10])
    to   = min(Date(String(station.valid_to)[1:10]), today())

    mkpath(RAW_DIR)
    frames = DataFrame[]
    for y0 in year(from):20:year(to)
        y1 = min(y0 + 19, year(to))
        path = joinpath(RAW_DIR, "$(id)_$(y0)_$(y1).csv")
        if refresh || !isfile(path)
            url = string(API, "/", DATASET,
                         "?parameters=", PARAM,
                         "&station_ids=", id,
                         "&start=", Date(y0, 1, 1), "T00:00",
                         "&end=", Date(y1, 12, 31), "T23:59",
                         "&output_format=csv")
            @info "Downloading" station=String(station.name) years="$(y0)–$(y1)"
            Downloads.download(url, path)
            sleep(1)   # be polite to a free public API
        end
        push!(frames, CSV.read(path, DataFrame; missingstring=["", "NA", "NaN"]))
    end
    reduce(vcat, frames; cols=:union)
end

# ╔═╡ c2e7538e-a532-11f1-8b7c-b3368ad7a44f
"""
Collapse daily maxima into one row per station and calendar year.

`n_observed` is carried through deliberately: a year with 200 observed days
looks like a cool year if you only count exceedances.
"""
function heat_days(daily::DataFrame, names_by_id::AbstractDict)
    d = transform(daily, :date => ByRow(year) => :year)

    out = combine(groupby(d, [:station_id, :year]),
        nrow => :n_observed,
        :date => (v -> count(x -> 6 <= month(x) <= 8, v)) => :jja_observed,
        # the JJA days the year could have shown so far: 92 once August is
        # over, fewer while the year is still being measured
        :date => (v -> max(0, Dates.value(min(Date(year(maximum(v)), 8, 31), maximum(v)) -
                                          Date(year(maximum(v)), 6, 1)) + 1)) => :jja_sofar,
        [:tlmax => (v -> count(>=(t), v)) => Symbol("days_ge_$(Int(t))") for t in THRESHOLDS]...,
        :tlmax => maximum => :tmax_year)

    out.station_name = [names_by_id[id] for id in out.station_id]

    # A year is comparable iff its summer is fully measured (Fabian,
    # 2026-09-03): the days this site counts fall almost entirely in
    # June–August, so a broken July makes the count a lie while a missing
    # January does not. The running year is judged by its summer *so far* —
    # unfinished is fine, a hole in what is already measured is not. For a
    # past year "so far" would excuse a summer the station simply stopped
    # measuring, so there the full 92 days are required.
    running = year(today())
    out.complete = [r.year == running ? r.jja_observed == r.jja_sofar :
                                        r.jja_observed == 92 for r in eachrow(out)]

    select!(out, :station_id, :station_name, :year, :n_observed, :jja_observed,
            Symbol.("days_ge_" .* string.(Int.(THRESHOLDS)))..., :tmax_year, :complete)
    sort!(out, [:station_name, :year])
end

# ╔═╡ c2e75722-a532-11f1-9e90-5bdb2d9753c5
"""
Tidy a raw API response into one row per station-day.

`substation_id` is kept deliberately. A `COMBINED` station is GeoSphere's
merged long record, stitched from successive `INDIVIDUAL` instrument records as
the station moved — Krems runs 3807 → 3800 (Landersdorf, 1977) → 3801 → 3805,
Hohe Warte 5902 → 5901 → 5904. Carrying the column through lets a plot style
those segments differently instead of implying one unbroken instrument.
"""
function daily_series(df)
    tcol = only(intersect(names(df), ["time", "Zeit"]))
    vcol = only(filter(n -> occursin(PARAM, lowercase(n)), names(df)))

    out = DataFrame(
        date          = Date.(SubString.(string.(df[!, tcol]), 1, 10)),
        station_id    = df[!, "station"],
        substation_id = "substation" in names(df) ? df[!, "substation"] : missing,
        tlmax         = df[!, vcol],
    )
    dropmissing!(out, :tlmax)
    sort!(out, [:station_id, :date])
end

# ╔═╡ c2e75af6-a532-11f1-be90-7d55c205d1ef
"""
Focus stations (`WANTED`) end to end: daily series, annual heat-day counts and
station metadata, all into `data/processed/`.

For the wide panel instead, see `select_stations` + `daily_all`.
"""
function main(; refresh::Bool=false)
    meta = metadata(; refresh)
    check_parameter(meta)

    stations = [resolve_station(meta, spec) for spec in WANTED]
    for st in stations
        @info "Station" id=st.id name=String(st.name) from=st.valid_from to=st.valid_to
    end
    names_by_id = Dict(st.id => String(st.name) for st in stations)

    daily = reduce(vcat, [daily_series(fetch_station(st; refresh)) for st in stations];
                   cols=:union)
    daily.station_name = [names_by_id[id] for id in daily.station_id]
    select!(daily, :date, :station_id, :station_name, :substation_id, :tlmax)
    sort!(daily, [:station_name, :date])

    mkpath(PROC_DIR)
    CSV.write(joinpath(PROC_DIR, "daily_tlmax.csv"), daily)
    @info "Wrote $(nrow(daily)) station-days" file="daily_tlmax.csv"

    annual = heat_days(daily, names_by_id)
    CSV.write(joinpath(PROC_DIR, "heat_days.csv"), annual)
    @info "Wrote $(nrow(annual)) station-years" file="heat_days.csv"

    smeta = DataFrame(
        station_id = [st.id for st in stations],
        name       = [String(st.name) for st in stations],
        state      = [String(get(st, :state, "")) for st in stations],
        lat        = [st.lat for st in stations],
        lon        = [st.lon for st in stations],
        altitude   = [get(st, :altitude, missing) for st in stations],
        valid_from = [String(st.valid_from) for st in stations],
        valid_to   = [String(st.valid_to) for st in stations],
        retrieved  = today(),
    )
    CSV.write(joinpath(PROC_DIR, "stations.csv"), smeta)

    (; daily, annual, stations = smeta)
end

# ╔═╡ c2e75db4-a532-11f1-9640-932f19594844
# Script entry point. In Pluto, PROGRAM_FILE is the Julia binary and @__FILE__
# carries a cell suffix, so this stays false and opening the notebook never
# touches the network. Do NOT mark this cell skip_as_script — the script needs it.
if abspath(PROGRAM_FILE) == @__FILE__
    main(; refresh = "--refresh" in ARGS)
end

# ╔═╡ c2e75f4e-a532-11f1-8264-7118d86bbbb5
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
!!! tip "Interaktiv laufen lassen"
    `main()` wird beim Öffnen des Notebooks **nicht** ausgeführt. Zum manuellen
    Durchlauf eine neue Zelle mit `main()` anlegen (bzw. `main(refresh = true)`),
    oder das Skript aus der Shell starten.
"""
  ╠═╡ =#

# ╔═╡ c2e762be-a532-11f1-a1c5-059a43ef6718
# ╠═╡ skip_as_script = true
#=╠═╡
md"""
## Viele Stationen auf einmal

Die API nimmt `station_ids` als Komma-Liste. Das ist der ganze Unterschied
zwischen „geht" und „geht nicht": alle 138 Langzeit-Stationen für ein Jahr
kommen in **einer** Antwort von ~1,8 MB in gut zwei Sekunden zurück. Eine
Anfrage pro Station wäre hier Minuten.
"""
  ╠═╡ =#

# ╔═╡ c2e76700-a532-11f1-bdee-edb8dfd04304
"""
Every `COMBINED` (merged long-record) station still reporting today whose record
starts no later than `from_year`.

`COMBINED` is the important part: the Data Hub also lists each `INDIVIDUAL`
instrument record separately, and those are the pieces the merged series is
stitched from — counting both would double-count every station.
"""
function select_stations(meta; from_year::Int = 1970)
    sts = [st for st in meta.stations
           if String(st.type) == "COMBINED" &&
              st.is_active &&
              year(Date(String(st.valid_from)[1:10])) <= from_year]
    sort(sts; by = st -> String(st.name))
end

# ╔═╡ c2e77d4e-a532-11f1-970f-11fa75e01999
"""
Download `tlmax` for many stations in one request per time chunk.

Cached per (station set, chunk) under `data/raw/`. `years_per_request` trades
response size against request count: 5 years x 138 stations is roughly 9 MB.
"""
function fetch_batch(stations; from_year::Int = 1970, refresh::Bool = false,
                     years_per_request::Int = 5)
    ids  = [st.id for st in stations]
    tag  = string(hash(sort(ids)); base = 16)[1:8]
    to   = year(today())

    mkpath(RAW_DIR)
    frames = DataFrame[]
    for y0 in from_year:years_per_request:to
        y1 = min(y0 + years_per_request - 1, to)
        path = joinpath(RAW_DIR, "batch_$(tag)_$(y0)_$(y1).csv")
        if refresh || !isfile(path)
            url = string(API, "/", DATASET,
                         "?parameters=", PARAM,
                         "&station_ids=", join(ids, ","),
                         "&start=", Date(y0, 1, 1), "T00:00",
                         "&end=", Date(y1, 12, 31), "T23:59",
                         "&output_format=csv")
            @info "Downloading batch" n_stations=length(ids) years="$(y0)–$(y1)"
            Downloads.download(url, path)
            sleep(1)   # be polite to a free public API
        end
        push!(frames, CSV.read(path, DataFrame; missingstring=["", "NA", "NaN"]))
    end
    reduce(vcat, frames; cols=:union)
end

# ╔═╡ c2e780e6-a532-11f1-9f76-db06b3be1435
"""
Full daily series for many stations. Writes `data/raw/daily_tlmax_all.csv`,
which is gitignored — 138 stations from 1970 is ~2.9 M rows / ~130 MB, far past
what belongs in a reviewable diff. The committed `data/processed/daily_tlmax.csv`
covers the focus stations only.

    meta = metadata()
    sts  = select_stations(meta; from_year = 1970)
    daily_all(sts)
"""
function daily_all(stations; refresh::Bool = false, from_year::Int = 1970)
    raw   = fetch_batch(stations; from_year, refresh)
    daily = daily_series(raw)

    names_by_id = Dict(st.id => String(st.name) for st in stations)
    daily.station_name = [get(names_by_id, id, missing) for id in daily.station_id]
    select!(daily, :date, :station_id, :station_name, :substation_id, :tlmax)

    out = joinpath(RAW_DIR, "daily_tlmax_all.csv")
    CSV.write(out, daily)
    @info "Wrote $(nrow(daily)) station-days" file=out stations=length(stations)
    daily
end

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
Downloads = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
Printf = "de0858da-6303-5e67-8744-51eddeeeb8d7"

[compat]
CSV = "~0.10.17"
DataFrames = "~1.8.2"
JSON3 = "~1.14.3"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.12.7"
manifest_format = "2.0"
project_hash = "ca78e2dde94a452772ee7a5d91e8647f8193b2ce"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.2"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"
version = "1.11.0"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"
version = "1.11.0"

[[deps.CSV]]
deps = ["CodecZlib", "Dates", "FilePathsBase", "InlineStrings", "Mmap", "Parsers", "PooledArrays", "PrecompileTools", "SentinelArrays", "Tables", "Unicode", "WeakRefStrings", "WorkerUtilities"]
git-tree-sha1 = "abed1e735dd4152f48c90cf0767e1790e25f332f"
uuid = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
version = "0.10.17"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "970758a3d591a2a5c2a907c53f2e2f8c1b1d3537"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.9"

[[deps.Compat]]
deps = ["TOML", "UUIDs"]
git-tree-sha1 = "9d8a54ce4b17aa5bdce0ea5c34bc5e7c340d16ad"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "4.18.1"
weakdeps = ["Dates", "LinearAlgebra"]

    [deps.Compat.extensions]
    CompatLinearAlgebraExt = "LinearAlgebra"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.3.1+2"

[[deps.Crayons]]
git-tree-sha1 = "54b76cbb40d9a0f5368c880725b2f141da77c94f"
uuid = "a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f"
version = "4.2.0"

[[deps.DataAPI]]
git-tree-sha1 = "abe83f3a2f1b857aac70ef8b269080af17764bbe"
uuid = "9a962f9c-6df0-11e9-0e5d-c546b8b5ee8a"
version = "1.16.0"

[[deps.DataFrames]]
deps = ["Compat", "DataAPI", "DataStructures", "Future", "InlineStrings", "InvertedIndices", "IteratorInterfaceExtensions", "LinearAlgebra", "Markdown", "Missings", "PooledArrays", "PrecompileTools", "PrettyTables", "Printf", "Random", "Reexport", "SentinelArrays", "SortingAlgorithms", "Statistics", "TableTraits", "Tables", "Unicode"]
git-tree-sha1 = "5fab31e2e01e70ad66e3e24c968c264d1cf166d6"
uuid = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
version = "1.8.2"

[[deps.DataStructures]]
deps = ["OrderedCollections"]
git-tree-sha1 = "b0bc6d2cad1fed8b7fd59a1551a991cb3d2809e6"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.19.6"

[[deps.DataValueInterfaces]]
git-tree-sha1 = "bfc1187b79289637fa0ef6d4436ebdfe6905cbd6"
uuid = "e2d170a0-9d28-54be-80f0-106bbe20a464"
version = "1.0.0"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
version = "1.11.0"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.7.0"

[[deps.FilePathsBase]]
deps = ["Compat", "Dates"]
git-tree-sha1 = "3bab2c5aa25e7840a4b065805c0cdfc01f3068d2"
uuid = "48062228-2e41-5def-b9a4-89aafe57970f"
version = "0.9.24"

    [deps.FilePathsBase.extensions]
    FilePathsBaseMmapExt = "Mmap"
    FilePathsBaseTestExt = "Test"

    [deps.FilePathsBase.weakdeps]
    Mmap = "a63ad114-7e13-5084-954f-fe012c677804"
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"
version = "1.11.0"

[[deps.Future]]
deps = ["Random"]
uuid = "9fa8497b-333b-5362-9e8d-4d0656e87820"
version = "1.11.0"

[[deps.InlineStrings]]
git-tree-sha1 = "8f3d257792a522b4601c24a577954b0a8cd7334d"
uuid = "842dd82b-1e85-43dc-bf29-5d0ee9dffc48"
version = "1.4.5"

    [deps.InlineStrings.extensions]
    ArrowTypesExt = "ArrowTypes"
    ParsersExt = "Parsers"

    [deps.InlineStrings.weakdeps]
    ArrowTypes = "31f734f8-188a-4ce0-8406-c8a06bd891cd"
    Parsers = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"
version = "1.11.0"

[[deps.InvertedIndices]]
git-tree-sha1 = "6da3c4316095de0f5ee2ebd875df8721e7e0bdbe"
uuid = "41ab1584-1d38-5bbf-9106-f11c6c58b48f"
version = "1.3.1"

[[deps.IteratorInterfaceExtensions]]
git-tree-sha1 = "a3f24677c21f5bbe9d2a714f95dcd58337fb2856"
uuid = "82899510-4779-5014-852e-03e436cf321d"
version = "1.0.0"

[[deps.JSON3]]
deps = ["Dates", "Mmap", "Parsers", "PrecompileTools", "StructTypes", "UUIDs"]
git-tree-sha1 = "411eccfe8aba0814ffa0fdf4860913ed09c34975"
uuid = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
version = "1.14.3"

    [deps.JSON3.extensions]
    JSON3ArrowExt = ["ArrowTypes"]

    [deps.JSON3.weakdeps]
    ArrowTypes = "31f734f8-188a-4ce0-8406-c8a06bd891cd"

[[deps.JuliaSyntaxHighlighting]]
deps = ["StyledStrings"]
uuid = "ac6e5ff7-fb65-4e79-a425-ec3bc9c03011"
version = "1.12.0"

[[deps.LaTeXStrings]]
git-tree-sha1 = "f88f3ccef05a6a72a0cf0ed417c8fd68530f4ab2"
uuid = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
version = "1.4.1"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.4"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "OpenSSL_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "8.15.0+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "OpenSSL_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.3+1"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
version = "1.11.0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
version = "1.12.0"

[[deps.Markdown]]
deps = ["Base64", "JuliaSyntaxHighlighting", "StyledStrings"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"
version = "1.11.0"

[[deps.Missings]]
deps = ["DataAPI"]
git-tree-sha1 = "ec4f7fbeab05d7747bdf98eb74d130a2a2ed298d"
uuid = "e1d29d7a-bbdc-5cf2-9ac0-f12de2c33e28"
version = "1.2.0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"
version = "1.11.0"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2025.11.4"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.3.0"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.29+0"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "3.5.6+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "05f45c2e0de6259db764adbfd2f1dc6d3f8de13c"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "2.0.1"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "3de8f5e6e90ebfa8d6d1f86997d6cdcd6a912ff3"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.7"

[[deps.PooledArrays]]
deps = ["DataAPI", "Future"]
git-tree-sha1 = "36d8b4b899628fb92c2749eb488d884a926614d3"
uuid = "2dfb63ee-cc39-5dd5-95bd-886bf059d720"
version = "1.4.3"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "edbeefc7a4889f528644251bdb5fc9ab5348bc2c"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.3.4"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "8b770b60760d4451834fe79dd483e318eee709c4"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.5.2"

[[deps.PrettyTables]]
deps = ["Crayons", "LaTeXStrings", "Markdown", "PrecompileTools", "Printf", "REPL", "Reexport", "StringManipulation", "Tables"]
git-tree-sha1 = "1b8aa19f229b1cea7fc93874a52e49db6a854450"
uuid = "08abe8d2-0d0c-5749-adfa-8a2ac140af0d"
version = "3.4.8"

    [deps.PrettyTables.extensions]
    PrettyTablesExcelExt = "XLSX"
    PrettyTablesTypstryExt = "Typstry"

    [deps.PrettyTables.weakdeps]
    Typstry = "f0ed7684-a786-439e-b1e3-3b82803b501e"
    XLSX = "fdbf4ff8-1666-58a4-91e7-1b58723a45e0"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
version = "1.11.0"

[[deps.REPL]]
deps = ["InteractiveUtils", "JuliaSyntaxHighlighting", "Markdown", "Sockets", "StyledStrings", "Unicode"]
uuid = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"
version = "1.11.0"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
version = "1.11.0"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.SentinelArrays]]
deps = ["Dates", "Random"]
git-tree-sha1 = "084c47c7c5ce5cfecefa0a98dff69eb3646b5a80"
uuid = "91c51154-3ec4-41a3-a24f-3f23e20d615c"
version = "1.4.10"

[[deps.Sockets]]
uuid = "6462fe0b-24de-5631-8697-dd941f90decc"
version = "1.11.0"

[[deps.SortingAlgorithms]]
deps = ["DataStructures"]
git-tree-sha1 = "13cd91cc9be159e3f4d95b857fa2aa383b53772a"
uuid = "a2af1166-a08f-5f64-846c-94a0d3cef48c"
version = "1.2.3"

[[deps.Statistics]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "389592b8592e5fb48f498ff60dc6acb4a0e62953"
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.11.4"

    [deps.Statistics.extensions]
    SparseArraysExt = ["SparseArrays"]

    [deps.Statistics.weakdeps]
    SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"

[[deps.StringManipulation]]
deps = ["PrecompileTools"]
git-tree-sha1 = "773065c6e0e903924a9d838259be74338422aef2"
uuid = "892a3eda-7b42-436c-8928-eab12a02cf0e"
version = "0.5.0"

[[deps.StructTypes]]
deps = ["Dates", "UUIDs"]
git-tree-sha1 = "159331b30e94d7b11379037feeb9b690950cace8"
uuid = "856f2bd8-1eba-4b0a-8007-ebc267875bd4"
version = "1.11.0"

[[deps.StyledStrings]]
uuid = "f489334b-da3d-4c2e-b8f0-e476e12c162b"
version = "1.11.0"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.TableTraits]]
deps = ["IteratorInterfaceExtensions"]
git-tree-sha1 = "c06b2f539df1c6efa794486abfb6ed2022561a39"
uuid = "3783bdb8-4a98-5b6b-af9a-565f29a5fe9c"
version = "1.0.1"

[[deps.Tables]]
deps = ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "OrderedCollections", "TableTraits"]
git-tree-sha1 = "a94d9bdda1b7bed0046cea645639ab3f62196fac"
uuid = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
version = "1.14.0"

[[deps.TranscodingStreams]]
git-tree-sha1 = "0c45878dcfdcfa8480052b6ab162cdd138781742"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.11.3"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
version = "1.11.0"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
version = "1.11.0"

[[deps.WeakRefStrings]]
deps = ["DataAPI", "InlineStrings", "Parsers"]
git-tree-sha1 = "0716e01c3b40413de5dedbc9c5c69f27cddfddfc"
uuid = "ea10d353-3f73-51f8-a26c-33c1cb351aa5"
version = "1.4.3"

[[deps.WorkerUtilities]]
git-tree-sha1 = "cd1659ba0d57b71a464a29e64dbc67cfe83d54e7"
uuid = "76eceee3-57b5-4d4a-8e66-0e911cebbf60"
version = "1.6.1"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.3.1+2"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.15.0+0"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.64.0+1"
"""

# ╔═╡ Cell order:
# ╟─c2e614b8-a532-11f1-b06d-1b4444990c4f
# ╠═c2e6c834-a532-11f1-badf-7d7af810d34c
# ╟─c2e6cbba-a532-11f1-af76-bf06a4a7c8f1
# ╠═c2e6cf48-a532-11f1-b360-5503608b398e
# ╠═c2e6d484-a532-11f1-bdd7-af34c7cc0969
# ╠═c2e6df60-a532-11f1-8939-6588d002fa1a
# ╠═c2e6e186-a532-11f1-b863-c1dbf66e0309
# ╠═c2e6e3ca-a532-11f1-957e-3b2f482315b6
# ╠═c2e6e7da-a532-11f1-a070-f94f487c9a84
# ╠═c2e703f2-a532-11f1-be6e-0545d79ee56b
# ╠═c2e708fa-a532-11f1-b137-f91dd905d51c
# ╟─c2e70c06-a532-11f1-acad-954131d695e0
# ╠═c2e70f26-a532-11f1-b19f-a96ec86cab8c
# ╠═c2e714a0-a532-11f1-be39-afe85e711cc4
# ╠═c2e72470-a532-11f1-ba2b-6119f9ba4d0a
# ╟─c2e727ec-a532-11f1-b1f0-839adb3e056b
# ╠═c2e729fc-a532-11f1-af68-9b195a4dee2f
# ╠═c2e72f92-a532-11f1-b89d-13cf12a9555c
# ╠═c2e74130-a532-11f1-a4c4-1de4e2353d2e
# ╟─c2e74482-a532-11f1-aa49-6d093180d44c
# ╠═c2e748c4-a532-11f1-911c-7db24957ab3a
# ╠═c2e7538e-a532-11f1-8b7c-b3368ad7a44f
# ╠═c2e75722-a532-11f1-9e90-5bdb2d9753c5
# ╠═c2e75af6-a532-11f1-be90-7d55c205d1ef
# ╠═c2e75db4-a532-11f1-9640-932f19594844
# ╟─c2e75f4e-a532-11f1-8264-7118d86bbbb5
# ╟─c2e762be-a532-11f1-a1c5-059a43ef6718
# ╠═c2e76700-a532-11f1-bdee-edb8dfd04304
# ╠═c2e77d4e-a532-11f1-970f-11fa75e01999
# ╠═c2e780e6-a532-11f1-9f76-db06b3be1435
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
