import Foundation
import Observation
import MinuitCore

/// Films et séries du fournisseur : catalogues (chargés à la première visite, gardés en cache
/// disque), fiches détaillées (mémoire) et progression de lecture (préférences).
@MainActor
@Observable
final class VODService {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var movies = VODCatalog<Movie>.empty
    private(set) var series = VODCatalog<Series>.empty
    private(set) var movieState: State = .idle
    private(set) var seriesState: State = .idle
    private(set) var progress = WatchProgress()

    @ObservationIgnored private var client: XtreamClient?
    @ObservationIgnored private var cacheKey = ""
    @ObservationIgnored private let cache = FileCache.applicationCaches()
    @ObservationIgnored private var movieDetailsCache: [Int: MovieDetails] = [:]
    @ObservationIgnored private var seriesDetailsCache: [Int: SeriesDetails] = [:]
    @ObservationIgnored private let progressStore: StoredValue<WatchProgress>
    @ObservationIgnored private let log = DiagnosticsLog.shared

    /// Au-delà, le cache disque est affiché puis actualisé en arrière-plan.
    private static let cacheLifetime: TimeInterval = 6 * 3600

    private struct Snapshot<Item: Codable>: Codable {
        var categories: [ChannelCategory]
        var items: [Item]
    }

    init(storage: KeyValueStorage) {
        progressStore = StoredValue(key: "watch-progress", storage: storage, maxBytes: 256 * 1024)
        progress = progressStore.load() ?? WatchProgress()
    }

    var urls: XtreamURLBuilder? { client?.urls }

    func configure(client: XtreamClient, cacheKey: String) {
        if cacheKey != self.cacheKey { reset() }
        self.client = client
        self.cacheKey = cacheKey
    }

    /// Déconnexion ou changement de compte. La progression reste (propre à l'appareil).
    func reset() {
        client = nil
        movies = .empty
        series = .empty
        movieState = .idle
        seriesState = .idle
        movieDetailsCache = [:]
        seriesDetailsCache = [:]
    }

    // MARK: Catalogues

    func loadMovies(force: Bool = false) {
        guard let client else { return }
        load(label: "films", cacheName: "vod-movies-\(cacheKey)", force: force, state: \.movieState, catalog: \.movies) {
            let categories = try await client.movieCategories()
            do {
                return (categories, try await client.movies())
            } catch let error as XtreamError where error.allowsCategoryFallback && !categories.isEmpty {
                return (categories, try await client.movies(byCategory: categories))
            }
        }
    }

    func loadSeries(force: Bool = false) {
        guard let client else { return }
        load(label: "séries", cacheName: "vod-series-\(cacheKey)", force: force, state: \.seriesState, catalog: \.series) {
            let categories = try await client.seriesCategories()
            do {
                return (categories, try await client.series())
            } catch let error as XtreamError where error.allowsCategoryFallback && !categories.isEmpty {
                return (categories, try await client.series(byCategory: categories))
            }
        }
    }

    private func load<Item: VODItem & Codable>(
        label: String, cacheName: String, force: Bool,
        state: ReferenceWritableKeyPath<VODService, State>,
        catalog: ReferenceWritableKeyPath<VODService, VODCatalog<Item>>,
        download: @escaping @Sendable () async throws -> ([ChannelCategory], [Item])
    ) {
        guard self[keyPath: state] != .loading, force || self[keyPath: state] != .ready else { return }
        let cache = self.cache
        if self[keyPath: catalog].isEmpty { self[keyPath: state] = .loading }
        Task {
            // Cache disque d'abord : affichage immédiat, actualisation seulement s'il est ancien.
            if !force, self[keyPath: catalog].isEmpty {
                let cached = await Task.detached(priority: .userInitiated) { () -> (VODCatalog<Item>, Date)? in
                    guard let snapshot = cache.read(Snapshot<Item>.self, name: cacheName) else { return nil }
                    return (VODCatalog(categories: snapshot.value.categories, items: snapshot.value.items), snapshot.savedAt)
                }.value
                if let cached {
                    self[keyPath: catalog] = cached.0
                    self[keyPath: state] = .ready
                    if Date().timeIntervalSince(cached.1) < Self.cacheLifetime { return }
                }
            }
            do {
                let (categories, items) = try await download()
                let built = await Task.detached(priority: .userInitiated) { VODCatalog(categories: categories, items: items) }.value
                self[keyPath: catalog] = built
                self[keyPath: state] = .ready
                log.log(.info, "vod", "Catalogue \(label) : \(items.count) titres, \(categories.count) catégories")
                Task.detached(priority: .utility) { try? cache.write(Snapshot(categories: categories, items: items), name: cacheName) }
            } catch {
                let message = (error as? XtreamError)?.userMessage ?? "Erreur inattendue."
                log.log(.warning, "vod", "Catalogue \(label) : \(message)")
                self[keyPath: state] = self[keyPath: catalog].isEmpty ? .failed(message) : .ready
            }
        }
    }

