# Test fixtures

Captured 2026-10-21 with the MediaWiki and Wikidata APIs (User-Agent: NocturneServer-tests). Files under `wikidata/` and `wikipedia/` are verbatim responses, except:

- `wikipedia/stub-no-plot.json`: `nayakan.json` with the Plot section removed, to test the no-plot path.
- `omdb/*.json`: hand-written in OMDb's documented response shape (no API key in tests).
- `wikidata/search-imdb-tt0000000.json`: a real query for a garbage id. It is NOT empty: Wikidata returns a 2026 Sri Lankan film that carries `tt0000000` as a placeholder, which is why the resolver cross-checks every hit's claims and year.
