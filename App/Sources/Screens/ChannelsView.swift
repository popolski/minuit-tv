import SwiftUI
import MinuitCore

/// Catalogue : catégories à gauche, chaînes à droite, recherche.
/// Les deux colonnes sont des sections de focus distinctes : ◀ ▶ passe de l'une à l'autre
/// sans sauts imprévisibles.
struct ChannelsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var selection: ChannelListContext = .all
    @State private var query = ""
    @State private var searching = false

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            categoryColumn
                .frame(width: 520)
                .focusSection()
            channelColumn
                .focusSection()
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal)
        .padding(.top, 20)
        .onAppear {
            if let last = app.preferences.lastCategory { selection = .category(last) }
        }
        .sheet(isPresented: $searching) { SearchSheet(query: $query) }
    }

    private var categoryColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Button { searching = true } label: {
                    Label("Rechercher", systemImage: "magnifyingglass").font(Theme.Typeface.label(26))
                }
                .buttonStyle(MinuitRowButtonStyle())
                .padding(.bottom, 12)
                categoryButton("Toutes les chaînes", context: .all, count: app.channels(in: .all).count)
                ForEach(app.library.visibleCategories(preferences: app.preferences)) { category in
                    categoryButton(category.name, context: .category(category.id),
                                   count: app.channels(in: .category(category.id)).count)
                }
            }
            .padding(.vertical, 20)
        }
    }

    private func categoryButton(_ title: String, context: ChannelListContext, count: Int) -> some View {
        Button {
            selection = context
            if case .category(let id) = context { app.setLastCategory(id) } else { app.setLastCategory(nil) }
        } label: {
            HStack {
                Text(title).font(Theme.Typeface.label(26)).lineLimit(1)
                Spacer()
                Text("\(count)").font(Theme.Typeface.time(22)).foregroundStyle(Theme.Palette.textTertiary)
            }
            .foregroundStyle(selection == context ? Theme.Palette.moon : Theme.Palette.textPrimary)
        }
        .buttonStyle(MinuitRowButtonStyle())
    }

    private var channelColumn: some View {
        let channels = app.channels(in: selection)
        return ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(channels) { channel in
                    Button { router.watch(channel.id, context: selection, app: app) } label: {
                        ChannelListRow(channel: channel)
                    }
                    .buttonStyle(MinuitRowButtonStyle())
                    .contextMenu {
                        Button(app.isFavorite(channel.id) ? "Retirer des favoris" : "Ajouter aux favoris") {
                            app.toggleFavorite(channel.id)
                        }
                    }
                    .onAppear { app.epg.ensureFresh([channel.id]) }
                }
            }
            .padding(.vertical, 20)
        }
    }
}

struct ChannelListRow: View {
    @Environment(AppModel.self) private var app
    let channel: Channel

    var body: some View {
        let (current, next) = app.epg.nowNext(channel.id)
        HStack(spacing: 24) {
            Text(channel.number.map(String.init) ?? "")
                .font(Theme.Typeface.time(22)).foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 60, alignment: .trailing)
            ChannelLogoView(channel: channel, size: CGSize(width: 110, height: 66))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(channel.name).font(Theme.Typeface.label(26)).lineLimit(1)
                    if app.isFavorite(channel.id) { Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(Theme.Palette.moon) }
                    if channel.hasAnnouncedArchive {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 18)).foregroundStyle(Theme.Palette.archive)
                    }
                }
                if let current {
                    HStack(spacing: 12) {
                        Text(current.title).font(Theme.Typeface.title(22)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                        ProgressLine(progress: current.progress(at: Date()), height: 3).frame(width: 140)
                    }
                }
            }
            Spacer(minLength: 0)
            if let next {
                Text("\(next.start.clockText) \(next.title)").font(Theme.Typeface.caption(20))
                    .foregroundStyle(Theme.Palette.textTertiary).lineLimit(1).frame(maxWidth: 420, alignment: .trailing)
            }
        }
    }
}

/// Recherche plein écran avec le clavier tvOS natif.
private struct SearchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Binding var query: String

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(app.library.search(query, preferences: app.preferences)) { channel in
                        Button {
                            dismiss()
                            router.watch(channel.id, context: .all, app: app)
                        } label: { ChannelListRow(channel: channel) }
                        .buttonStyle(MinuitRowButtonStyle())
                    }
                }
                .padding(.horizontal, Theme.Metrics.safeHorizontal)
            }
            .searchable(text: $query, prompt: "Nom ou numéro de chaîne")
        }
        .background(Theme.Palette.backdrop.ignoresSafeArea())
    }
}
