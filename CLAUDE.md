# CLAUDE.md

Guidance for Claude Code working in this repository. `README.md` lists every published file.

## What this is

The weekly data feed for the **Now Showing** Android movie app (the app lives in the private repo
`C:\Users\rderr\OneDrive\Documents\Claude\NowShowing`, next to this folder; github.com/rderr27-del/nowshowing; read
its CLAUDE.md for the app side and the product decisions). It's modeled on `rabbitears-data` (the owner's TV app
feed, next to this folder): same layout, same manifest-and-checksum update scheme.

This repo is **public** (github.com/rderr27-del/nowshowing-data) and published by GitHub Pages (source: GitHub
Actions) at `https://rderr27-del.github.io/nowshowing-data/`. Never put anything private here: no keystore, no TMDB
key (it's the `TMDB_API_KEY` Actions secret, set by the owner), nothing about users.

## Sources

- **TMDB** (key required, free non-commercial terms): catalog, genres, trending, details, US release dates and
  ratings, posters. The app is free with no ads; TMDB's terms need a commercial license otherwise. The owner may
  replace TMDB later. Either TMDB credential works in `TMDB_API_KEY`: the short API Key (sent as `api_key=`) or the
  long Read Access Token (sent as a Bearer header); `common.ps1` tells them apart by length.
- **JustWatch via TMDB**: US watch providers (stream / free / ads / rent / buy). Must be credited. No "watch now"
  links, by the owner's choice: the JustWatch `link` TMDB returns is deliberately not stored.
- **Wikipedia** (CC BY-SA 4.0, no key; credit it): Oscar and Golden Globe winners AND nominees, read from each
  ceremony's page ("97th Academy Awards", "82nd Golden Globe Awards" → redirect) by `build-awards.ps1`. Under each
  category heading, top-level bullets are winners and second-level bullets nominees; old pages vary (a bold line or
  ‡ marks the winner, or winners only), and the parser handles those. The ceremony year and date come from the
  infobox; a ceremony still to come is nominees only. Only categories in `config/awards.tsv` are kept (matched by
  the article the heading links to, redirects followed, or the heading text). Wikidata was the source until Nov
  2026 but had Golden Globes for only ~30 of ~80 years and no usable nominees.
  **Rate limits**: pages are fetched with `index.php?action=raw` (cached, one at a time). Wikipedia's API answers
  429 quickly for automated clients, so it is used only for links Wikidata can't place (redirects), 2 s apart,
  honoring Retry-After.
- **Wikidata** (CC0, no key): turns each nominated film's Wikipedia article into its TMDB id (P4947), through
  sitelink lookups (a few hundred titles per SPARQL query).
- **OMDb (future)**: the owner may add IMDb / Rotten Tomatoes / Metacritic scores. The design leaves room:
  each movie file has a `ratings` object keyed by source (`tmdb` today), an `imdb` id to look OMDb up by, ranking
  goes through `Get-RankScore` in `build-discover.ps1`, and `manifest.json` lists `sources` for the app to credit.
  OMDb's free key allows 1,000 requests a day, too few for ~21,000 movies weekly; paid tiers start around $1/month.

## How it's built

`.github/workflows/weekly-data.yml`, Mondays 10:00 UTC on `windows-latest` with Windows PowerShell 5.1 (the owner's
PC has only 5.1, no pwsh or Python). Order: catalog → awards → discover pools → details → feed. Each
script's header documents its inputs, outputs and rules. `tools/common.ps1` has the shared HTTP code: `Get-JsonMany`
fetches 12 at a time with retries on 429/5xx and throws on other errors (a bad key fails the run instead of
publishing empty data). Every script refuses to write output that looks broken (too few movies/winners), so the
previous week's site stays up. If Wikipedia or Wikidata fails, last week's `history/awards.json` is republished.

**Measured on the first runs (Nov 2026):** ~33–35 minutes total. Catalog 107,412 movies (10 MB, 5.5 MB gzipped);
21,371 movie files; 244 streaming services; (posters and the Discover thumbnail zip were dropped in Nov 2026); discover.json ~1.7 MB with 6,485 movies; awards (winners only, Wikidata) 853 Oscar winners, 1929–2026; see last-run.json for current counts.

**Top 25 by Year** ranks by a weighted score: TMDB score pulled toward the year's average, with the pull scaled to
the year (a quarter of the average votes of its 25 most-voted movies; recent years need 300+ votes, older 200+).
A fixed weighting let niche titles with a few hundred votes top recent years.

## Windows PowerShell 5.1 pitfalls (all of these bit us)

- **Arrays read back from JSON get wrapped** as `{"value": [...], "Count": n}` when written out again
  (`@(ConvertFrom-Json ...)` inside a hashtable). This broke the genre list and the app couldn't open Discover.
  Rebuild such lists item by item into a `List[object]` and use `.ToArray()` (see `build-feed.ps1`).
- `@($list)` of a `List[object]` inside an `[ordered]@{}` literal can throw "Argument types do not match"; use `.ToArray()`.
- **Script files without a BOM are read as ANSI**, so a non-ASCII character in code (an en dash in a regex, ‡) never
  matches. Keep code ASCII: build such characters with `[char]0x2013` (`build-awards.ps1` does this).
- `Get-Content` reads UTF-8 files as ANSI in 5.1; use `[IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)` (`Read-JsonFile`).
- Check any change to the published shape with the app's `BundledFeedTest` (run `tools/fetch-feed.ps1` there first).

## Running and watching it

- Start a run: `gh workflow run weekly-data.yml --repo rderr27-del/nowshowing-data`.
- Watch: `gh run watch <id> --repo rderr27-del/nowshowing-data --exit-status`; step status:
  `gh run view <id> --json jobs`; logs: `gh run view --job=<job id> --log`.
- **Deploy can fail on GitHub's side** ("Fetching artifact metadata failed ... re-run later"). The build is fine;
  rerun only the failed job: `gh run rerun <id> --failed`.
- Check the live site: `curl https://rderr27-del.github.io/nowshowing-data/manifest.json`.

## How the app uses it

- `manifest.json` at most once a day; files whose checksum changed are downloaded, verified, swapped in.
- **Don't rename or reshape published files or fields** without updating the app: phones on older versions keep
  reading them. Add fields; never remove or rename. `catalog.tsv` columns may only be appended.
- `movies/<id>.json` isn't in the manifest. The app requests it per movie and falls back to catalog info on 404.
- **No posters in the feed.** The app loads them from TMDB's image server at the width each screen needs (w154 in
  lists, w342/w500 on the movie page), saves w342 copies of your own movies as WebP, and caps its browse cache.
  Keep `poster` paths in the catalog, discover.json and movie files: that's all the app needs. Hosting larger
  posters here would have outgrown GitHub Pages' 1 GB limit.
- The app bundles a copy of the feed for first launch (its `tools/fetch-feed.ps1`).

## Working here

- **Run `git pull --rebase` before pushing.** The workflow commits `last-run.json` and `history/awards.json` each run.
  Commit first, then pull: `git pull --rebase` refuses to run with uncommitted changes.
- Pushing here publishes. Confirm new kinds of changes with the owner first.
- The owner isn't a developer. Explain changes plainly and say what was and wasn't verified.
- Claude must not handle the TMDB key; the owner sets it with
  `gh secret set TMDB_API_KEY --repo rderr27-del/nowshowing-data`. `gh secret list` confirms it exists.
- Local runs need the key in `$env:TMDB_API_KEY`. `build-awards.ps1` needs none:
  `powershell -ExecutionPolicy Bypass -File tools\build-awards.ps1 -OutDir $env:TEMP\ns-test`.
