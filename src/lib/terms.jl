# What a day above each threshold is called. ZAMG/GeoSphere usage: ≥ 25 °C is
# a *Sommertag*, ≥ 30 °C a *Hitzetag*, ≥ 35 °C an *extrem heißer Tag* (the
# colloquial *Wüstentag* is not an official term; the DWD calls the same day
# *sehr heißer Tag*). One table for every page, so the words cannot drift
# between the station pages, the landing page and the chart titles.
#
# `plain`/`sing` are the everyday forms the interpretation sentences use:
# "35-Grad-Tage" reads like speech, "extrem heiße Tage" like a bulletin. The
# method block introduces "35-Grad-Tag" as a term; it also sidesteps a pedant's
# point — the threshold is ≥ 35, a day at exactly 35.0 counts, "über 35" would
# not.

const DAY_TERMS = Dict(
    25 => (nom = "Sommertage",        dat = "Sommertagen",         plain = "Sommertage",  sing = "Sommertag"),
    30 => (nom = "Hitzetage",         dat = "Hitzetagen",          plain = "Hitzetage",   sing = "Hitzetag"),
    35 => (nom = "Extrem heiße Tage", dat = "extrem heißen Tagen", plain = "35-Grad-Tage", sing = "35-Grad-Tag"),
)

"Nominative plural, capitalised as a heading word: `Hitzetage`."
day_term(threshold) = DAY_TERMS[threshold].nom
"Dative plural for `mit den meisten …`: `Hitzetagen`."
day_term_dat(threshold) = DAY_TERMS[threshold].dat
"Lower-case for mid-sentence use — only the adjective form changes."
day_term_lc(threshold) = threshold == 35 ? "extrem heiße Tage" : day_term(threshold)
"Everyday plural for the interpretation sentences: `35-Grad-Tage`."
day_term_plain(threshold) = DAY_TERMS[threshold].plain
"Everyday singular: `ein Hitzetag`, `ein 35-Grad-Tag`."
day_term_sing(threshold) = DAY_TERMS[threshold].sing

# ---- numbers as German prose has them

const NUM_DE = ["ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht",
                "neun", "zehn", "elf", "zwölf"]
"Numbers up to twelve in words; digits above."
num_de(n) = 1 <= n <= 12 ? NUM_DE[n] : string(n)
"`1971 und 1983`, `1962, 1971 und 1983`."
join_de(xs) = length(xs) == 1 ? string(only(xs)) :
              join(string.(xs[1:end-1]), ", ") * " und " * string(xs[end])

const ORDINAL_DE = Dict(2 => "zweit", 3 => "dritt", 4 => "viert", 5 => "fünft", 6 => "sechst",
                        7 => "siebt", 8 => "acht", 9 => "neunt", 10 => "zehnt", 11 => "elft",
                        12 => "zwölft", 13 => "dreizehnt", 14 => "vierzehnt", 15 => "fünfzehnt",
                        16 => "sechzehnt", 17 => "siebzehnt", 18 => "achtzehnt", 19 => "neunzehnt",
                        20 => "zwanzigst")
"Ordinal stem for „die zweitmeisten“ … „die zwanzigstmeisten“; anything else is a build error."
ordinal_de(n) = get(ORDINAL_DE, n) do
    error("ordinal_de: no word for rank $n")
end
