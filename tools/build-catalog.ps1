<#
  Builds the search catalog: every movie on TMDB with at least -MinVotes votes, plus
  announced and recent movies too new to have votes, from TMDB's "discover" search,
  one release year at a time.

      $env:TMDB_API_KEY = '...'
      powershell -ExecutionPolicy Bypass -File tools\build-catalog.ps1

  Writes (to public/ unless -OutDir says otherwise):
    catalog.tsv    one movie per line, most popular first. Columns (see common.ps1):
                   id, title, year, released (yyyy-MM-dd), popularity, score (TMDB
                   average out of 10), votes, poster path, genre ids (1|2|3), language
    genres.json    TMDB's genre list: [{id, name}]

  TMDB's discover search returns at most 500 pages (10,000 movies) per query, so it's
  asked one year at a time; no year has more than that many movies with enough votes.
  Adult titles are left out. Takes a few minutes (~5,000 requests).
#>
param(
    [int]$MinVotes = 10,
    [int]$FirstYear = 1900,
    [int]$UpcomingPages = 25,   # pages (of 20) of not-yet-voted movies per recent year
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

. "$PSScriptRoot\common.ps1"
New-Item -ItemType Directory -Force $OutDir | Out-Null

# ── Genres ────────────────────────────────────────────────────────────────
$g = Get-Json (Get-TmdbUrl '/genre/movie/list' @{ language = 'en-US' })
if (-not $g -or -not $g.genres) { throw 'TMDB genre list came back empty' }
Write-JsonFile (Join-Path $OutDir 'genres.json') @($g.genres | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })
Write-Host "genres: $($g.genres.Count)"

# ── Movies, a year at a time ──────────────────────────────────────────────
$thisYear = (Get-UtcToday).Year
$movies = @{}
function Add-Results($pages) {
    foreach ($page in $pages) {
        if (-not $page) { continue }
        foreach ($m in $page.results) {
            if ($m.adult -or -not $m.title) { continue }
            $movies[[int]$m.id] = $m
        }
    }
}

function Get-DiscoverPages([hashtable]$query, [int]$maxPages) {
    $first = Get-Json (Get-TmdbUrl '/discover/movie' ($query + @{ page = 1 }))
    if (-not $first) { return @() }
    $pages = [Math]::Min([Math]::Min([int]$first.total_pages, 500), $maxPages)
    $urls = @(for ($p = 2; $p -le $pages; $p++) { Get-TmdbUrl '/discover/movie' ($query + @{ page = $p }) })
    $rest = if ($urls.Count) { (Get-JsonMany $urls 12 'discover pages').Values } else { @() }
    return @($first) + @($rest)
}

$base = @{ include_adult = 'false'; include_video = 'false'; language = 'en-US'; sort_by = 'popularity.desc' }
for ($y = $thisYear + 2; $y -ge $FirstYear; $y--) {
    $before = $movies.Count
    if ($y -le $thisYear) {
        Add-Results (Get-DiscoverPages ($base + @{ primary_release_year = $y; 'vote_count.gte' = $MinVotes }) 500)
    }
    # Announced, just-released and future movies have few or no votes yet, but people
    # look them up and add them to their Schedule.
    if ($y -ge $thisYear - 1) {
        Add-Results (Get-DiscoverPages ($base + @{ primary_release_year = $y }) $UpcomingPages)
    }
    if ($y % 10 -eq 0 -or $y -ge $thisYear - 1) { Write-Host "year $y : +$($movies.Count - $before) (total $($movies.Count))" }
}
if ($movies.Count -lt 20000) { throw "Only $($movies.Count) movies came back from TMDB; not writing the catalog" }

# ── Write, most popular first ─────────────────────────────────────────────
function Clean([string]$s) { if ($s) { ($s -replace '[\t\r\n]+', ' ').Trim() } else { '' } }
$lines = $movies.Values | Sort-Object @{ e = { [double]$_.popularity }; Descending = $true }, id | ForEach-Object {
    $released = Clean $_.release_date
    $year = if ($released.Length -ge 4) { $released.Substring(0, 4) } else { '' }
    $popularity = ([double]$_.popularity).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    $score = ([double]$_.vote_average).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
    (@($_.id, (Clean $_.title), $year, $released, $popularity, $score, [int]$_.vote_count,
        (Clean $_.poster_path), (@($_.genre_ids) -join '|'), (Clean $_.original_language)) -join "`t")
}
[IO.File]::WriteAllLines((Join-Path $OutDir 'catalog.tsv'), [string[]]@($lines), $script:Utf8)
$size = (Get-Item (Join-Path $OutDir 'catalog.tsv')).Length / 1MB
Write-Host ("Wrote catalog.tsv: {0:N0} movies ({1:N1} MB)" -f $movies.Count, $size)
