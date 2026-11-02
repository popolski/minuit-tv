# Tests du cœur métier sur le NAS Synology (DS224+ : x86_64) ou Docker Desktop (Windows).
# Aucun coût : tout s'exécute localement.
FROM swift:6.1-noble
WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY scripts ./scripts
COPY App/Sources ./App/Sources
RUN swift build --build-tests
CMD ["sh", "-c", "swift test --parallel && sh scripts/static-checks.sh"]
