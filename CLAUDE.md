# CLAUDE.md

Guidance for Claude Code working in this repository. `README.md` lists every published file.

## What this is

The weekly data feed for the **Now Showing** Android movie app (the app lives in the private repo
`C:\Users\rderr\OneDrive\Documents\Claude\NowShowing`, next to this folder; github.com/rderr27-del/nowshowing; read
its CLAUDE.md for the app side). It's modeled on `rabbitears-data` (the owner's TV app feed, next to this folder):
same layout, same manifest-and-checksum update scheme.

This repo is **public** (github.com/rderr27-del/nowshowing-data) and published by GitHub Pages at
`https://rderr27-del.github.io/nowshowing-data/`. Never put anything private here: no keystore, no TMDB key (it's
the `TMDB_API_KEY` Actions secret), nothing about users.

## Sources

- **TMDB** (key required, free non-commercial terms): catalog, genres, trending, details, US release dates, posters.
  The app is free with no ads; TMDB's terms need a commercial license otherwise. The owner may replace TMDB later.
- **JustWatch via TMDB**: US watch providers (stream / free / ads / rent / buy). Must be credited. No "watch now" links,
  by the owner's choice: the JustWatch `link` TMDB returns is deliberately not stored.
- **Wikidata** (CC0, no key): Oscar winners, via SPARQL in `build-awards.ps1`. Golden Globes are commented out in
  `config/awards.tsv` because Wikidata's Globe data covers only ~30 of ~80 years.
- **OMDb (future)**: the owner may add IMDb / Rotten Tomatoes / Metacritic scores later. The design leaves room:
  each movie file has a `ratings` object keyed by source (`tmdb` today), an `imdb` id to look OMDb up by, ranking
  goes through `Get-RankScore` in `build-discover.ps1`, and `manifest.json` lists `sources` for the app to credit.
  OMDb's free key allows 1,000 requests a day, too few for ~25,000 movies weekly; paid tiers start around $1/month.

## How it's built

`.github/workflows/weekly-data.yml`, Mondays 10:00 UTC on `windows-latest` with Windows PowerShell 5.1 (the owner's
PC has only 5.1, no pwsh or Python). Order: catalog → awards → discover pools → details → posters → feed. Each
script's header documents its inputs, outputs and rules. `tools/common.ps1` has the shared HTTP code: `Get-JsonMany`
fetches 12 at a time with retries on 429/5xx and throws on other errors (a bad key fails the run instead of
publishing empty data). Every script refuses to write output that looks broken (too few movies/winners), so the
previous week's site stays up.

## How the app uses it

- `manifest.json` at most once a day; files whose checksum changed are downloaded, verified, swapped in.
- **Don't rename or reshape published files or fields** without updating the app: phones on older versions keep
  reading them. Add fields; never remove or rename. `catalog.tsv` columns may only be appended.
- `movies/<id>.json` and `posters/<id>.jpg` aren't in the manifest. The app requests them per movie and falls back to
  catalog info / TMDB's image server on 404.
- The app bundles a copy of the feed for first launch (its `tools/fetch-feed.ps1`).

## Working here

- **Run `git pull --rebase` before pushing.** The workflow commits `last-run.json` and `history/awards.json` weekly.
- Pushing here publishes. Confirm with the owner first.
- The owner isn't a developer. Explain changes plainly and say what was and wasn't verified.
- The TMDB scripts can only be tried with a key. `build-awards.ps1` needs none:
  `powershell -ExecutionPolicy Bypass -File tools\build-awards.ps1 -OutDir $env:TEMP\ns-test`.
