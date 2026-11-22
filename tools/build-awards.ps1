<#
  Builds awards.json: the winners of the major award categories in config/awards.tsv
  (Oscars, Golden Globes...) for every year, from Wikidata (https://www.wikidata.org,
  CC0, no key needed). Each winning film is matched to its TMDB movie id through
  Wikidata's "TMDB movie ID" property (P4947), so the app can link it to the catalog.

      powershell -ExecutionPolicy Bypass -File tools\build-awards.ps1

  Writes (to public/ unless -OutDir says otherwise):
    awards.json   {updated, shows, categories, years: {"2025": [winner, ...]}}

  Years are ceremony years: the 97th Academy Awards were held in March 2025 (honoring
  2024 films), so they're listed under 2025, the way the ceremonies are usually named.
  A winner Wikidata hasn't linked to a TMDB movie is left out (rare, mostly very old films).

  Takes under a minute: one query to Wikidata's public query service.
#>
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public'),
    [string]$Config = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\awards.tsv')
)

. "$PSScriptRoot\common.ps1"

# ── Read the categories ───────────────────────────────────────────────────
$shows = New-Object System.Collections.Generic.List[object]
$categories = New-Object System.Collections.Generic.List[object]
$section = ''
foreach ($line in [IO.File]::ReadAllLines($Config, [Text.Encoding]::UTF8)) {
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    if ($line -match '^\[(\w+)\]$') { $section = $Matches[1]; continue }
    $f = $line.Split("`t")
    if ($section -eq 'shows' -and $f.Count -ge 3) {
        $shows.Add([ordered]@{ id = $f[0]; name = $f[1]; short = $f[2] })
    } elseif ($section -eq 'categories' -and $f.Count -ge 5) {
        $categories.Add([ordered]@{ id = $f[0]; show = $f[1]; name = $f[2]; item = $f[3]; people = ($f[4] -eq 'yes') })
    }
}
$byItem = @{}
foreach ($c in $categories) { $byItem[$c.item] = $c }
Write-Host "awards: $($categories.Count) categories in $($shows.Count) shows"

# ── Ask Wikidata ──────────────────────────────────────────────────────────
# Every "award received" statement for these awards. The winner is either the film
# itself (Best Picture) or a person, with the film in the "for work" qualifier
# (Best Actor). The ceremony qualifier gives the year; failing that, "point in time".
$values = ($categories | ForEach-Object { "wd:$($_.item)" }) -join ' '
$sparql = @"
SELECT ?award ?winner ?winnerLabel ?human ?winnerTmdb ?work ?workLabel ?workTmdb ?ceremonyLabel ?ceremonyTime ?time WHERE {
  VALUES ?award { $values }
  ?winner p:P166 ?st . ?st ps:P166 ?award .
  OPTIONAL { ?st pq:P585 ?time }
  OPTIONAL { ?st pq:P805 ?ceremony . OPTIONAL { ?ceremony wdt:P585 ?ceremonyTime } }
  OPTIONAL { ?st pq:P1686 ?work . OPTIONAL { ?work wdt:P4947 ?workTmdb } }
  OPTIONAL { ?winner wdt:P4947 ?winnerTmdb }
  BIND(EXISTS { ?winner wdt:P31 wd:Q5 } AS ?human)
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
}
"@

$form = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$form['query'] = $sparql
$rows = $null
for ($attempt = 1; $attempt -le 4; $attempt++) {
    $req = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, 'https://query.wikidata.org/sparql')
    $req.Headers.Accept.ParseAdd('application/sparql-results+json')
    $req.Headers.UserAgent.Clear()
    $req.Headers.UserAgent.ParseAdd('nowshowing-data/1.0')
    $req.Content = New-Object Net.Http.FormUrlEncodedContent($form)
    try {
        $resp = $script:Http.SendAsync($req).Result
        if ([int]$resp.StatusCode -eq 200) {
            $rows = ($resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).results.bindings
            break
        }
        Write-Host "Wikidata answered HTTP $([int]$resp.StatusCode); retrying"
    } catch {
        Write-Host "Wikidata request failed ($($_.Exception.Message)); retrying"
    }
    Start-Sleep -Seconds (15 * $attempt)
}
if ($null -eq $rows) { throw 'Wikidata query failed' }
Write-Host "wikidata: $($rows.Count) award statements"

