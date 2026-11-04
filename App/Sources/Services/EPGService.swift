import Foundation
import Observation
import MinuitCore

/// Guide des programmes : index en mémoire observé par l'interface, alimenté par
/// trois sources (XMLTV complet, `get_short_epg` à la demande, `get_simple_data_table`
/// pour le détail d'une chaîne), mis en cache et actualisé selon `EPGRefreshPolicy`.
@MainActor
@Observable
final class EPGService {
    private(set) var index = EPGIndex()
    /// Incrémenté à chaque modification : déclencheur de rafraîchissement pour UIKit.
    private(set) var revision = 0
    private(set) var lastFullRefresh: Date?
    private(set) var isImportingXMLTV = false
    private(set) var lastImportSummary: String?

    @ObservationIgnored private var client: XtreamClient?
    @ObservationIgnored private var serverTimeZone = TimeZone.current
    @ObservationIgnored private var channels: [Channel] = []
    @ObservationIgnored private var useXMLTV = true
    @ObservationIgnored private var daysAhead = 2
    @ObservationIgnored private var customURL: URL?
    @ObservationIgnored private let policy = EPGRefreshPolicy()
    @ObservationIgnored private let cache = FileCache.applicationCaches()
    @ObservationIgnored private var pending: [ChannelID] = []
    @ObservationIgnored private var inFlight = Set<ChannelID>()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let maxConcurrent = 4
    @ObservationIgnored private let log = DiagnosticsLog.shared

    private nonisolated static let cacheName = "epg-index-v1"
    private nonisolated static let metaName = "epg-meta-v1"

    func configure(client: XtreamClient, session: XtreamSession, channels: [Channel], settings: AppSettings) {
        self.client = client
        self.serverTimeZone = session.server.timeZone
        self.channels = channels
        self.useXMLTV = settings.useXMLTV
        self.daysAhead = settings.epgDaysAhead
        let custom = settings.customXMLTVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.customURL = custom.isEmpty ? nil : URL(string: custom).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        if index.channelCount == 0, let cached = cache.read(EPGIndex.self, name: Self.cacheName) {
            index = cached.value
            lastFullRefresh = cache.read(Date.self, name: Self.metaName)?.value
            pruneOld()
            revision += 1
        }
    }

    /// Réglages du guide modifiés : un changement de guide personnalisé relance l'import.
    func applySettings(_ settings: AppSettings) {
        let previous = customURL
        useXMLTV = settings.useXMLTV
        daysAhead = settings.epgDaysAhead
        let custom = settings.customXMLTVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        customURL = custom.isEmpty ? nil : URL(string: custom).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        if customURL != previous { refreshFullIfNeeded(force: true) }
    }

    func reset() {
        index = EPGIndex()
        revision += 1
        lastFullRefresh = nil
        pending.removeAll()
        cache.remove(name: Self.cacheName)
        cache.remove(name: Self.metaName)
    }

    // MARK: Lecture

    func nowNext(_ channel: ChannelID, at date: Date = Date()) -> (now: Programme?, next: Programme?) {
        index.nowNext(for: channel, at: date)
    }

    func programmes(_ channel: ChannelID, in interval: DateInterval) -> [Programme] {
        Array(index.programmes(for: channel, in: interval))
    }

    // MARK: Actualisation

    /// À appeler pour les chaînes visibles à l'écran : ne déclenche que le nécessaire.
    func ensureFresh(_ ids: [ChannelID]) {
        let now = Date()
        for id in ids where !inFlight.contains(id) && !pending.contains(id) {
            if policy.needsChannelRefresh(index: index, channel: id, now: now) { pending.append(id) }
        }
        pump()
    }

    /// Guide détaillé d'une chaîne (avec indicateurs d'archive), pour le panneau programmes.
    func loadDetailed(_ id: ChannelID) async {
        guard let client else { return }
        do {
            let programmes = try await client.fullEPG(channel: id, serverTimeZone: serverTimeZone)
            apply(programmes, for: id)
        } catch {
            log.log(.warning, "epg", "Guide détaillé indisponible pour \(id) : \(error.userMessage)")
        }
    }

    private func pump() {
        guard let client else { return }
        while inFlight.count < maxConcurrent, !pending.isEmpty {
            let id = pending.removeFirst()
            inFlight.insert(id)
            let tz = serverTimeZone
            Task { [weak self] in
                let result: [Programme]?
                do { result = try await client.shortEPG(channel: id, limit: 8, serverTimeZone: tz) }
                catch { result = nil }
                guard let self else { return }
                self.inFlight.remove(id)
                // Même vide, on note la tentative pour ne pas réessayer en boucle.
                self.apply(result ?? [], for: id)
                self.pump()
            }
        }
    }

    private func apply(_ programmes: [Programme], for id: ChannelID) {
        index.merge(programmes, for: id, at: Date())
        revision += 1
        scheduleSave()
    }

