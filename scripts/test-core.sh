#!/bin/sh
# NAS / Linux : tests du cœur métier dans le conteneur Swift officiel.
cd "$(dirname "$0")/.." && docker run --rm -v "$PWD":/src -w /src swift:6.1-noble sh -c "swift test --parallel && sh scripts/static-checks.sh"
