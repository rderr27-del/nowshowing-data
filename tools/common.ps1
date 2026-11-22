<#
  Shared helpers for the Now Showing data scripts. Dot-source it:  . "$PSScriptRoot\common.ps1"

  Runs on Windows PowerShell 5.1 (the owner's PC and the windows-latest GitHub runner).
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$script:Utf8 = New-Object Text.UTF8Encoding $false
$script:UserAgent = 'nowshowing-data weekly build (github.com/rderr27-del/nowshowing-data)'

function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Write-JsonFile([string]$Path, $Value, [int]$Depth = 8) {
    Write-Utf8 $Path ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Read-JsonFile([string]$Path) {
    [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

# One HttpClient for the whole run (creating one per request exhausts sockets).
$script:Http = New-Object Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(60)
$script:Http.DefaultRequestHeaders.UserAgent.ParseAdd('nowshowing-data/1.0')

# ── TMDB ──────────────────────────────────────────────────────────────────
# The key comes from the TMDB_API_KEY environment variable (a GitHub Actions secret in
# the workflow). Either kind of TMDB credential works: the short "API Key" (sent as
# ?api_key=) or the long "API Read Access Token" (sent as a Bearer header).
$script:TmdbKey = $env:TMDB_API_KEY
if ($script:TmdbKey -and $script:TmdbKey.Length -gt 40) {
    $script:Http.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:TmdbKey)
}

function Get-TmdbUrl([string]$Path, [hashtable]$Query = @{}) {
    if (-not $script:TmdbKey) { throw 'TMDB_API_KEY is not set. Add it as a repository secret (see README).' }
    $q = @{} + $Query
    if ($script:TmdbKey.Length -le 40) { $q['api_key'] = $script:TmdbKey }
    $parts = $q.Keys | Sort-Object | ForEach-Object { "$_=$([Uri]::EscapeDataString([string]$q[$_]))" }
    "https://api.themoviedb.org/3$Path" + $(if ($parts) { '?' + ($parts -join '&') } else { '' })
}

<#
  Fetches many URLs, -Parallel at a time, and returns a hashtable url -> parsed JSON
  ($null for 404). TMDB answers about 40-50 requests a second; 429 ("slow down") is
  retried after a pause, other failures a few times, then reported and skipped.
#>
function Get-JsonMany([string[]]$Urls, [int]$Parallel = 12, [string]$Label = 'requests') {
    $results = @{}
    $done = 0
    $failed = 0
    for ($i = 0; $i -lt $Urls.Count; $i += $Parallel) {
        $batch = @($Urls[$i..([Math]::Min($i + $Parallel, $Urls.Count) - 1)])
        $pending = $batch
        for ($attempt = 1; $attempt -le 5 -and $pending.Count -gt 0; $attempt++) {
            $tasks = @{}
            foreach ($u in $pending) { $tasks[$u] = $script:Http.GetAsync($u) }
            try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values)) } catch { }
            $retry = @()
            $slowDown = $false
            foreach ($u in $pending) {
                $t = $tasks[$u]
                if ($t.IsFaulted -or $t.IsCanceled) { $retry += $u; continue }
                $resp = $t.Result
                $code = [int]$resp.StatusCode
                if ($code -eq 200) {
                    $text = $resp.Content.ReadAsStringAsync().Result
                    $results[$u] = $text | ConvertFrom-Json
                } elseif ($code -eq 404) {
                    $results[$u] = $null
                } elseif ($code -eq 429 -or $code -ge 500) {
                    $retry += $u
                    if ($code -eq 429) { $slowDown = $true }
                } else {
                    throw "HTTP $code for $($u -replace 'api_key=[^&]+', 'api_key=***')"
                }
                $resp.Dispose()
            }
            $pending = $retry
            if ($pending.Count -gt 0) { Start-Sleep -Seconds $(if ($slowDown) { 5 } else { 2 * $attempt }) }
        }
        foreach ($u in $pending) { $failed++; $results[$u] = $null }
        $done += $batch.Count
        if (($done % 2000) -lt $Parallel) { Write-Host "  $Label : $done / $($Urls.Count)" }
        # ~12 requests per ~0.3 s keeps well under TMDB's limit.
        Start-Sleep -Milliseconds 250
    }
    if ($failed -gt 0) { Write-Host "::warning::$failed $Label failed after retries" }
    return $results
}

function Get-Json([string]$Url) {
    $r = Get-JsonMany @($Url) 1
    return $r[$Url]
}

# ── Images ────────────────────────────────────────────────────────────────
# TMDB's image server needs no key. Sizes: w92, w154, w185, w342, w500, original.
function Get-TmdbImageUrl([string]$PosterPath, [string]$Size = 'w185') {
    "https://image.tmdb.org/t/p/$Size$PosterPath"
}

<# Downloads url -> path pairs, -Parallel at a time. Returns how many failed. #>
function Save-FilesMany([hashtable]$Downloads, [int]$Parallel = 16) {
    $failed = 0
    $keys = @($Downloads.Keys)
    for ($i = 0; $i -lt $keys.Count; $i += $Parallel) {
        $batch = @($keys[$i..([Math]::Min($i + $Parallel, $keys.Count) - 1)])
        $tasks = @{}
        foreach ($u in $batch) { $tasks[$u] = $script:Http.GetAsync($u) }
        try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values)) } catch { }
        foreach ($u in $batch) {
            $t = $tasks[$u]
            if ($t.IsFaulted -or $t.IsCanceled -or [int]$t.Result.StatusCode -ne 200) { $failed++; continue }
            $dest = $Downloads[$u]
            $bytes = $t.Result.Content.ReadAsByteArrayAsync().Result
            [IO.File]::WriteAllBytes("$dest.part", $bytes)
            Move-Item -Force "$dest.part" $dest
            $t.Result.Dispose()
        }
        if ((($i + $batch.Count) % 2000) -lt $Parallel) { Write-Host "  images: $($i + $batch.Count) / $($keys.Count)" }
    }
    return $failed
}

# ── Catalog ───────────────────────────────────────────────────────────────
# catalog.tsv columns, written by build-catalog.ps1 and read by the other scripts and
# the app (Catalog.kt). Add new columns only at the end: older app versions read by position.
$script:CatalogColumns = 'id', 'title', 'year', 'released', 'popularity', 'score', 'votes', 'poster', 'genres', 'language'

function Read-Catalog([string]$OutDir) {
    $movies = New-Object 'System.Collections.Generic.Dictionary[int,object]'
    foreach ($line in [IO.File]::ReadLines((Join-Path $OutDir 'catalog.tsv'), [Text.Encoding]::UTF8)) {
        $f = $line.Split("`t")
        if ($f.Count -lt 10) { continue }
        $movies[[int]$f[0]] = [pscustomobject]@{
            id = [int]$f[0]; title = $f[1]; year = $f[2]; released = $f[3]
            popularity = [double]$f[4]; score = [double]$f[5]; votes = [int]$f[6]
            poster = $f[7]; genres = @(if ($f[8]) { $f[8].Split('|') | ForEach-Object { [int]$_ } }); language = $f[9]
        }
    }
    return $movies
}

function Get-UtcToday { (Get-Date).ToUniversalTime().Date }
