# Test fixtures

Captured 2026-10-21 with the MediaWiki and Wikidata APIs (User-Agent: NocturneServer-tests). Files under `wikidata/` and `wikipedia/` are verbatim responses, except:

- `wikipedia/stub-no-plot.json`: `nayakan.json` with the Plot section removed, to test the no-plot path.
- `omdb/*.json`: hand-written in OMDb's documented response shape (no API key in tests).
- `wikidata/search-imdb-tt0000000.json`: a real query for an id with no match.
