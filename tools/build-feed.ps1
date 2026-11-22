<#
  Packages everything into the files the Now Showing app downloads. Run last.

      powershell -ExecutionPolicy Bypass -File tools\build-feed.ps1

  Writes (to public/ unless -OutDir says otherwise):
    discover.json          the Discover lists plus display info for every movie on them
                           (title, year, poster, score, genres, where to watch), the
                           genre names and streaming services, so the app can filter
                           by genre and service on the phone
    catalog.tsv.gz         the search catalog, gzipped
    discover-posters.zip   the Discover thumbnails
    manifest.json          what the app checks first: version (build time, UTC), the
                           data sources to credit, and each file's size and SHA-256
    index.html             a small landing page

  awards.json is published as build-awards.ps1 wrote it. movies/<id>.json and
  posters/<id>.jpg are fetched one at a time by the app and aren't in the manifest.
#>
param(
    [string]$Region = 'US',
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

. "$PSScriptRoot\common.ps1"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$catalog = Read-Catalog $OutDir
$pools = Read-JsonFile (Join-Path $OutDir 'discover-pools.json')
$awards = Read-JsonFile (Join-Path $OutDir 'awards.json')
$movieDir = Join-Path $OutDir 'movies'

# ── discover.json ─────────────────────────────────────────────────────────
$ids = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($p in $pools.trending.PSObject.Properties) { foreach ($id in $p.Value) { [void]$ids.Add([int]$id) } }
foreach ($p in $pools.years.PSObject.Properties) { foreach ($id in $p.Value) { [void]$ids.Add([int]$id) } }
foreach ($p in (@($awards.years, $awards.nominees) | Where-Object { $_ } | ForEach-Object { $_.PSObject.Properties })) { foreach ($w in $p.Value) { [void]$ids.Add([int]$w.movie) } }

$movies = [ordered]@{}
$noDetails = 0
foreach ($id in ($ids | Sort-Object)) {
    $file = Join-Path $movieDir "$id.json"
    if (Test-Path $file) {
        $d = Read-JsonFile $file
        $entry = [ordered]@{
            title = $d.title; year = $d.year; released = $d.released; poster = $d.poster
            score = $d.ratings.tmdb.score; votes = $d.ratings.tmdb.votes; genres = @($d.genres)
        }
        $w = $d.watch.$Region
        if ($w) { $entry.watch = [ordered]@{ $Region = $w } }
    } elseif ($catalog.ContainsKey($id)) {
        $c = $catalog[$id]
        $noDetails++
        $entry = [ordered]@{
            title = $c.title; year = $c.year; released = $c.released; poster = $c.poster
            score = $c.score; votes = $c.votes; genres = @($c.genres)
        }
    } else {
        continue   # neither details nor catalog (deleted from TMDB): the app skips unknown ids
    }
    $movies["$id"] = $entry
}

# Rebuilt item by item: Windows PowerShell 5.1 wraps an array read back from JSON in
# {"value": [...], "Count": n} when it's written out again.
$genres = New-Object System.Collections.Generic.List[object]
foreach ($g in (Read-JsonFile (Join-Path $OutDir 'genres.json'))) { $genres.Add([ordered]@{ id = [int]$g.id; name = $g.name }) }

$discover = [ordered]@{
    schema    = 1
    updated   = $pools.updated
    region    = $Region
    genres    = $genres.ToArray()
    providers = Read-JsonFile (Join-Path $OutDir 'providers.json')
    trending  = $pools.trending
    years     = $pools.years
    movies    = $movies
}
Write-JsonFile (Join-Path $OutDir 'discover.json') $discover 10
Write-Host "discover.json: $($movies.Count) movies ($noDetails without details)"

# ── catalog.tsv.gz ────────────────────────────────────────────────────────
$in = [IO.File]::OpenRead((Join-Path $OutDir 'catalog.tsv'))
$outStream = [IO.File]::Create((Join-Path $OutDir 'catalog.tsv.gz'))
$gzip = New-Object IO.Compression.GZipStream($outStream, [IO.Compression.CompressionLevel]::Optimal)
$in.CopyTo($gzip)
$gzip.Dispose(); $outStream.Dispose(); $in.Dispose()

# ── discover-posters.zip (flat: <id>.jpg) ─────────────────────────────────
$zip = Join-Path $OutDir 'discover-posters.zip'
if (Test-Path $zip) { Remove-Item $zip }
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $OutDir 'discover'), $zip, [IO.Compression.CompressionLevel]::NoCompression, $false)

# ── manifest.json ─────────────────────────────────────────────────────────
function Entry([string]$name) {
    $path = Join-Path $OutDir $name
    [ordered]@{
        path   = $name
        bytes  = (Get-Item $path).Length
        sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
# The version is the build's UTC date and time ("2026-11-23T0412Z"): it sorts as text,
# so a later build always counts as newer, even on the same day.
$manifest = [ordered]@{
    schema  = 1
    version = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HHmm'Z'")
    region  = $Region
    # Who to credit on the app's Info screen. A new data source (OMDb, say) is added here
    # and in the app's list of credits; the app credits the ones a feed lists.
    sources = @('tmdb', 'justwatch', 'wikipedia', 'wikidata')
    files   = [ordered]@{
        catalog  = Entry 'catalog.tsv.gz'
        discover = Entry 'discover.json'
        awards   = Entry 'awards.json'
        posters  = Entry 'discover-posters.zip'
    }
}
Write-JsonFile (Join-Path $OutDir 'manifest.json') $manifest

$index = @"
<!doctype html><meta charset="utf-8"><title>Now Showing data</title>
<p>Weekly movie data for the Now Showing app, version $($manifest.version).
See <a href="manifest.json">manifest.json</a>.</p>
<p>This product uses the TMDB API but is not endorsed or certified by
<a href="https://www.themoviedb.org/">TMDB</a>. Streaming availability by
<a href="https://www.justwatch.com/">JustWatch</a>. Award winners and nominees from
<a href="https://en.wikipedia.org/">Wikipedia</a> (CC BY-SA 4.0), matched to TMDB through
<a href="https://www.wikidata.org/">Wikidata</a> (CC0).</p>
"@
Write-Utf8 (Join-Path $OutDir 'index.html') $index

Write-Host "Feed $($manifest.version):"
$manifest.files.Values | ForEach-Object { Write-Host ("  {0}  {1:N0} KB" -f $_.path, ($_.bytes / 1KB)) }
