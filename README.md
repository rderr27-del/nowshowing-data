# Now Showing data

Weekly movie data for the **Now Showing** Android app, built from [TMDB](https://www.themoviedb.org/) and
[Wikidata](https://www.wikidata.org/) and published at **https://rderr27-del.github.io/nowshowing-data/**.

| File | What it is |
|---|---|
| `manifest.json` | Version (build time), the data sources to credit, and each file's size and SHA-256. The app checks this first. |
| `catalog.tsv.gz` | Every movie on TMDB with 10+ votes (~107,000), plus announced and new ones, for search on the phone: id, title, year, release date, popularity, score, votes, poster, genres, language |
| `discover.json` | Discover lists: trending (week / month / 3 months / year) and top movies of each year, with display info and US streaming for every movie on them |
| `awards.json` | Oscar winners in the major categories, by ceremony year (853 winners, 1929 onward; categories in `config/awards.tsv`) |
| `discover-posters.zip` | Small posters for what Discover shows first |
| `movies/<id>.json` | Full details for ~21,000 movies: overview, runtime, US rating, US release dates (theatrical / digital / physical), and where to watch in the US (stream / free / with ads / rent / buy). Fetched by the app one at a time. |
| `posters/<id>.jpg` | Posters (185×278) of the ~15,000 most popular movies (~16,000 files, ~270 MB) plus every Discover and award movie. |

## How it's built

`.github/workflows/weekly-data.yml` runs every Monday at 10:00 UTC (or on demand: Actions tab → *Weekly data* →
*Run workflow*). Each script's header explains it in detail:

1. `tools/build-catalog.ps1`: TMDB's discover search, one year at a time → `catalog.tsv`, `genres.json`
2. `tools/build-awards.ps1`: Oscar winners from Wikidata → `awards.json`. Categories are listed in
   `config/awards.tsv`; add a line there to add one. If Wikidata is down, last week's copy
   (`history/awards.json`) is published again.
3. `tools/build-discover.ps1`: ranks the Discover lists → `discover-pools.json`
4. `tools/build-details.ps1`: one TMDB request per movie → `movies/<id>.json`, `providers.json`
5. `tools/build-posters.ps1`: new or changed posters (kept between runs in the Actions cache)
6. `tools/build-feed.ps1`: packages it all and writes `manifest.json`

`.github/workflows/cache-keepalive.yml` opens the poster cache every Thursday, so GitHub's 7-day cache expiry
can't delete it between weekly runs.

## Status

Running since November 22, 2026. A full run takes about 35 minutes. Every run is listed in the repo's Actions tab:
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
Awards data is from Wikidata, available under [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
