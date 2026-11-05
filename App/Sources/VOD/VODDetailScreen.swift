import SwiftUI
import MinuitCore

/// Fiche plein écran d'un film ou d'une série, par-dessus les onglets.
/// Retour ferme la fiche ; le lecteur s'ouvre depuis la racine (aucune feuille à refermer).
struct VODDetailScreen: View {
    @Environment(AppRouter.self) private var router
    let detail: AppRouter.VODDetail

    var body: some View {
        Group {
            switch detail {
            case .movie(let movie): MovieDetailView(movie: movie)
            case .series(let series): SeriesDetailView(series: series)
            }
        }
        .onExitCommand { router.vodDetail = nil }
    }
}

/// Fond de fiche : image très large à droite, voiles pour la lisibilité.
private struct DetailBackdrop: View {
    let url: URL?

    var body: some View {
        ZStack {
            Theme.Palette.backdrop
            if let url {
                RemoteImage(url: url, maxPixel: 1920)
                    .opacity(0.55)
            }
            Theme.Palette.scrimLeading
            LinearGradient(colors: [.clear, Theme.Palette.night.opacity(0.9)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct DetailHeader: View {
    let title: String
    let meta: String
    let plot: String?
    let people: [(label: String, value: String?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(Theme.Typeface.display(60)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
            if !meta.isEmpty {
                Text(meta).font(Theme.Typeface.label(24)).foregroundStyle(Theme.Palette.textSecondary)
            }
            if let plot {
                Text(plot).font(Theme.Typeface.body(25)).foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                    .lineLimit(6).frame(maxWidth: 1000, alignment: .leading)
            }
            ForEach(people.indices, id: \.self) { index in
                if let value = people[index].value {
                    (Text(people[index].label + " ").foregroundStyle(Theme.Palette.textTertiary)
                     + Text(value).foregroundStyle(Theme.Palette.textSecondary))
                        .font(Theme.Typeface.caption(21)).lineLimit(1).frame(maxWidth: 1000, alignment: .leading)
                }
            }
        }
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Theme.Typeface.label(25)).primaryText()
        }
        .buttonStyle(GlassRowButtonStyle(cornerRadius: 40, horizontalPadding: 34, verticalPadding: 14))
        .fixedSize()
        .accessibilityIdentifier(identifier ?? title)
    }
}

// MARK: - Film

private struct MovieDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    let movie: Movie
    @State private var details: MovieDetails?
    @State private var loading = true

    var body: some View {
        let key = WatchProgress.key(movie: movie.id)
        let resume = app.vod.progress.resumePosition(key)
        let entry = app.vod.progress.entry(key)
        ZStack(alignment: .topLeading) {
            DetailBackdrop(url: details?.backdropURL ?? details?.posterURL ?? movie.posterURL)
            HStack(alignment: .top, spacing: 60) {
                RemoteImage(url: details?.posterURL ?? movie.posterURL, maxPixel: 700)
                    .frame(width: 340, height: 510)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
                VStack(alignment: .leading, spacing: 30) {
                    DetailHeader(title: VODText.title(movie.name),
                                 meta: VODFormat.meta(year: details?.year ?? movie.year, genre: details?.genre,
                                                      duration: details?.durationSeconds, rating: details?.rating ?? movie.rating),
                                 plot: details?.plot ?? (loading ? nil : "Pas de résumé fourni."),
                                 people: [("Réalisation", details?.director), ("Avec", details?.cast)])
                    if let entry, !entry.finished, resume != nil {
                        HStack(spacing: 14) {
                            ProgressLine(progress: entry.fraction, height: 5).frame(width: 300)
                            Text(VODFormat.remaining(position: entry.position, duration: entry.duration))
                                .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    HStack(spacing: 24) {
                        if let resume {
                            ActionButton(title: "Reprendre à \(VODFormat.clock(resume))", icon: "play.fill", identifier: "vod-play") { play(from: resume) }
                            ActionButton(title: "Depuis le début", icon: "backward.end.fill") { play(from: 0) }
                        } else {
                            ActionButton(title: "Lecture", icon: "play.fill", identifier: "vod-play") { play(from: 0) }
                        }
                        let finished = entry?.finished ?? false
                        ActionButton(title: finished ? "Marquer comme non vu" : "Marquer comme vu",
                                     icon: finished ? "eye.slash" : "checkmark") {
                            app.vod.setFinished(progressTemplate, !finished)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, Theme.Metrics.safeHorizontal + 20)
            .padding(.top, 110)
        }
        .task(id: movie.id) {
            loading = true
            details = await app.vod.movieDetails(movie.id)
            loading = false
        }
    }

    /// Extension confirmée par la fiche si elle diffère de la liste.
    private var playableMovie: Movie {
        var copy = movie
        if let ext = details?.containerExtension { copy.containerExtension = ext }
        return copy
    }

    private var progressTemplate: WatchProgress.Entry {
        VODPlayItem(content: .movie(playableMovie), startPosition: 0)
            .progressEntry(position: 0, duration: Double(details?.durationSeconds ?? 0))
    }

    private func play(from position: Double) {
        router.play(VODPlayItem(content: .movie(playableMovie), startPosition: position), app: app)
    }
}

// MARK: - Série

private struct SeriesDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    let series: Series
    @State private var details: SeriesDetails?
    @State private var loading = true
    @State private var season: Int?
    @FocusState private var focusedEpisode: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            DetailBackdrop(url: details?.backdropURL ?? series.backdropURL ?? series.posterURL)
            HStack(alignment: .top, spacing: 50) {
                VStack(alignment: .leading, spacing: 30) {
                    DetailHeader(title: VODText.title(series.name),
                                 meta: VODFormat.meta(year: series.year ?? VODText.year(in: details?.releaseDate), genre: details?.genre ?? series.genre,
                                                      duration: nil, rating: details?.rating ?? series.rating),
                                 plot: details?.plot ?? series.plot ?? (loading ? nil : "Pas de résumé fourni."),
                                 people: [("Avec", details?.cast ?? series.cast)])
                    if let details, let target = resumeTarget(details) {
                        ActionButton(title: target.label, icon: "play.fill", identifier: "vod-play") { play(target.episode, details: details) }
                            .focusSection()
                    }
                }
                .frame(width: 860, alignment: .leading)
                episodesPanel
                    .frame(maxWidth: .infinity)
                    .focusSection()
            }
            .padding(.horizontal, Theme.Metrics.safeHorizontal + 20)
            .padding(.top, 100)
        }
        .task(id: series.id) {
            loading = true
            details = await app.vod.seriesDetails(series.id)
            loading = false
            if season == nil, let details {
                let latest = app.vod.progress.latestEpisode(series: series.id)
                season = details.episodes.first { $0.id == latest?.episodeID }?.season ?? details.seasons.first?.number
            }
        }
    }

    @ViewBuilder private var episodesPanel: some View {
        if let details {
            let current = season ?? details.seasons.first?.number ?? 1
            VStack(alignment: .leading, spacing: 18) {
                if details.seasons.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(details.seasons) { item in
                                Button { season = item.number } label: {
                                    Text(item.name).font(Theme.Typeface.label(22)).lineLimit(1).primaryText()
                                }
                                .buttonStyle(GlassRowButtonStyle(isSelected: item.number == current, cornerRadius: 26,
                                                                 horizontalPadding: 22, verticalPadding: 10))
                                .fixedSize()
                            }
                        }
                        .padding(12)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(details.episodes(inSeason: current)) { episode in
                            episodeRow(episode, details: details)
                        }
                    }
                    .padding(12)
                }
            }
        } else if loading {
            ProgressView().tint(Theme.Palette.moon).frame(maxWidth: .infinity).padding(.top, 160)
        } else {
            VStack(spacing: 18) {
                Text("Épisodes indisponibles").font(Theme.Typeface.title(30)).foregroundStyle(Theme.Palette.textSecondary)
                Button("Réessayer") {
                    Task {
                        loading = true
                        details = await app.vod.seriesDetails(series.id)
                        loading = false
                    }
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 160)
        }
    }

    private func episodeRow(_ episode: Episode, details: SeriesDetails) -> some View {
        let entry = app.vod.progress.entry(WatchProgress.key(episode: episode.id))
        return Button { play(episode, details: details) } label: {
            HStack(spacing: 18) {
                Text("\(episode.number)").font(Theme.Typeface.time(24)).frame(width: 44).tertiaryText()
                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.title).font(Theme.Typeface.label(23)).lineLimit(1).primaryText()
                    if let plot = episode.plot {
                        Text(plot).font(Theme.Typeface.body(19)).lineLimit(2).secondaryText()
                    }
                    if let entry, !entry.finished, entry.position > 0 {
                        ProgressLine(progress: entry.fraction, height: 3).frame(width: 240)
                    }
                }
                Spacer(minLength: 0)
                if let label = VODText.durationLabel(episode.durationSeconds) {
                    Text(label).font(Theme.Typeface.caption(19)).tertiaryText()
                }
                if entry?.finished == true {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.Palette.moon)
                }
            }
        }
        .buttonStyle(GlassRowButtonStyle(horizontalPadding: 18, verticalPadding: 12))
        .focused($focusedEpisode, equals: episode.id)
        .accessibilityIdentifier("episode-\(episode.id)")
        .contextMenu {
            let template = VODPlayItem(content: .episode(series, episode, details), startPosition: 0)
                .progressEntry(position: 0, duration: Double(episode.durationSeconds ?? 0))
            if entry?.finished == true {
                Button("Marquer comme non vu") { app.vod.setFinished(template, false) }
            } else {
                Button("Marquer comme vu") { app.vod.setFinished(template, true) }
            }
        }
    }

    /// Bouton principal : reprise de l'épisode entamé, épisode suivant du dernier vu, ou premier épisode.
    private func resumeTarget(_ details: SeriesDetails) -> (episode: Episode, label: String)? {
        let progress = app.vod.progress
        if let latest = progress.latestEpisode(series: series.id),
           let episode = details.episodes.first(where: { $0.id == latest.episodeID }) {
            if latest.finished, let next = details.episode(after: episode) {
                return (next, "Lecture \(next.code)")
            }
            if !latest.finished {
                let resume = progress.resumePosition(latest.key)
                return (episode, resume.map { "Reprendre \(episode.code) à \(VODFormat.clock($0))" } ?? "Lecture \(episode.code)")
            }
        }
        return details.episodes.first.map { (episode: $0, label: "Lecture \($0.code)") }
    }

    private func play(_ episode: Episode, details: SeriesDetails) {
        let key = WatchProgress.key(episode: episode.id)
        router.play(VODPlayItem(content: .episode(series, episode, details), startPosition: app.vod.progress.resumePosition(key) ?? 0), app: app)
    }
}
