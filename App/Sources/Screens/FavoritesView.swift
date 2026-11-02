import SwiftUI
import MinuitCore

/// Favoris : grille, réorganisation par menu contextuel (appui long).
struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router

    private let columns = Array(repeating: GridItem(.fixed(360), spacing: 40), count: 4)

    var body: some View {
        let favorites = app.channels(in: .favorites)
        ScrollView {
            if favorites.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "star").font(.system(size: 72, weight: .light)).foregroundStyle(Theme.Palette.moon)
                    Text("Aucun favori pour l'instant").font(Theme.Typeface.title(40))
                    Text("Pendant la lecture, maintenez le bouton central pour ajouter la chaîne.")
                        .font(Theme.Typeface.body(26)).foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.top, 160)
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(favorites) { channel in
                        Button { router.watch(channel.id, context: .favorites, app: app) } label: {
                            ChannelCard(channel: channel)
                        }
                        .buttonStyle(MinuitCardButtonStyle())
                        .contextMenu {
                            Button("Déplacer vers le début") { app.moveFavorite(channel.id, by: -1) }
                            Button("Déplacer vers la fin") { app.moveFavorite(channel.id, by: 1) }
                            Button("Retirer des favoris", role: .destructive) { app.toggleFavorite(channel.id) }
                        }
                        .onAppear { app.epg.ensureFresh([channel.id]) }
                    }
                }
                .padding(.horizontal, Theme.Metrics.safeHorizontal)
                .padding(.vertical, 40)
            }
        }
    }
}
