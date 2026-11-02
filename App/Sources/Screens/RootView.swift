import SwiftUI
import MinuitCore

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        ZStack {
            Theme.Palette.backdrop.ignoresSafeArea()
            switch app.phase {
            case .launching:
                ProgressView().tint(Theme.Palette.moon)
            case .signedOut(let message):
                LoginView(message: message)
            case .loading(let step):
                LoadingView(step: step)
            case .ready, .degraded:
                TabView(selection: $router.selectedTab) {
                    HomeView().tabItem { Text("Accueil") }.tag(AppRouter.Tab.home)
                    GuideScreen().tabItem { Text("Guide TV") }.tag(AppRouter.Tab.guide)
                    ChannelsView().tabItem { Text("Chaînes") }.tag(AppRouter.Tab.channels)
                    FavoritesView().tabItem { Text("Favoris") }.tag(AppRouter.Tab.favorites)
                    SettingsView().tabItem { Text("Réglages") }.tag(AppRouter.Tab.settings)
                }
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .fullScreenCover(isPresented: $router.isPlayerPresented) {
            PlayerScreen(app: app) { router.isPlayerPresented = false }
                .ignoresSafeArea()
        }
    }
}

private struct LoadingView: View {
    let step: String

    var body: some View {
        VStack(spacing: 28) {
            Text("Minuit").font(Theme.Typeface.display(96))
            ProgressView().tint(Theme.Palette.moon)
            Text(step).font(Theme.Typeface.label()).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// Bandeau signalant un mode dégradé (serveur injoignable, cache affiché).
struct DegradedNotice: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if case .degraded(let message) = app.phase {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.ember)
                Text("\(message) Données en cache affichées.").font(Theme.Typeface.caption())
                Spacer()
                Button("Réessayer") { Task { await app.refresh(silently: false) } }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall).fill(Theme.Palette.surface))
        }
    }
}
