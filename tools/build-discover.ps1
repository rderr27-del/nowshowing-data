<#
  Ranks the Discover lists. Run after build-catalog.ps1 (it reads catalog.tsv from
  the same folder):

      powershell -ExecutionPolicy Bypass -File tools\build-discover.ps1

  Writes discover-pools.json (to public/ unless -OutDir says otherwise): the ranked
  movie ids behind each list. It's an in-between file: build-details.ps1 fetches
  details for every movie in it, and build-feed.ps1 turns it into discover.json.

  How the lists are made (also explained on the app's Info page):
    Trending, Week      TMDB's own trending list for the week (what people are viewing
                        on TMDB now).
    Trending, Month /   The most popular movies (TMDB popularity) first released in
      3 Months / Year   the last 30 / 91 / 365 days.
    Top 25 by Year      Per release year, a weighted rating: a movie's TMDB score, pulled
                        toward that year's average when it has few votes, so a 9.0
                        from 40 votes can't outrank an 8.4 from 20,000 (the method
                        IMDb uses for its Top 250). Movies need -MinYearVotes votes
                        to be ranked (fewer for the current and last year).
  Each list keeps a deeper "pool" than it shows (-PoolSize), so the app can filter it by
  genre and streaming service on the phone and still fill the list.

  FUTURE RATINGS (OMDb etc.): ranking goes through Get-RankScore below. To blend in
  IMDb or Rotten Tomatoes scores later, read them there (for example from the
  ratings block build-details.ps1 writes into each movie's file); nothing in the
  app needs to change, because the app only reads the order of the ids.
#>
param(
    [int]$PoolSize = 100,
    [int]$TrendingPool = 200,
    [int]$MinYearVotes = 200,
    [int]$MinRecentVotes = 50,
    [int]$FirstYear = 1920,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

. "$PSScriptRoot\common.ps1"

$catalog = Read-Catalog $OutDir
Write-Host "catalog: $($catalog.Count) movies"
$today = Get-UtcToday
$thisYear = $today.Year

# ── Ranking score ─────────────────────────────────────────────────────────
# Weighted ("Bayesian") rating: v/(v+m)*R + m/(v+m)*C, where R is the movie's score,
# v its votes, m the minimum votes to be ranked, and C the average score of the
# ranked movies that year.
function Get-RankScore($movie, [double]$m, [double]$c) {
    $v = [double]$movie.votes
    return ($v / ($v + $m)) * $movie.score + ($m / ($v + $m)) * $c
}

# ── Top by year ───────────────────────────────────────────────────────────
$byYear = @{}
foreach ($movie in $catalog.Values) {
    if (-not $movie.year) { continue }
    if (-not $byYear.ContainsKey($movie.year)) { $byYear[$movie.year] = New-Object System.Collections.Generic.List[object] }
    $byYear[$movie.year].Add($movie)
}
$years = [ordered]@{}
for ($y = $thisYear; $y -ge $FirstYear; $y--) {
    $all = $byYear["$y"]
    if (-not $all) { continue }
    $m = if ($y -ge $thisYear - 1) { $MinRecentVotes } else { $MinYearVotes }
    $ranked = @($all | Where-Object { $_.votes -ge $m -and $_.score -gt 0 })
    if ($ranked.Count -lt 10) { continue }
    $c = ($ranked | Measure-Object score -Average).Average
    $years["$y"] = @($ranked | Sort-Object @{ e = { Get-RankScore $_ $m $c }; Descending = $true }, @{ e = 'votes'; Descending = $true } |
        Select-Object -First $PoolSize | ForEach-Object { $_.id })
}
Write-Host "years: $($years.Count) ($(@($years.Keys)[-1])-$(@($years.Keys)[0]))"

# ── Trending ──────────────────────────────────────────────────────────────
$urls = @(for ($p = 1; $p -le [Math]::Ceiling($TrendingPool / 20); $p++) { Get-TmdbUrl '/trending/movie/week' @{ page = $p; language = 'en-US' } })
$pages = Get-JsonMany $urls 10 'trending pages'
$week = New-Object System.Collections.Generic.List[int]
foreach ($u in $urls) {   # in page order, so the rank is kept
    $page = $pages[$u]
    if (-not $page) { continue }
    foreach ($m in $page.results) {
        if ($m.adult -or $week.Contains([int]$m.id)) { continue }
        $week.Add([int]$m.id)
    }
}
if ($week.Count -lt 20) { throw "TMDB trending came back with only $($week.Count) movies" }

$trending = [ordered]@{ week = $week.ToArray() }
foreach ($w in @(@('month', 30), @('quarter', 91), @('year', 365))) {
    $since = $today.AddDays(-$w[1]).ToString('yyyy-MM-dd')
    $until = $today.ToString('yyyy-MM-dd')
    $trending[$w[0]] = @($catalog.Values |
        Where-Object { $_.released -and $_.released -ge $since -and $_.released -le $until } |
        Sort-Object @{ e = 'popularity'; Descending = $true } |
        Select-Object -First $TrendingPool | ForEach-Object { $_.id })
}
Write-Host ("trending: week {0}, month {1}, 3 months {2}, year {3}" -f $trending.week.Count, $trending.month.Count, $trending.quarter.Count, $trending.year.Count)

Write-JsonFile (Join-Path $OutDir 'discover-pools.json') ([ordered]@{
    updated  = $today.ToString('yyyy-MM-dd')
    trending = $trending
    years    = $years
})
Write-Host 'Wrote discover-pools.json'
