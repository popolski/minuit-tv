import SwiftUI
import MinuitCore

/// Onglets « Films » et « Séries » : barre latérale (À reprendre, Ajouts récents, Tout,
/// catégories du fournisseur) et grille d'affiches. Un clic ouvre la fiche.
struct VODScreen: View {
    enum Kind { case movies, series }

    enum Section: Hashable {
        case resume, recent, all
        case category(CategoryID)
    }

    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.backToTopBar) private var backToTopBar
    let kind: Kind
    @State private var section: Section?
    @FocusState private var sidebarFocus: Section?

    private var vod: VODService { app.vod }
    private var hideAdult: Bool { app.preferences.hideAdultContent }

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            sidebar
                .frame(width: 420)
                .focusSection()
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 2).padding(.vertical, 30)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal - 30)
        .onAppear {
            switch kind {
            case .movies: vod.loadMovies()
            case .series: vod.loadSeries()
            }
        }
    }

    // MARK: Données

    private var state: VODService.State { kind == .movies ? vod.movieState : vod.seriesState }

    private var categories: [ChannelCategory] {
        kind == .movies ? vod.movies.visibleCategories(hideAdult: hideAdult) : vod.series.visibleCategories(hideAdult: hideAdult)
    }

    private var resumeEntries: [WatchProgress.Entry] {
        vod.progress.continueWatching(limit: 40).filter { ($0.kind == .movie) == (kind == .movies) }
    }

    private var current: Section { section ?? (resumeEntries.isEmpty ? .recent : .resume) }

    // MARK: Barre latérale

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !resumeEntries.isEmpty { item(.resume, title: "À reprendre", icon: "play.circle") }
                item(.recent, title: "Ajouts récents", icon: "sparkles")
                item(.all, title: kind == .movies ? "Tous les films" : "Toutes les séries", icon: "square.grid.2x2")
                if !categories.isEmpty {
                    Text("Catégories").sectionHeader()
                        .padding(.leading, 22).padding(.top, 24).padding(.bottom, 6)
                }
                ForEach(categories) { category in
                    item(.category(category.id), title: category.name, icon: CategoryIcon.symbol(for: category.name))
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
        }
        .defaultFocus($sidebarFocus, current)
        .onExitCommand { backToTopBar() }
        .onChange(of: sidebarFocus) { _, value in
            if let value, value != current { section = value }
        }
    }

    private func item(_ value: Section, title: String, icon: String) -> some View {
        Button { section = value } label: {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).frame(width: 30).secondaryText()
                Text(title).font(Theme.Typeface.label(25)).lineLimit(1).primaryText()
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SidebarButtonStyle(isSelected: current == value))
        .focused($sidebarFocus, equals: value)
        .accessibilityIdentifier("vod-sidebar-\(title)")
    }

    // MARK: Contenu

    @ViewBuilder private var content: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 22) {
                ProgressView().tint(Theme.Palette.moon)
                Text(kind == .movies ? "Chargement des films…" : "Chargement des séries…")
                    .font(Theme.Typeface.label()).foregroundStyle(Theme.Palette.textSecondary)
                Text("La première fois, un grand catalogue peut prendre une minute.")
                    .font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity).padding(.top, 180)
        case .failed(let message):
            VStack(spacing: 22) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 60, weight: .light)).foregroundStyle(Theme.Palette.ember)
                Text(message).font(Theme.Typeface.title(32)).foregroundStyle(Theme.Palette.textPrimary).multilineTextAlignment(.center)
                Button("Réessayer") { kind == .movies ? vod.loadMovies(force: true) : vod.loadSeries(force: true) }
            }
            .frame(maxWidth: .infinity).padding(.top, 160)
        case .ready:
            grid
        }
    }

    private struct Card: Identifiable {
        let id: String
        let title: String
        let caption: String?
        let posterURL: URL?
        let progress: Double?
        let finished: Bool
        let open: AppRouter.VODDetail
    }

    private var cards: [Card] {
        switch current {
        case .resume:
            return resumeEntries.map { entry in
                Card(id: entry.key, title: entry.title, caption: entry.subtitle ?? VODFormat.remaining(position: entry.position, duration: entry.duration),
                     posterURL: entry.imageURL, progress: entry.queued ? nil : entry.fraction, finished: false, open: detail(for: entry))
            }
        case .recent, .all, .category:
            switch kind {
            case .movies: return movieList.map(movieCard)
            case .series: return seriesList.map(seriesCard)
            }
        }
    }

    private var movieList: [Movie] {
        switch current {
        case .recent: return vod.movies.recentlyAdded(limit: 120, hideAdult: hideAdult)
        case .category(let id): return vod.movies.items(in: id, hideAdult: hideAdult)
        default: return vod.movies.all(hideAdult: hideAdult)
        }
    }

    private var seriesList: [Series] {
        switch current {
        case .recent: return vod.series.recentlyAdded(limit: 120, hideAdult: hideAdult)
        case .category(let id): return vod.series.items(in: id, hideAdult: hideAdult)
        default: return vod.series.all(hideAdult: hideAdult)
        }
    }

    private func movieCard(_ movie: Movie) -> Card {
        let key = WatchProgress.key(movie: movie.id)
        let entry = vod.progress.entry(key)
        return Card(id: key, title: VODText.title(movie.name), caption: movie.year.map(String.init), posterURL: movie.posterURL,
                    progress: entry.flatMap { (e: WatchProgress.Entry) -> Double? in e.finished ? nil : e.fraction },
                    finished: entry?.finished ?? false, open: .movie(movie))
    }

    private func seriesCard(_ series: Series) -> Card {
        Card(id: "s\(series.id)", title: VODText.title(series.name), caption: series.year.map(String.init), posterURL: series.posterURL,
             progress: nil, finished: false, open: .series(series))
    }

    /// Fiche d'une entrée de progression, même si le catalogue n'est pas (encore) chargé.
    private func detail(for entry: WatchProgress.Entry) -> AppRouter.VODDetail {
        switch entry.kind {
        case .movie:
            return .movie(vod.movies.item(entry.itemID)
                ?? Movie(id: entry.itemID, name: entry.title, posterURL: entry.imageURL, containerExtension: entry.containerExtension))
        case .episode:
            return .series(vod.series.item(entry.itemID) ?? Series(id: entry.itemID, name: entry.title, posterURL: entry.imageURL))
        }
    }

    private var grid: some View {
        let cards = self.cards
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(sectionTitle).font(Theme.Typeface.label(26)).foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text("\(cards.count) titre\(cards.count > 1 ? "s" : "")").font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 12)
            if cards.isEmpty {
                Text("Rien ici pour l'instant").font(Theme.Typeface.title(32)).foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity).padding(.top, 140)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(PosterCard.size.width), spacing: 40), count: 5),
                              alignment: .leading, spacing: 44) {
                        ForEach(cards) { card in
                            Button { router.vodDetail = card.open } label: {
                                PosterCard(title: card.title, posterURL: card.posterURL, caption: card.caption,
                                           progress: card.progress, finished: card.finished, icon: kind == .movies ? "film" : "tv")
                            }
                            .buttonStyle(GlassRowButtonStyle(cornerRadius: 18, horizontalPadding: 0, verticalPadding: 0))
                            .accessibilityIdentifier("vod-\(card.id)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
        }
        .padding(.top, 20)
        .onExitCommand { sidebarFocus = current }
    }

    private var sectionTitle: String {
        switch current {
        case .resume: return "À reprendre"
        case .recent: return "Ajouts récents"
        case .all: return kind == .movies ? "Tous les films" : "Toutes les séries"
        case .category(let id): return categories.first { $0.id == id }?.name ?? "Catégorie"
        }
    }
}
