<#
  Builds awards.json: the winners AND nominees of the major categories in config/awards.tsv
  (Oscars and Golden Globes), for every ceremony.

      powershell -ExecutionPolicy Bypass -File tools\build-awards.ps1

  Sources (no keys needed):
    Wikipedia  each ceremony's page ("97th Academy Awards", "82nd Golden Globes") lists every
               category's winner and nominees. Wikipedia has them for every year;
               Wikidata, used before, had Golden Globes for only about 30 of 80 years.
    Wikidata   turns each nominated film's Wikipedia article into its TMDB movie id
               (property P4947), so the app can link it to the catalog.

  Writes (to public/ unless -OutDir says otherwise):
    awards.json  {updated, shows, categories, ceremonies, years, nominees}
      years       ceremony year -> winners          [{category, movie, title, ceremony, people}]
      nominees    ceremony year -> other nominees   (same shape; added Nov 2026, so apps
                  that only know "years" still read winners correctly)
      ceremonies  [{show, name, year, date}]: every ceremony found, with its date, so the
                  app can say when an announced ceremony's winners will be known

  How a page is read: under each category heading, top-level bullets are winners and
  bullets one level deeper are the other nominees (the layout Wikipedia uses on these
  pages). Some old pages differ: a bold line or a ‡ marks the winner, or only winners are
  listed. A ceremony still to come has nominees only. Years are ceremony years: the
  97th Academy Awards were held in March 2025 (honoring 2024 films), so they're 2025.
  A nominee Wikidata hasn't linked to a TMDB movie is left out (rare, mostly very old films).

  Takes a few minutes: ~20 page downloads, then ~150 small lookups.
#>
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'public'),
    [string]$Config = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\awards.tsv')
)

. "$PSScriptRoot\common.ps1"

# ── Read the config ───────────────────────────────────────────────────────
$shows = New-Object System.Collections.Generic.List[object]
$categories = New-Object System.Collections.Generic.List[object]
$section = ''
foreach ($line in [IO.File]::ReadAllLines($Config, [Text.Encoding]::UTF8)) {
    if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
    if ($line -match '^\[(\w+)\]$') { $section = $Matches[1]; continue }
    $f = $line.Split("`t")
    if ($section -eq 'shows' -and $f.Count -ge 5) {
        $shows.Add([pscustomobject]@{ id = $f[0]; name = $f[1]; short = $f[2]; page = $f[3]; first = [int]$f[4] })
    } elseif ($section -eq 'categories' -and $f.Count -ge 5) {
        $categories.Add([pscustomobject]@{ id = $f[0]; show = $f[1]; name = $f[2]
            match = @($f[3].Split('|') | ForEach-Object { $_.Trim().ToLowerInvariant() }); people = ($f[4] -eq 'yes') })
    }
}
Write-Host "awards: $($categories.Count) categories in $($shows.Count) shows"

# ── Wikipedia / Wikidata helpers ──────────────────────────────────────────
# One request with retries. A form makes it a POST; without one it's a GET. Returns the
# response text, or $null for 404.
function Invoke-Text([string]$Url, [hashtable]$Form = $null, [string]$Accept = 'application/json') {
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    if ($Form) { foreach ($k in $Form.Keys) { $dict[$k] = [string]$Form[$k] } }
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        # Wikimedia asks automated clients to go one request at a time, gently; it answers
        # 429 with a Retry-After when a client goes faster.
        Start-Sleep -Milliseconds 700
        $req = New-Object Net.Http.HttpRequestMessage($(if ($Form) { [Net.Http.HttpMethod]::Post } else { [Net.Http.HttpMethod]::Get }), $Url)
        $req.Headers.Accept.ParseAdd($Accept)
        $req.Headers.UserAgent.Clear()
        $req.Headers.UserAgent.ParseAdd($script:UserAgent)
        if ($Form) { $req.Content = New-Object Net.Http.FormUrlEncodedContent($dict) }
        try {
            $resp = $script:Http.SendAsync($req).Result
            $code = [int]$resp.StatusCode
            if ($code -eq 200) { return $resp.Content.ReadAsStringAsync().Result }
            if ($code -eq 404) { return $null }
            $wait = 15 * $attempt
            if ($code -eq 429 -and $resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) {
                $wait = [Math]::Max($wait, [int]$resp.Headers.RetryAfter.Delta.Value.TotalSeconds + 2)
            }
            Write-Host "$Url answered HTTP $code; retrying in $wait s"
        } catch {
            $wait = 15 * $attempt
            Write-Host "$Url failed ($($_.Exception.Message)); retrying in $wait s"
        }
        Start-Sleep -Seconds $wait
    }
    throw "Request to $Url kept failing"
}

