<#
  Copies movie posters from TMDB's image server into the feed, so the app gets most
  posters from this site. Run after build-details.ps1.

      powershell -ExecutionPolicy Bypass -File tools\build-posters.ps1

  Writes (to public/ unless -OutDir says otherwise):
    posters/<id>.jpg     TMDB's w185 poster (185x278, ~15 KB) for the -PosterCount most
                         popular movies, every Discover pool movie and every award
                         winner. The app asks for one when you add a movie and falls
                         back to TMDB's image server (no key needed) for the rest.
    posters/index.tsv    id <TAB> TMDB poster path, so the next run downloads only
                         new or changed posters
    discover/<id>.jpg    small w92 thumbnails (92x138, ~4 KB) for what the Discover
                         screens show first: the top of each trending window, the
                         top 25 of the last -ThumbYears years, and those years' award
                         winners. Zipped into discover-posters.zip by build-feed.ps1
                         and bundled with the app, so Discover has pictures offline.

  Incremental: the weekly workflow keeps posters/ between runs in the Actions cache.
  A first run (or a lost cache) downloads everything, ~15-20 minutes.
  -Limit N downloads at most N posters (for trying it out).
#>
param(
    [int]$PosterCount = 15000,
    [int]$ThumbYears = 30,
    [int]$ShownPerList = 25,
    [int]$Limit = 0,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public')
)

. "$PSScriptRoot\common.ps1"

$catalog = Read-Catalog $OutDir
$movieDir = Join-Path $OutDir 'movies'
$pools = Read-JsonFile (Join-Path $OutDir 'discover-pools.json')
$awards = Read-JsonFile (Join-Path $OutDir 'awards.json')

# The newest poster path we know: the movie's details file, else the catalog.
function Get-PosterPath([int]$id) {
    $file = Join-Path $movieDir "$id.json"
    if (Test-Path $file) {
        $p = (Read-JsonFile $file).poster
        if ($p) { return $p }
    }
    if ($catalog.ContainsKey($id)) { return $catalog[$id].poster }
    return ''
}

# ── Which posters ─────────────────────────────────────────────────────────
$want = @{}
$catalog.Values | Sort-Object @{ e = 'popularity'; Descending = $true } | Select-Object -First $PosterCount |
    Where-Object { $_.poster } | ForEach-Object { $want[$_.id] = $_.poster }
$extra = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($p in $pools.trending.PSObject.Properties) { foreach ($id in $p.Value) { [void]$extra.Add([int]$id) } }
foreach ($p in $pools.years.PSObject.Properties) { foreach ($id in $p.Value) { [void]$extra.Add([int]$id) } }
foreach ($p in $awards.years.PSObject.Properties) { foreach ($w in $p.Value) { [void]$extra.Add([int]$w.movie) } }
foreach ($id in $extra) {
    $path = Get-PosterPath $id
    if ($path) { $want[$id] = $path }
}

$thumbs = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($p in $pools.trending.PSObject.Properties) { @($p.Value) | Select-Object -First $ShownPerList | ForEach-Object { [void]$thumbs.Add([int]$_) } }
$firstThumbYear = (Get-UtcToday).Year - $ThumbYears
foreach ($p in $pools.years.PSObject.Properties) {
    if ([int]$p.Name -ge $firstThumbYear) { @($p.Value) | Select-Object -First $ShownPerList | ForEach-Object { [void]$thumbs.Add([int]$_) } }
}
foreach ($p in $awards.years.PSObject.Properties) {
    if ([int]$p.Name -ge $firstThumbYear) { foreach ($w in $p.Value) { [void]$thumbs.Add([int]$w.movie) } }
}

# ── Full posters (incremental) ────────────────────────────────────────────
$posterDir = Join-Path $OutDir 'posters'
$indexPath = Join-Path $posterDir 'index.tsv'
New-Item -ItemType Directory -Force $posterDir | Out-Null
$have = @{}
if (Test-Path $indexPath) {
    foreach ($line in [IO.File]::ReadLines($indexPath)) {
        $f = $line.Split("`t")
        if ($f.Count -eq 2 -and (Test-Path (Join-Path $posterDir "$($f[0]).jpg"))) { $have[[int]$f[0]] = $f[1] }
    }
}
$removed = 0
foreach ($file in Get-ChildItem $posterDir -Filter *.jpg) {
    $id = [int]$file.BaseName
    if (-not $want.ContainsKey($id)) { Remove-Item $file.FullName; $have.Remove($id); $removed++ }
}
$todo = @($want.Keys | Where-Object { $have[$_] -ne $want[$_] } | Sort-Object)
if ($Limit -gt 0) { $todo = @($todo | Select-Object -First $Limit) }
Write-Host "posters: $($want.Count) covered, $($todo.Count) to download, $removed removed"
$downloads = @{}
foreach ($id in $todo) { $downloads[(Get-TmdbImageUrl $want[$id] 'w185')] = Join-Path $posterDir "$id.jpg" }
$failed = Save-FilesMany $downloads
foreach ($id in $todo) { if (Test-Path (Join-Path $posterDir "$id.jpg")) { $have[$id] = $want[$id] } }
# Saved last, so an interrupted run only loses the list, not the posters.
$lines = $have.Keys | Sort-Object | ForEach-Object { "$_`t$($have[$_])" }
[IO.File]::WriteAllLines($indexPath, [string[]]@($lines), $script:Utf8)

# ── Discover thumbnails ───────────────────────────────────────────────────
# Rebuilt every week from scratch: they're small and few (~1,500).
$thumbDir = Join-Path $OutDir 'discover'
if (Test-Path $thumbDir) { Remove-Item -Recurse -Force $thumbDir }
New-Item -ItemType Directory -Force $thumbDir | Out-Null
$thumbDownloads = @{}
foreach ($id in $thumbs) {
    $path = if ($want.ContainsKey($id)) { $want[$id] } else { Get-PosterPath $id }
    if ($path) { $thumbDownloads[(Get-TmdbImageUrl $path 'w92')] = Join-Path $thumbDir "$id.jpg" }
}
$thumbFailed = Save-FilesMany $thumbDownloads

$size = (Get-ChildItem $posterDir -Filter *.jpg | Measure-Object Length -Sum).Sum / 1MB
$thumbSize = (Get-ChildItem $thumbDir -Filter *.jpg | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Wrote posters: {0} files ({1:N0} MB, {2} failed); thumbnails: {3} ({4:N1} MB, {5} failed)" -f $have.Count, $size, $failed, $thumbDownloads.Count, $thumbSize, $thumbFailed)
