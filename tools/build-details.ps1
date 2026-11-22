<#
  Fetches full details for the movies people are most likely to add: where to watch
  them in the US (stream / free / with ads / rent / buy), US release dates and rating
  (PG-13...), runtime, overview, genres and IMDb id. Run after build-catalog.ps1,
  build-awards.ps1 and build-discover.ps1:

      powershell -ExecutionPolicy Bypass -File tools\build-details.ps1

  Which movies (-DetailCount and friends): the most voted-on and the most popular
  movies in the catalog, every recent or upcoming one, every movie on a Discover
  list and every award winner (~25,000). The app shows a movie outside this set with
  catalog info only (title, year, score, poster).

  Writes (to public/ unless -OutDir says otherwise):
    movies/<id>.json   one file per movie, fetched by the app when you open or add it,
                       and again weekly for movies you've added (streaming changes).
                       Format: see "Movie file format" below and MovieDetails.kt in the app.
    providers.json     every streaming service seen: {id: {name, logo, priority}}

  Streaming availability comes from JustWatch through TMDB; the app must credit both.
  Takes ~20 minutes (one request per movie, ~25 a second).

  Movie file format (schema 1). Add fields freely; never rename or remove one, since
  older app versions read them. Keyed objects leave room for more sources and regions:
    {
      "schema": 1, "id": 603, "title": "The Matrix", "year": "1999",
      "released": "1999-03-31", "runtime": 136, "overview": "...",
      "poster": "/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg", "genres": [28, 878],
      "imdb": "tt0133093",
      "ratings": { "tmdb": { "score": 8.2, "votes": 26000 } },   <- OMDb can add "imdb", "rt", "metacritic"
      "certification": { "US": "R" },
      "releases": { "US": { "theatrical": "1999-03-31", "digital": "...", "physical": "...", "tv": "..." } },
      "watch": { "US": { "stream": [8], "free": [], "ads": [], "rent": [2, 10], "buy": [2, 10] } },
      "updated": "2026-11-23"
    }
