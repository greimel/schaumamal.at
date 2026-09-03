using Makie

"Shared look for every chart on the site."
function klima_theme()
    Theme(
        fontsize = 15,
        figure_padding = 12,
        Axis = (
            xgridvisible = false,
            ygridvisible = true,
            ygridcolor = (:black, 0.08),
            topspinevisible = false,
            rightspinevisible = false,
            leftspinevisible = false,
            xtickcolor = (:black, 0.4),
            ytickcolor = (:black, 0.0),
            titlealign = :left,
            titlesize = 17,
        ),
        Legend = (framevisible = false, padding = (0, 0, 0, 0)),
    )
end

"Colour per station. Deliberately few, deliberately distinguishable."
const STATION_COLORS = [
    "#1b6ca8", "#c0392b", "#2e8b57", "#8e44ad", "#d68910",
]

"Centred moving average of width `w` (odd). Ends are shortened, not padded."
function centred_ma(v::AbstractVector, w::Integer)
    @assert isodd(w)
    h = w ÷ 2
    n = length(v)
    out = Vector{Union{Missing,Float64}}(missing, n)
    for i in eachindex(v)
        lo, hi = i - h, i + h
        (lo < 1 || hi > n) && continue
        out[i] = sum(@view v[lo:hi]) / w
    end
    out
end