function Val($row, [string]$name) { if ($row.$name) { $row.$name.value } else { $null } }
function QidOf([string]$uri) { if ($uri) { $uri.Substring($uri.LastIndexOf('/') + 1) } else { $null } }
# Labels fall back to the item id ("Q123") when Wikidata has no English name.
function LabelOf([string]$label) { if ($label -and $label -notmatch '^Q\d+$') { $label } else { $null } }

# ── Group into winners ────────────────────────────────────────────────────
# One winner = one category, one year, one film, plus the winning people for that film.
$parsed = foreach ($row in $rows) {
    $category = $byItem[(QidOf (Val $row 'award'))]
    if (-not $category) { continue }
    $human = (Val $row 'human') -eq 'true'
    $tmdb = Val $row 'workTmdb'
    $title = LabelOf (Val $row 'workLabel')
    if (-not $tmdb -and -not $human) {
        # The winner is the film itself.
        $tmdb = Val $row 'winnerTmdb'
        $title = LabelOf (Val $row 'winnerLabel')
    }
    if (-not $tmdb -or $tmdb -notmatch '^\d+$') { continue }
    [pscustomobject]@{ row = $row; category = $category; human = $human; tmdb = $tmdb; title = $title
        ceremonyDate = Val $row 'ceremonyTime'; date = Val $row 'time' }
}

# The ceremony's own date is reliable; a bare "point in time" sometimes holds the film's
# release year instead. So when any statement for a film in a category names its
# ceremony, statements for that film and category without one are not used for the year
# (Everything Everywhere All at Once won at the 2023 ceremony, not in 2022).
$hasCeremony = @{}
foreach ($p in $parsed) { if ($p.ceremonyDate) { $hasCeremony["$($p.category.id)|$($p.tmdb)"] = $true } }

$winners = @{}
foreach ($p in $parsed) {
    $row = $p.row; $category = $p.category; $human = $p.human; $tmdb = $p.tmdb; $title = $p.title
    $date = $p.ceremonyDate
    if (-not $date) {
        if ($hasCeremony["$($category.id)|$tmdb"]) { continue }
        $date = $p.date
    }
    if (-not $date -or $date.Length -lt 4) { continue }
    $year = $date.Substring(0, 4)

    $key = "$($category.id)|$year|$tmdb"
    if (-not $winners.ContainsKey($key)) {
        $winners[$key] = [pscustomobject]@{
            category = $category.id; year = $year; movie = [int]$tmdb; title = $title
            ceremony = LabelOf (Val $row 'ceremonyLabel'); people = New-Object System.Collections.Generic.List[string]
        }
    }
    $w = $winners[$key]
    if (-not $w.title -and $title) { $w.title = $title }
    if (-not $w.ceremony) { $w.ceremony = LabelOf (Val $row 'ceremonyLabel') }
    $person = LabelOf (Val $row 'winnerLabel')
    if ($human -and $category.people -and $person -and -not $w.people.Contains($person)) { $w.people.Add($person) }
}

# Some films carry a person's award on the film itself too (an actor's win recorded on
# the movie). That shows up as the same film, so it merges above; nothing else to do.

$order = @{}
for ($i = 0; $i -lt $categories.Count; $i++) { $order[$categories[$i].id] = $i }
$years = [ordered]@{}
foreach ($y in ($winners.Values | ForEach-Object { $_.year } | Sort-Object -Unique -Descending)) {
    $years[$y] = @($winners.Values | Where-Object { $_.year -eq $y } |
        Sort-Object { $order[$_.category] }, title |
        ForEach-Object {
            $o = [ordered]@{ category = $_.category; movie = $_.movie; title = $_.title }
            if ($_.ceremony) { $o.ceremony = $_.ceremony }
            if ($_.people.Count -gt 0) { $o.people = @($_.people | Sort-Object) }
            $o
        })
}

# Sanity check: an empty or tiny result means the query or Wikidata broke; keep last week's file.
$total = ($years.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
if ($total -lt 500) { throw "Only $total winners came back from Wikidata; not writing awards.json" }

$out = [ordered]@{
    updated    = (Get-UtcToday).ToString('yyyy-MM-dd')
    shows      = $shows.ToArray()
    categories = @($categories | ForEach-Object { [ordered]@{ id = $_.id; show = $_.show; name = $_.name } })
    years      = $years
}
Write-JsonFile (Join-Path $OutDir 'awards.json') $out
Write-Host ("Wrote awards.json: {0} winners over {1} years ({2}-{3})" -f $total, $years.Count, @($years.Keys)[-1], @($years.Keys)[0])