#>
param(
    [int]$DetailCount = 20000,     # most voted-on
    [int]$PopularCount = 5000,     # most popular right now
    [int]$RecentDays = 180,        # released this many days ago or later (incl. upcoming)
    [int]$ChunkSize = 600,
    [string[]]$Regions = @('US'),
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

. "$PSScriptRoot\common.ps1"

$catalog = Read-Catalog $OutDir
$today = Get-UtcToday
$todayText = $today.ToString('yyyy-MM-dd')

# ── Which movies ──────────────────────────────────────────────────────────
$wanted = New-Object 'System.Collections.Generic.HashSet[int]'
$catalog.Values | Sort-Object @{ e = 'votes'; Descending = $true } | Select-Object -First $DetailCount | ForEach-Object { [void]$wanted.Add($_.id) }
$catalog.Values | Sort-Object @{ e = 'popularity'; Descending = $true } | Select-Object -First $PopularCount | ForEach-Object { [void]$wanted.Add($_.id) }
$recent = $today.AddDays(-$RecentDays).ToString('yyyy-MM-dd')
$catalog.Values | Where-Object { $_.released -ge $recent } | ForEach-Object { [void]$wanted.Add($_.id) }
$pools = Read-JsonFile (Join-Path $OutDir 'discover-pools.json')
foreach ($p in $pools.trending.PSObject.Properties) { foreach ($id in $p.Value) { [void]$wanted.Add([int]$id) } }
foreach ($p in $pools.years.PSObject.Properties) { foreach ($id in $p.Value) { [void]$wanted.Add([int]$id) } }
$awards = Read-JsonFile (Join-Path $OutDir 'awards.json')
foreach ($p in $awards.years.PSObject.Properties) { foreach ($w in $p.Value) { [void]$wanted.Add([int]$w.movie) } }
Write-Host "details: $($wanted.Count) movies"

# ── Fetch, a chunk at a time (all of it at once wouldn't fit in memory) ───
$movieDir = Join-Path $OutDir 'movies'
New-Item -ItemType Directory -Force $movieDir | Out-Null
$providers = @{}
$typeNames = [ordered]@{ flatrate = 'stream'; free = 'free'; ads = 'ads'; rent = 'rent'; buy = 'buy' }
# TMDB release types: 1 premiere, 2 limited theatrical, 3 theatrical, 4 digital, 5 physical, 6 TV.
$releaseNames = @{ 2 = 'limited'; 3 = 'theatrical'; 4 = 'digital'; 5 = 'physical'; 6 = 'tv' }

function Convert-Details($d) {
    $releases = [ordered]@{}; $certs = [ordered]@{}; $watch = [ordered]@{}
    foreach ($region in $Regions) {
        $r = $d.release_dates.results | Where-Object { $_.iso_3166_1 -eq $region } | Select-Object -First 1
        $dates = [ordered]@{}
        if ($r) {
            foreach ($rd in ($r.release_dates | Sort-Object release_date)) {
                $name = $releaseNames[[int]$rd.type]
                if ($name -and -not $dates.Contains($name) -and $rd.release_date) { $dates[$name] = $rd.release_date.Substring(0, 10) }
                if ($rd.certification -and -not $certs.Contains($region) -and @(2, 3) -contains [int]$rd.type) { $certs[$region] = $rd.certification }
            }
            # A limited run counts as the theatrical date when there's no wide release.
            if ($dates.Contains('limited')) {
                if (-not $dates.Contains('theatrical')) { $dates['theatrical'] = $dates['limited'] }
                $dates.Remove('limited')
            }
            if (-not $certs.Contains($region)) {
                $any = $r.release_dates | Where-Object { $_.certification } | Select-Object -First 1
                if ($any) { $certs[$region] = $any.certification }
            }
        }
        if ($dates.Count) { $releases[$region] = $dates }

        $wp = $d.'watch/providers'.results.$region
        $offers = [ordered]@{}
        foreach ($t in $typeNames.Keys) {
            $ids = @()
            foreach ($o in @($wp.$t | Where-Object { $_ } | Sort-Object display_priority)) {
                $ids += [int]$o.provider_id
                if (-not $providers.ContainsKey([int]$o.provider_id)) {
                    $providers[[int]$o.provider_id] = [ordered]@{ name = $o.provider_name; logo = $o.logo_path; priority = [int]$o.display_priority }
                }
            }
            $offers[$typeNames[$t]] = $ids
        }
        $watch[$region] = $offers
    }
    $released = if ($d.release_date) { $d.release_date } else { '' }
    return [ordered]@{
        schema = 1; id = [int]$d.id; title = $d.title
        year = if ($released.Length -ge 4) { $released.Substring(0, 4) } else { '' }
        released = $released
        runtime = if ($d.runtime) { [int]$d.runtime } else { $null }
        overview = if ($d.overview) { $d.overview } else { '' }
        poster = if ($d.poster_path) { $d.poster_path } else { '' }
        genres = @($d.genres | ForEach-Object { [int]$_.id })
        imdb = if ($d.imdb_id) { $d.imdb_id } else { '' }
        ratings = [ordered]@{ tmdb = [ordered]@{ score = [Math]::Round([double]$d.vote_average, 1); votes = [int]$d.vote_count } }
        certification = $certs
        releases = $releases
        watch = $watch
        updated = $todayText
    }
}

$ids = @($wanted | Sort-Object)
$written = 0; $missing = 0
for ($i = 0; $i -lt $ids.Count; $i += $ChunkSize) {
    $chunk = @($ids[$i..([Math]::Min($i + $ChunkSize, $ids.Count) - 1)])
    $urls = @{}
    foreach ($id in $chunk) {
        $urls[(Get-TmdbUrl "/movie/$id" @{ language = 'en-US'; append_to_response = 'release_dates,watch/providers' })] = $id
    }
    $results = Get-JsonMany @($urls.Keys) 12 'movie details'
    foreach ($u in $urls.Keys) {
        $d = $results[$u]
        if (-not $d -or $d.adult) { $missing++; continue }
        Write-JsonFile (Join-Path $movieDir "$($urls[$u]).json") (Convert-Details $d)
        $written++
    }
    Write-Host "  details: $([Math]::Min($i + $ChunkSize, $ids.Count)) / $($ids.Count)"
}
if ($written -lt $ids.Count * 0.9) { throw "Only $written of $($ids.Count) movie details could be fetched" }

# Movies no longer in the set: drop their files so the site doesn't grow forever.
$removed = 0
foreach ($file in Get-ChildItem $movieDir -Filter *.json) {
    if (-not $wanted.Contains([int]$file.BaseName)) { Remove-Item $file.FullName; $removed++ }
}

$registry = [ordered]@{}
foreach ($id in ($providers.Keys | Sort-Object { $providers[$_].priority }, { $_ })) { $registry["$id"] = $providers[$id] }
Write-JsonFile (Join-Path $OutDir 'providers.json') $registry
Write-Host "Wrote $written movie files ($missing not found, $removed removed), $($registry.Count) streaming services"