function Invoke-Post([string]$Url, [hashtable]$Form, [string]$Accept = 'application/json') {
    Invoke-Text $Url $Form $Accept | ConvertFrom-Json
}

$WikiApi = 'https://en.wikipedia.org/w/api.php'

# Wikipedia's query API, following "continue" until every page in the batch is answered.
function Get-WikiQuery([hashtable]$Form) {
    $pages = New-Object System.Collections.Generic.List[object]
    $normalized = @{}; $redirects = @{}
    $cont = @{}
    do {
        $f = @{ action = 'query'; format = 'json'; formatversion = '2'; redirects = '1' } + $Form + $cont
        Start-Sleep -Seconds 2   # the API is the rate-limited part; go slower than the cached pages
        $r = Invoke-Post $WikiApi $f
        foreach ($n in @($r.query.normalized)) { if ($n) { $normalized[$n.from] = $n.to } }
        foreach ($n in @($r.query.redirects)) { if ($n) { $redirects[$n.from] = $n.to } }
        foreach ($p in @($r.query.pages)) { if ($p) { $pages.Add($p) } }
        $cont = @{}
        if ($r.continue) { foreach ($p in $r.continue.PSObject.Properties) { $cont[$p.Name] = [string]$p.Value } }
    } while ($cont.Count -gt 0)
    [pscustomobject]@{ pages = $pages; normalized = $normalized; redirects = $redirects }
}

function Get-Ordinal([int]$n) {
    $suffix = if (($n % 100) -in 11, 12, 13) { 'th' } else { switch ($n % 10) { 1 { 'st' } 2 { 'nd' } 3 { 'rd' } default { 'th' } } }
    "$n$suffix"
}

# ── 1. Download every ceremony page ───────────────────────────────────────
$thisYear = (Get-UtcToday).Year
$wanted = New-Object System.Collections.Generic.List[object]
foreach ($s in $shows) {
    # One ceremony a year, plus one spare for the next ceremony once its page exists.
    for ($n = 1; $n -le ($thisYear - $s.first + 2); $n++) {
        $wanted.Add([pscustomobject]@{ show = $s.id; title = $s.page.Replace('{n}', (Get-Ordinal $n)) })
    }
}
$ceremonyPages = New-Object System.Collections.Generic.List[object]
# Plain page text (action=raw) is served from Wikipedia's cache: cheap for them, and not
# rate-limited like the API's content queries. "#REDIRECT [[...]]" is followed by hand.
foreach ($w in $wanted) {
    $title = $w.title
    $text = $null
    for ($hop = 0; $hop -lt 3; $hop++) {
        $text = Invoke-Text "https://en.wikipedia.org/w/index.php?action=raw&title=$([Uri]::EscapeDataString($title.Replace(' ', '_')))" -Accept 'text/plain'
        if ($text -and $text -match '(?i)^\s*#REDIRECT\s*\[\[([^\]|#]+)') { $title = $Matches[1].Trim(); continue }
        break
    }
    if ($text) { $ceremonyPages.Add([pscustomobject]@{ show = $w.show; title = $title; text = $text }) }
}
Write-Host "wikipedia: $($ceremonyPages.Count) ceremony pages"

# ── 2. Read each page's categories and bullets ────────────────────────────
function Remove-Templates([string]$s) {
    # Innermost first, so nested templates ({{efn|...{{cite}}...}}) go too. A few carry text.
    for ($guard = 0; $guard -lt 10 -and $s.Contains('{{'); $guard++) {
        $s = [regex]::Replace($s, '\{\{([^{}]*)\}\}', {
            param($m)
            $parts = $m.Groups[1].Value.Split('|')
            $name = $parts[0].Trim().ToLowerInvariant()
            if ($name -eq "'") { "'" }
            elseif ($name -in 'sortname', 'sort name' -and $parts.Count -ge 3) { "$($parts[1]) $($parts[2])" }
            elseif ($name -in 'nowrap', 'nobr', 'lang' -and $parts.Count -ge 2) { $parts[$parts.Count - 1] }
            else { '' }
        })
    }
    $s
}