    // MARK: Fiches

    func movieDetails(_ id: Int) async -> MovieDetails? {
        if let cached = movieDetailsCache[id] { return cached }
        guard let client else { return nil }
        do {
            let details = try await client.movieDetails(id)
            movieDetailsCache[id] = details
            return details
        } catch {
            log.log(.warning, "vod", "Fiche du film \(id) : \((error as? XtreamError)?.userMessage ?? "\(error)")")
            return nil
        }
    }

    func seriesDetails(_ id: Int) async -> SeriesDetails? {
        if let cached = seriesDetailsCache[id] { return cached }
        guard let client else { return nil }
        do {
            let details = try await client.seriesDetails(id)
            seriesDetailsCache[id] = details
            return details
        } catch {
            log.log(.warning, "vod", "Fiche de la série \(id) : \((error as? XtreamError)?.userMessage ?? "\(error)")")
            return nil
        }
    }

    // MARK: Progression

    func record(_ entry: WatchProgress.Entry) {
        progress.record(entry)
        saveProgress()
    }

    func queue(_ entry: WatchProgress.Entry) {
        progress.queue(entry)
        saveProgress()
    }

    func setFinished(_ entry: WatchProgress.Entry, _ finished: Bool) {
        progress.setFinished(entry, finished)
        saveProgress()
    }

    func removeProgress(_ key: String) {
        progress.remove(key)
        saveProgress()
    }

    private func saveProgress() {
        do { try progressStore.save(progress) }
        catch { log.log(.error, "vod", "Progression non enregistrée : \(error)") }
    }
}

/// Ce que lit le lecteur de films et séries.
struct VODPlayItem: Identifiable, Equatable {
    enum Content: Equatable {
        case movie(Movie)
        /// Les détails de la série permettent d'enchaîner l'épisode suivant.
        case episode(Series, Episode, SeriesDetails?)
    }

    var content: Content
    var startPosition: Double

    var id: String { progressKey }

    var progressKey: String {
        switch content {
        case .movie(let movie): return WatchProgress.key(movie: movie.id)
        case .episode(_, let episode, _): return WatchProgress.key(episode: episode.id)
        }
    }

    var title: String {
        switch content {
        case .movie(let movie): return VODText.title(movie.name)
        case .episode(let series, _, _): return VODText.title(series.name)
        }
    }

    var subtitle: String? {
        guard case .episode(_, let episode, _) = content else { return nil }
        return "\(episode.code) · \(episode.title)"
    }

    var imageURL: URL? {
        switch content {
        case .movie(let movie): return movie.posterURL
        case .episode(let series, let episode, _): return episode.imageURL ?? series.posterURL
        }
    }

    var containerExtension: String {
        switch content {
        case .movie(let movie): return movie.containerExtension
        case .episode(_, let episode, _): return episode.containerExtension
        }
    }

    func url(_ urls: XtreamURLBuilder) -> URL {
        switch content {
        case .movie(let movie): return urls.movieURL(id: movie.id, containerExtension: movie.containerExtension)
        case .episode(_, let episode, _): return urls.episodeURL(id: episode.id, containerExtension: episode.containerExtension)
        }
    }

    /// Épisode suivant, prêt à lire depuis le début.
    var next: VODPlayItem? {
        guard case .episode(let series, let episode, let details?) = content, let next = details.episode(after: episode) else { return nil }
        return VODPlayItem(content: .episode(series, next, details), startPosition: 0)
    }

    func progressEntry(position: Double, duration: Double, at date: Date = Date()) -> WatchProgress.Entry {
        switch content {
        case .movie(let movie):
            return WatchProgress.Entry(kind: .movie, itemID: movie.id, position: position, duration: duration, updatedAt: date,
                                       title: title, imageURL: movie.posterURL, containerExtension: movie.containerExtension)
        case .episode(let series, let episode, _):
            return WatchProgress.Entry(kind: .episode, itemID: series.id, episodeID: episode.id, position: position,
                                       duration: duration, updatedAt: date, title: title, subtitle: subtitle,
                                       imageURL: series.posterURL, containerExtension: episode.containerExtension)
        }
    }
}
