# Now Showing data

Weekly movie data for the **Now Showing** Android app, built from [TMDB](https://www.themoviedb.org/),
[Wikipedia](https://en.wikipedia.org/) and [Wikidata](https://www.wikidata.org/) and published at **https://rderr27-del.github.io/nowshowing-data/**.

| File | What it is |
|---|---|
| `manifest.json` | Version (build time), the data sources to credit, and each file's size and SHA-256. The app checks this first. |
| `catalog.tsv.gz` | Every movie on TMDB with 10+ votes (~107,000), plus announced and new ones, for search on the phone: id, title, year, release date, popularity, score, votes, poster, genres, language |
| `discover.json` | Discover lists: trending (week / month / 3 months / year) and top movies of each year, with display info and US streaming for every movie on them |
| `awards.json` | Oscar and Golden Globe winners (`years`) and other nominees (`nominees`) in the major categories, by ceremony year, plus every ceremony with its date (`ceremonies`). Categories in `config/awards.tsv` |
| `movies/<id>.json` | Full details for ~21,000 movies: overview, runtime, US rating, US release dates (theatrical / digital / physical), and where to watch in the US (stream / free / with ads / rent / buy). Fetched by the app one at a time. |

No posters: the app loads them straight from TMDB's image server (image.tmdb.org, no key needed) at the width
each screen needs, using the poster paths in these files. (Until Nov 2026 the feed hosted ~270 MB of small copies.)

## How it's built

`.github/workflows/weekly-data.yml` runs every Monday at 10:00 UTC (or on demand: Actions tab → *Weekly data* →
*Run workflow*). Each script's header explains it in detail:

1. `tools/build-catalog.ps1`: TMDB's discover search, one year at a time → `catalog.tsv`, `genres.json`
2. `tools/build-awards.ps1`: Oscar and Golden Globe winners and nominees from each ceremony's Wikipedia page,
   matched to TMDB through Wikidata → `awards.json`. Categories are listed in `config/awards.tsv`; add a line
   there to add one. If Wikipedia or Wikidata is down, last week's copy (`history/awards.json`) is published again.
3. `tools/build-discover.ps1`: ranks the Discover lists → `discover-pools.json`
4. `tools/build-details.ps1`: one TMDB request per movie → `movies/<id>.json`, `providers.json`
5. `tools/build-feed.ps1`: packages it all and writes `manifest.json`

## Status

Running since November 22, 2026. A full run takes about 30 minutes. Every run is listed in the repo's Actions tab:
a green check means the new data is live, a red X means the previous week's data stays up.

## Setup: the TMDB key

The workflow needs a TMDB API key, stored as a repository secret so it never appears in the code:

1. Sign in at themoviedb.org → Settings → API, and request a free (non-commercial) key.
2. In this repository on GitHub: Settings → Secrets and variables → Actions → New repository secret.
   Name it `TMDB_API_KEY` and paste either the "API Key" or the longer "API Read Access Token".

To run the scripts on a PC instead, set it first in PowerShell (`$env:TMDB_API_KEY = '...'`), then run
`powershell -ExecutionPolicy Bypass -File tools\<script>.ps1`. Output goes to `public/`.

The app checks `manifest.json` at most once a day and downloads only files whose checksum changed. Requests
carry nothing about the user.

## Credits and terms

This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming availability is provided by
JustWatch (through TMDB). Movie data and posters belong to TMDB and its contributors and are used under
[TMDB's API terms](https://www.themoviedb.org/api-terms-of-use) for a free, non-commercial app.
Award winners and nominees are from Wikipedia, available under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); films are matched to TMDB through Wikidata
([CC0](https://creativecommons.org/publicdomain/zero/1.0/)).
