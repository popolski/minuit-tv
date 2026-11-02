import SwiftUI
import MinuitCore

/// Accueil : reprise immédiate, favoris et récentes en rangées, accès au guide.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                DegradedNotice()
                hero
                if !favorites.isEmpty {
                    ChannelRow(title: "Favoris", channels: favorites, context: .favorites)
                }
                if !recents.isEmpty {
                    ChannelRow(title: "Regardées récemment", channels: recents, context: .recents)
                }
                if favorites.isEmpty && recents.isEmpty {
                    ChannelRow(title: "Pour commencer", channels: Array(app.channels(in: .all).prefix(20)), context: .all)
                }
            }
            .padding(.horizontal, Theme.Metrics.safeHorizontal)
            .padding(.vertical, Theme.Metrics.safeVertical)
        }
    }

    private var favorites: [Channel] { app.channels(in: .favorites) }
    private var recents: [Channel] { app.channels(in: .recents) }

    @ViewBuilder private var hero: some View {
        if let id = app.preferences.lastChannel, let channel = app.library.channel(id) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let (current, next) = app.epg.nowNext(channel.id, at: context.date)
                Button {
                    router.watch(channel.id, context: app.preferences.lastCategory.map { .category($0) } ?? .all, app: app)
                } label: {
                    HStack(spacing: 40) {
                        ChannelLogoView(channel: channel, size: CGSize(width: 260, height: 156))
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                StatusBadge(kind: .live)
                                Text("Reprendre · \(channel.name)").font(Theme.Typeface.label(26)).foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Text(current?.title ?? channel.name).font(Theme.Typeface.display(56)).lineLimit(1)
                            if let current {
                                HStack(spacing: 14) {
                                    Text(current.start.clockText).font(Theme.Typeface.time())
                                    ProgressLine(progress: current.progress(at: context.date)).frame(width: 480)
                                    Text(current.end.clockText).font(Theme.Typeface.time())
                                }
                                .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            if let next {
                                Text("Ensuite à \(next.start.clockText) · \(next.title)")
                                    .font(Theme.Typeface.body(24)).foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MinuitCardButtonStyle(cornerRadius: 28))
                .onAppear { app.epg.ensureFresh([channel.id]) }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bonsoir.").font(Theme.Typeface.display(72))
                Text("Choisissez une chaîne ou ouvrez le guide.").font(Theme.Typeface.title(34)).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}

/// Rangée horizontale de chaînes avec programme en cours.
struct ChannelRow: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    let title: String
    let channels: [Channel]
    let context: ChannelListContext

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(Theme.Typeface.title(34))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) {
                    ForEach(channels) { channel in
                        Button { router.watch(channel.id, context: context, app: app) } label: {
                            ChannelCard(channel: channel)
                        }
                        .buttonStyle(MinuitCardButtonStyle())
                        .onAppear { app.epg.ensureFresh([channel.id]) }
                    }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
    }
}

struct ChannelCard: View {
    @Environment(AppModel.self) private var app
    let channel: Channel

    var body: some View {
        let (current, _) = app.epg.nowNext(channel.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ChannelLogoView(channel: channel, size: CGSize(width: 120, height: 72))
                Spacer()
                if app.isFavorite(channel.id) { Image(systemName: "star.fill").foregroundStyle(Theme.Palette.moon) }
            }
            Text(channel.name).font(Theme.Typeface.label(24)).lineLimit(1)
            Text(current?.title ?? " ").font(Theme.Typeface.title(24)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            ProgressLine(progress: current?.progress(at: Date()) ?? 0, height: 3)
                .opacity(current == nil ? 0 : 1)
        }
        .padding(24)
        .frame(width: 360, height: 230, alignment: .topLeading)
    }
}