function ConvertTo-PlainText([string]$s) {
    $s = Remove-Templates $s
    $s = [regex]::Replace($s, '\[\[([^\]|]*)\|([^\]]*)\]\]', '$2')
    $s = [regex]::Replace($s, '\[\[([^\]]*)\]\]', '$1')
    $s = $s.Replace('&nbsp;', ' ').Replace('&ndash;', [string][char]0x2013).Replace('&mdash;', [string][char]0x2014).Replace('&amp;', '&').Replace("'''", '').Replace("''", '').Replace([string][char]0x2021, '').Replace([string][char]0x2020, '')
    $s = [regex]::Replace($s, '<[^>]+>', '')
    [regex]::Replace($s, '\s+', ' ').Trim()
}

# Every [[link]] in a piece of wikitext: target (no #section) and shown text.
function Get-Links([string]$s) {
    foreach ($m in [regex]::Matches($s, '\[\[([^\]|]+)(?:\|([^\]]*))?\]\]')) {
        $target = $m.Groups[1].Value.Split('#')[0].Trim()
        if (-not $target -or $target -match '^(File|Image|Category|wikt|w):') { continue }
        $text = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $target }
        [pscustomobject]@{ target = $target; text = $text }
    }
}

function Get-CeremonyDate([string]$text) {
    $m = [regex]::Match($text, '(?im)^\s*\|\s*date\s*=\s*(.*)$')
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value
    $t = [regex]::Match($v, '(?i)\{\{\s*start date[^|}]*\|\s*(\d{4})\s*\|\s*(\d{1,2})\s*\|\s*(\d{1,2})')
    if ($t.Success) { return '{0}-{1:D2}-{2:D2}' -f [int]$t.Groups[1].Value, [int]$t.Groups[2].Value, [int]$t.Groups[3].Value }
    $plain = ConvertTo-PlainText $v
    $d = [datetime]::MinValue
    foreach ($fmt in 'MMMM d, yyyy', 'd MMMM yyyy', 'MMMM d yyyy') {
        if ([datetime]::TryParseExact($plain.Trim(' ,.'), $fmt, [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { return $d.ToString('yyyy-MM-dd') }
    }
    $y = [regex]::Match($plain, '\b(19|20)\d{2}\b')
    if ($y.Success) { return $y.Value }
    $null
}

# Headings for parts of a page that hold no category lists.
$SkipHeading = '(?i)presenter|performer|multiple|see also|reference|notes|external|ceremony information|background|box office|critical|in memoriam|controvers|broadcast|ratings|viewership|honorary|special award|television'

function Read-Ceremony($page) {
    $text = $page.text
    $text = [regex]::Replace($text, '(?s)<!--.*?-->', '')
    $text = [regex]::Replace($text, '(?is)<ref[^>/]*/>', '')
    $text = [regex]::Replace($text, '(?is)<ref[^>]*>.*?</ref>', '')

    $blocks = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $current = $null
    $skip = $false
    $newBlock = {
        param([string]$wikitext)
        $link = @(Get-Links $wikitext | Select-Object -First 1)
        [pscustomobject]@{
            target = if ($link) { $link[0].target } else { $null }
            label = ConvertTo-PlainText $wikitext
            items = New-Object System.Collections.Generic.List[object]
        }
    }
    foreach ($raw in $text -split "`n") {
        $line = $raw.Trim()
        if ($line -match '^(={2,6})\s*(.*?)\s*\1$') {
            $heading = $Matches[2]
            $queue.Clear(); $current = $null
            $skip = (ConvertTo-PlainText $heading) -match $SkipHeading
            # A heading that names a category ("===[[...Best Director|Best Director]]===").
            if (-not $skip -and ($heading.Contains('[[') -or (ConvertTo-PlainText $heading) -match '(?i)^best ')) {
                $queue.Enqueue((& $newBlock $heading))
            }
            continue
        }
        if ($skip) { continue }
        if ($line.StartsWith('*')) {
            $depth = ([regex]::Match($line, '^\*+')).Value.Length
            if (-not $current) { if ($queue.Count -gt 0) { $current = $queue.Dequeue(); $blocks.Add($current) } else { continue } }
            $current.items.Add([pscustomobject]@{ depth = $depth; raw = $line.Substring($depth).Trim() })
            continue
        }
        if ($line.StartsWith("'") -and $line.Contains('[[') -and ($current -or $queue.Count -gt 0)) {
            # A bold line naming the winner above the bullets (some 1950s Golden Globe pages).
            if (-not $current) { $current = $queue.Dequeue(); $blocks.Add($current) }
            $current.items.Add([pscustomobject]@{ depth = 0; raw = $line })
            continue
        }
        if ($line.StartsWith('|') -or $line.StartsWith('!') -or $line.StartsWith('{{') -or $line.StartsWith('{|')) {
            $current = $null
            foreach ($m in [regex]::Matches($line, '(?i)\{\{\s*Award category\s*\|[^|]*\|(.+?)\}\}')) {
                $queue.Enqueue((& $newBlock $m.Groups[1].Value))
            }
            if ($line.StartsWith('!')) {
                foreach ($cell in $line.Substring(1).Split(@('!!'), 'None')) {
                    if ($cell -match '(?i)colspan') { continue }
                    # "! style=... | [[...|Drama]]": the text after the attributes' "|".
                    $c = $cell
                    $bar = $c.IndexOf('|')
                    if ($bar -ge 0 -and $c.Substring(0, $bar) -notmatch '\[\[') { $c = $c.Substring($bar + 1) }
                    if ($c.Trim()) { $queue.Enqueue((& $newBlock $c)) }
                }
            }
            # A bold winner on the table cell's own line, bullets of nominees below it
            # (late-1990s Golden Globe pages): "| valign="top" |'''''[[Titanic]]'' '''".
            if ($line.StartsWith('|') -and -not $line.StartsWith('|-') -and -not $line.StartsWith('|}') -and $queue.Count -gt 0) {
                $cell = $line.Substring(1)
                $bar = $cell.IndexOf('|')
                if ($bar -ge 0 -and $cell.Substring(0, $bar) -notmatch '\[\[') { $cell = $cell.Substring($bar + 1) }
                $cell = $cell.Trim()
                if ($cell.StartsWith("'") -and $cell.Contains('[[') -and $cell -notmatch '(?i)\{\{\s*Award category') {
                    $current = $queue.Dequeue(); $blocks.Add($current)
                    $current.items.Add([pscustomobject]@{ depth = 0; raw = $cell })
                }
            }
        }
    }
    # Shown text -> link target for every link on the page: a film linked once is often
    # written later in plain italics (''Avatar''), and this finds its article.
    $linkByText = @{}
    foreach ($l in (Get-Links $text)) { $k = (ConvertTo-PlainText $l.text); if ($k -and -not $linkByText.ContainsKey($k)) { $linkByText[$k] = $l.target } }
    [pscustomobject]@{ show = $page.show; name = $page.title; date = Get-CeremonyDate $page.text; blocks = $blocks; linkByText = $linkByText }
}

$ceremonies = @($ceremonyPages | ForEach-Object { Read-Ceremony $_ } | Where-Object { $_.date })
Write-Host "parsed: $(($ceremonies | ForEach-Object { $_.blocks.Count } | Measure-Object -Sum).Sum) category lists"

# ── 3. Resolve links: Wikipedia article -> Wikidata item -> TMDB id ──────
$resolveCache = @{}   # link target as written -> @{ title; qid }
function Resolve-Titles([string[]]$Targets) {
    $todo = @($Targets | Where-Object { $_ -and -not $resolveCache.ContainsKey($_) } | Sort-Object -Unique)
    for ($i = 0; $i -lt $todo.Count; $i += 50) {
        $batch = @($todo[$i..([Math]::Min($i + 50, $todo.Count) - 1)])
        $r = Get-WikiQuery @{ prop = 'pageprops'; ppprop = 'wikibase_item'; titles = ($batch -join '|') }
        $qidByTitle = @{}
        foreach ($p in $r.pages) { if ($p.pageprops -and $p.pageprops.wikibase_item) { $qidByTitle[$p.title] = $p.pageprops.wikibase_item } }
        foreach ($t in $batch) {
            $final = $t
            if ($r.normalized[$final]) { $final = $r.normalized[$final] }
            if ($r.redirects[$final]) { $final = $r.redirects[$final] }
            $resolveCache[$t] = [pscustomobject]@{ title = $final; qid = $qidByTitle[$final] }
        }
    }
}

# Categories first: match each list's heading to a configured category of that show.
Resolve-Titles @($ceremonies | ForEach-Object { $_.blocks } | ForEach-Object { $_.target })
$byShow = @{}
foreach ($c in $categories) { if (-not $byShow[$c.show]) { $byShow[$c.show] = New-Object System.Collections.Generic.List[object] }; $byShow[$c.show].Add($c) }
$matched = New-Object System.Collections.Generic.List[object]
$unmatchedLabels = @{}
foreach ($cer in $ceremonies) {
    foreach ($b in $cer.blocks) {
        $keys = @()
        if ($b.target) { $keys += $resolveCache[$b.target].title.ToLowerInvariant() }
        if ($b.label) { $keys += $b.label.ToLowerInvariant() }
        $cat = $null
        foreach ($c in $byShow[$cer.show]) { foreach ($k in $keys) { if ($c.match -contains $k) { $cat = $c; break } }; if ($cat) { break } }
        if ($cat) { $matched.Add([pscustomobject]@{ ceremony = $cer; category = $cat; block = $b }) }
        else { $unmatchedLabels["$($cer.show): $($b.label)"] = 1 + [int]$unmatchedLabels["$($cer.show): $($b.label)"] }
    }
}
Write-Host "matched $($matched.Count) category lists"

# Then every link inside those lists, and the TMDB id of each linked article.
# Wikidata knows which item each Wikipedia article is about (its "sitelinks"), so one query
# answers a few hundred titles at once, TMDB id included. Only links it can't place (mostly
# redirects such as an old title) go to Wikipedia's API, which follows redirects but is
# rate-limited; of those, only italic links (film titles are written in italics) are asked.
function Format-Title([string]$t) {
    $t = [regex]::Replace($t.Replace('_', ' '), '\s+', ' ').Trim()
    if ($t) { $t.Substring(0, 1).ToUpperInvariant() + $t.Substring(1) } else { $t }
}
$tmdbByQid = @{}
function Find-Sitelinks([string[]]$Titles) {
    $found = @{}
    for ($i = 0; $i -lt $Titles.Count; $i += 250) {
        $batch = @($Titles[$i..([Math]::Min($i + 250, $Titles.Count) - 1)])
        $values = ($batch | ForEach-Object { '"' + $_.Replace('\', '\').Replace('"', '\"') + '"@en' }) -join ' '
        $sparql = "SELECT ?title ?item ?tmdb WHERE { VALUES ?title { $values } ?article schema:name ?title ; schema:isPartOf <https://en.wikipedia.org/> ; schema:about ?item . OPTIONAL { ?item wdt:P4947 ?tmdb } }"
        $r = Invoke-Post 'https://query.wikidata.org/sparql' @{ query = $sparql } 'application/sparql-results+json'
        foreach ($row in $r.results.bindings) {
            $q = $row.item.value.Substring($row.item.value.LastIndexOf('/') + 1)
            $found[$row.title.value] = $q
            if ($row.tmdb -and $row.tmdb.value -match '^\d+$' -and -not $tmdbByQid[$q]) { $tmdbByQid[$q] = [int]$row.tmdb.value }
        }
    }
    $found
}

$itemTexts = @($matched | ForEach-Object { $_.block.items } | ForEach-Object { $_.raw })
$targets = @($itemTexts | ForEach-Object { Get-Links $_ } | ForEach-Object { $_.target } | Sort-Object -Unique)
$byTitle = Find-Sitelinks @($targets | ForEach-Object { Format-Title $_ } | Sort-Object -Unique)
$leftover = New-Object System.Collections.Generic.List[string]
foreach ($t in $targets) {
    $q = $byTitle[(Format-Title $t)]
    if ($q) { $resolveCache[$t] = [pscustomobject]@{ title = (Format-Title $t); qid = $q } } else { $leftover.Add($t) }
}
$italic = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($s in $itemTexts) {
    foreach ($m in [regex]::Matches($s, "(?<!')(?:''|''''')\s*\[\[([^\]|#]+)")) { [void]$italic.Add($m.Groups[1].Value.Trim()) }
}
$ask = @($leftover | Where-Object { $italic.Contains($_) })
Write-Host "links: $($targets.Count), placed by Wikidata: $($targets.Count - $leftover.Count), asking Wikipedia about $($ask.Count) italic ones"
Resolve-Titles $ask
$more = @($ask | ForEach-Object { $resolveCache[$_] } | Where-Object { $_ -and $_.qid -and -not $tmdbByQid[$_.qid] } | ForEach-Object { $_.qid } | Sort-Object -Unique)
for ($i = 0; $i -lt $more.Count; $i += 400) {
    $batch = @($more[$i..([Math]::Min($i + 400, $more.Count) - 1)])
    $sparql = "SELECT ?item ?tmdb WHERE { VALUES ?item { $(($batch | ForEach-Object { "wd:$_" }) -join ' ') } ?item wdt:P4947 ?tmdb }"
    $r = Invoke-Post 'https://query.wikidata.org/sparql' @{ query = $sparql } 'application/sparql-results+json'
    foreach ($row in $r.results.bindings) {
        $q = $row.item.value.Substring($row.item.value.LastIndexOf('/') + 1)
        if ($row.tmdb.value -match '^\d+$' -and -not $tmdbByQid[$q]) { $tmdbByQid[$q] = [int]$row.tmdb.value }
    }
}
Write-Host "wikidata: $($tmdbByQid.Count) films with a TMDB id"

# ── 4. Turn bullets into nominees ─────────────────────────────────────────
# The people of a bullet, for categories that name them: the text on the other side of
# the dash from the film ("Adrien Brody – The Brutalist as László Tóth", or for old
# screenplay lists "The Godfather – Francis Ford Coppola and Mario Puzo").
function Get-People([string]$plain, [string]$filmText) {
    $s = $plain
    # Dashes built from char codes, not typed: Windows PowerShell 5.1 reads a script file without a
    # byte-order mark as ANSI, so a literal en dash here would never match.
    $dash = [regex]::Match($s, ('\s[' + [char]0x2013 + [char]0x2014 + '-]\s'))
    $filmAt = if ($filmText) { $s.IndexOf($filmText) } else { -1 }
    if ($dash.Success) {
        if ($filmAt -ge 0 -and $filmAt -lt $dash.Index) { $s = $s.Substring($dash.Index + $dash.Length) }
        else { $s = $s.Substring(0, $dash.Index) }
    } elseif ($s -match '(?i)\b(?:written|directed|composed) by (.*)$') {
        $s = $Matches[1]
    } else { return @() }
    # Cut the source material off ("... based on the novel by", "... from Becket by Jean Anouilh").
    $s = [regex]::Split($s, '(?i)\s+as\s+|\s+based on\s+|;\s*based on|,?\s+(?:adapted\s+)?from\s')[0]
    $s = [regex]::Replace($s, '\([^)]*\)', '')
    $names = foreach ($n in [regex]::Split($s, '(?i),\s*and\s+|,\s*|\s+and\s+|\s*&\s*|;\s*')) {
        # Credit wording before a name: "Screenplay by", "Original story by", "co-written by",
        # "in collaboration with".
        $n = [regex]::Replace($n.Trim(), '(?i)^(?:in collaboration with|(?:original\s+)?(?:screenplay|screen story|story|stories|written|co-written|teleplay|dialogue|adaptation)(?:\s+by)?)\s*:?\s*', '').Trim(' ', ',', ':')   # keep periods: "Robert Downey Jr."
        if ($n -and $n.Length -le 40 -and $n -notmatch '(?i)^(producers?|screenplay|story)$|\bby\b') { $n }
    }
    @($names | Select-Object -Unique)
}

$today = (Get-UtcToday).ToString('yyyy-MM-dd')
$entries = @{}   # category|year|movie -> entry
$dropped = 0
foreach ($m in $matched) {
    $cer = $m.ceremony; $cat = $m.category; $items = $m.block.items
    $year = $cer.date.Substring(0, 4)
    $upcoming = $cer.date.Length -ge 10 -and $cer.date -gt $today -or [int]$year -gt [int]$today.Substring(0, 4)
    $isWinner = {
        param($item)
        if ($upcoming) { return $false }
        if (@($items | Where-Object { $_.depth -ge 2 }).Count -gt 0) { return $item.depth -le 1 }
        if (@($items | Where-Object { $_.raw.Contains([string][char]0x2021) }).Count -gt 0) { return $item.raw.Contains([string][char]0x2021) }
        if (@($items | Where-Object { $_.raw.Contains("'''") }).Count -gt 0) { return $item.raw.Contains("'''") }
        return $true   # a winners-only list
    }
    foreach ($item in $items) {
        $film = $null
        foreach ($l in (Get-Links $item.raw)) {
            $res = $resolveCache[$l.target]
            if ($res -and $res.qid -and $tmdbByQid[$res.qid]) { $film = [pscustomobject]@{ id = $tmdbByQid[$res.qid]; text = (ConvertTo-PlainText $l.text) }; break }
        }
        if (-not $film) {
            foreach ($m in [regex]::Matches($item.raw, "(?<!')''([^'\[\]]+?)''")) {
                $target = $cer.linkByText[$m.Groups[1].Value.Trim()]
                $res = if ($target) { $resolveCache[$target] } else { $null }
                if ($res -and $res.qid -and $tmdbByQid[$res.qid]) { $film = [pscustomobject]@{ id = $tmdbByQid[$res.qid]; text = $m.Groups[1].Value.Trim() }; break }
            }
        }
        if (-not $film) { $dropped++; continue }
        $won = & $isWinner $item
        $key = "$($cat.id)|$year|$($film.id)"
        if (-not $entries.ContainsKey($key)) {
            $entries[$key] = [pscustomobject]@{ category = $cat.id; year = $year; movie = $film.id; title = $film.text
                ceremony = $cer.name; won = $false; people = New-Object System.Collections.Generic.List[string] }
        }
        $e = $entries[$key]
        if ($won) { $e.won = $true }
        if ($cat.people) {
            foreach ($p in (Get-People (ConvertTo-PlainText $item.raw) $film.text)) { if (-not $e.people.Contains($p)) { $e.people.Add($p) } }
        }
    }
}
Write-Host "nominees: $($entries.Count) ($dropped bullets without a TMDB-linked film left out)"

# ── 5. Write awards.json ──────────────────────────────────────────────────
$order = @{}
for ($i = 0; $i -lt $categories.Count; $i++) { $order[$categories[$i].id] = $i }
function ConvertTo-YearMap($list) {
    $map = [ordered]@{}
    foreach ($y in ($list | ForEach-Object { $_.year } | Sort-Object -Unique -Descending)) {
        $map[$y] = @($list | Where-Object { $_.year -eq $y } | Sort-Object { $order[$_.category] }, title | ForEach-Object {
            $o = [ordered]@{ category = $_.category; movie = $_.movie; title = $_.title; ceremony = $_.ceremony }
            if ($_.people.Count -gt 0) { $o.people = $_.people.ToArray() }
            $o
        })
    }
    $map
}
$winners = @($entries.Values | Where-Object { $_.won })
$others = @($entries.Values | Where-Object { -not $_.won })

# Sanity check: too few results means a page layout or a service broke; keep last week's file.
foreach ($s in $shows) {
    $n = @($winners | Where-Object { $order[$_.category] -ne $null -and $categories[$order[$_.category]].show -eq $s.id }).Count
    Write-Host "  $($s.name): $n winners"
    if ($n -lt 300) { throw "Only $n $($s.name) winners came back; not writing awards.json" }
}
$top = $unmatchedLabels.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15
Write-Host "Most common headings not collected (expected: categories not in the config):"
$top | ForEach-Object { Write-Host "  $($_.Value)x $($_.Key)" }

$out = [ordered]@{
    updated    = $today
    shows      = @($shows | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; short = $_.short } })
    categories = @($categories | ForEach-Object { [ordered]@{ id = $_.id; show = $_.show; name = $_.name } })
    ceremonies = @($ceremonies | Sort-Object date -Descending | ForEach-Object { [ordered]@{ show = $_.show; name = $_.name; year = $_.date.Substring(0, 4); date = $_.date } })
    years      = ConvertTo-YearMap $winners
    nominees   = ConvertTo-YearMap $others
}
Write-JsonFile (Join-Path $OutDir 'awards.json') $out
Write-Host ("Wrote awards.json: {0} winners and {1} other nominees, {2} ceremonies" -f $winners.Count, $others.Count, @($ceremonies).Count)