    /// Import XMLTV complet en arrière-plan (guide du fournisseur, puis guide personnalisé
    /// pour les chaînes qu'il ne couvre pas), si activé et si le cache a expiré.
    func refreshFullIfNeeded(force: Bool = false) {
        guard useXMLTV || customURL != nil, let client, !isImportingXMLTV else { return }
        guard force || policy.needsFullRefresh(lastFull: lastFullRefresh, now: Date()) else { return }
        isImportingXMLTV = true
        let channels = self.channels
        let window = DateInterval(start: Date().addingTimeInterval(-Double(maxArchiveDays()) * 86_400),
                                  end: Date().addingTimeInterval(Double(daysAhead) * 86_400))
        let log = self.log
        let useProvider = useXMLTV
        let customURL = self.customURL
        Task { [weak self] in
            // Téléchargement et analyse hors du fil principal ; application du résultat ensuite.
            let (finalSummary, finalMapped) = await Task.detached(priority: .utility) { () -> (String, [ChannelID: [Programme]]) in
            let started = Date()
            var summary = ""
            var mapped: [ChannelID: [Programme]] = [:]
            if useProvider { do {
                let data = try await client.downloadXMLTV()
                let options = XMLTVParser.Options(channelKeys: EPGImporter.channelKeys(for: channels), window: window)
                let document = try XMLTVParser.parse(data, options: options)
                let result = EPGImporter.map(document, to: channels)
                mapped = result.programmes
                summary = "XMLTV : \(document.programmes.count) programmes, \(result.programmes.count) chaînes liées "
                    + "(\(result.matchedByName) par nom), \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)), "
                    + String(format: "%.1f s", Date().timeIntervalSince(started))
                log.log(.info, "epg", summary)
            } catch let error as XtreamError {
                summary = "XMLTV indisponible : \(error.userMessage)"
                log.log(.warning, "epg", summary)
            } catch {
                summary = "XMLTV illisible"
                log.log(.warning, "epg", "XMLTV illisible : \(error)")
            } }
            if let customURL {
                let custom = await Self.importCustom(customURL, http: client.http, channels: channels, window: window,
                                                     alreadyCovered: Set(mapped.keys), log: log)
                mapped.merge(custom.programmes) { current, _ in current }
                summary += (summary.isEmpty ? "" : " · ") + custom.summary
            }
            return (summary, mapped)
            }.value
            guard let self else { return }
            do {
                let now = Date()
                for (id, programmes) in finalMapped { self.index.merge(programmes, for: id, at: now) }
                if !finalMapped.isEmpty {
                    self.lastFullRefresh = now
                    try? self.cache.write(now, name: Self.metaName)
                }
                self.isImportingXMLTV = false
                self.lastImportSummary = finalSummary
                self.revision += 1
                self.scheduleSave()
            }
        }
    }

    /// Guide personnalisé : téléchargé (gzip accepté), analysé, appliqué seulement aux chaînes
    /// que le guide du fournisseur n'a pas couvertes. L'adresse n'est jamais journalisée en entier.
    private nonisolated static func importCustom(_ url: URL, http: HTTPClient, channels: [Channel], window: DateInterval,
                                                 alreadyCovered: Set<ChannelID>, log: DiagnosticsLog) async -> (programmes: [ChannelID: [Programme]], summary: String) {
        let host = url.host ?? "?"
        do {
            let response = try await http.send(HTTPRequest(url: url, timeout: 120))
            guard (200..<300).contains(response.statusCode) else {
                log.log(.warning, "epg", "Guide personnalisé (\(host)) : HTTP \(response.statusCode)")
                return ([:], "Guide personnalisé : erreur \(response.statusCode)")
            }
            var data = response.body
            if GzipContainer.isGzip(data) {
                guard let range = GzipContainer.deflateRange(data),
                      let inflated = try? (data.subdata(in: range) as NSData).decompressed(using: .zlib) as Data else {
                    return ([:], "Guide personnalisé : archive gzip illisible")
                }
                data = inflated
            }
            let remaining = channels.filter { !alreadyCovered.contains($0.id) }
            let options = XMLTVParser.Options(channelKeys: EPGImporter.channelKeys(for: remaining), window: window)
            let document = try XMLTVParser.parse(data, options: options)
            let result = EPGImporter.map(document, to: remaining)
            let summary = "Guide personnalisé (\(host)) : \(result.programmes.count) chaînes complétées (\(result.matchedByName) par nom)"
            log.log(.info, "epg", summary)
            return (result.programmes, summary)
        } catch {
            log.log(.warning, "epg", "Guide personnalisé (\(host)) illisible : \(error)")
            return ([:], "Guide personnalisé indisponible")
        }
    }

    private func maxArchiveDays() -> Int {
        max(1, channels.compactMap { $0.archive?.days }.max() ?? 1)
    }

    private func pruneOld() {
        index.prune(before: Date().addingTimeInterval(-Double(maxArchiveDays()) * 86_400))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pruneOld()
            let snapshot = self.index
            let cache = self.cache
            await Task.detached(priority: .background) {
                try? cache.write(snapshot, name: Self.cacheName)
            }.value
        }
    }
}
