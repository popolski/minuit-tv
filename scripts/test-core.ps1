# Windows (PowerShell + Docker Desktop) : tests du cœur métier, sans frais.
docker run --rm -v "${PWD}:/src" -w /src swift:6.1-noble sh -c "swift test --parallel && sh scripts/static-checks.sh"
