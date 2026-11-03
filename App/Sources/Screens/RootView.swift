import SwiftUI
import UIKit
import MinuitCore

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @FocusState private var navFocus: AppRouter.Tab?
    @State private var showCrashReport = CrashReporter.lastReport != nil && !DemoMode.isEnabled

    var body: some View {
        @Bindable var router = router
        GeometryReader { screen in
        ZStack {
            switch app.phase {
            case .launching:
                ProgressView().tint(Theme.Palette.moon)
            case .signedOut(let message):
                LoginView(message: message)
            case .loading(let step):
                LoadingView(step: step)
            case .ready, .degraded:
                VStack(spacing: 0) {
                    TopBar(navFocus: $navFocus)
                        .focusSection()
                        .zIndex(1)
                    DegradedNotice()
                        .padding(.horizontal, Theme.Metrics.safeHorizontal)
                    Group {
                        switch router.selectedTab {
                        case .search: SearchScreen()
                        case .live: LiveScreen()
                        case .guide: GuideScreen()
                        case .settings: SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .focusSection()
                    .environment(\.backToTopBar, { navFocus = router.selectedTab })
                }
                // Au lancement, le focus est sur la capsule de navigation (le menu).
                .defaultFocus($navFocus, router.selectedTab)
            }
        }
        // Taille imposée : aucun contenu (texte long, liste) ne peut agrandir la racine.
        .frame(width: screen.size.width, height: screen.size.height)
        }
        // Le fond est un arrière-plan : ses grands cercles flous ne doivent pas agrandir la
        // mise en page (sinon l'interface dépasse l'écran et la barre du haut disparaît).
        .background { AmbientBackdrop(color: router.ambient, image: router.ambientImage) }
        // Pas de couleur de texte globale : elle s'appliquerait aussi aux champs de saisie
        // focalisés (fond blanc système) et les rendrait illisibles. Le mode sombre suffit.
        .sheet(isPresented: $showCrashReport) {
            CrashReportSheet(report: CrashReporter.lastReport ?? "") { showCrashReport = false }
        }
        .fullScreenCover(isPresented: $router.isPlayerPresented) {
            PlayerScreen(app: app) { router.isPlayerPresented = false }
                .ignoresSafeArea()
        }
    }
}

/// Fond « verre de nuit » : dégradé bleu nuit et halo coloré flouté qui suit la chaîne focalisée.
struct AmbientBackdrop: View {
    var color: Color
    var image: UIImage? = nil

    var body: some View {
        ZStack {
            Theme.Palette.backdrop
            if let image {
                // Image très floutée : couleur et profondeur, sans détail lisible.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1400, height: 900)
                    .blur(radius: 110)
                    .opacity(0.5)
                    .offset(x: 420, y: -120)
                    .transition(.opacity)
                    .id(ObjectIdentifier(image))
            }
            Circle()
                .fill(color)
                .frame(width: 1300, height: 1300)
                .blur(radius: 280)
                .opacity(0.42)
                .offset(x: 520, y: -260)
            Circle()
                .fill(Theme.Palette.moon)
                .frame(width: 900, height: 900)
                .blur(radius: 300)
                .opacity(0.16)
                .offset(x: -640, y: 420)
            // Voile : garde le texte lisible quel que soit le halo.
            Theme.Palette.night.opacity(0.35)
        }
        .ignoresSafeArea()
        .animation(Theme.Motion.backdrop, value: color)
        .animation(Theme.Motion.backdrop, value: image.map(ObjectIdentifier.init))
        .allowsHitTesting(false)
    }
}

/// Barre du haut : salutation, capsule de navigation, date et état du compte.
private struct TopBar: View {
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    var navFocus: FocusState<AppRouter.Tab?>.Binding

    var body: some View {
        HStack(alignment: .center) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.Palette.nightRaised, Theme.Palette.surfaceFocused],
                                                 startPoint: .top, endPoint: .bottom))
                        MinuitMark(size: 44)
                    }
                    .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Greeting.text(for: context.date)),")
                            .font(Theme.Typeface.caption(22)).foregroundStyle(Theme.Palette.textSecondary)
                        Text("Minuit").font(Theme.Typeface.label(28)).foregroundStyle(Theme.Palette.textPrimary)
                    }
                }
                .frame(width: 520, alignment: .leading)
            }

            Spacer()
            NavCapsule(navFocus: navFocus)
            Spacer()

            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                        .font(Theme.Typeface.label(24)).foregroundStyle(Theme.Palette.textPrimary)
                    Text("\(accountLine) · \(buildLabel)").font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
                }
                .frame(width: 520, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }

    private var accountLine: String {
        guard let account = app.session?.account else { return "Compte non vérifié" }
        if let expiry = account.expiresAt {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
            if days <= 14 { return "Expire dans \(max(0, days)) j" }
        }
        let connections = account.maxConnections.map { " · \($0) connexion\($0 > 1 ? "s" : "")" } ?? ""
        return "Abonnement actif\(connections)"
    }
}

/// Numéro de build affiché discrètement (diagnostic : quelle version est installée).
let buildLabel: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "v\(version) · build \(build)"
}()

/// Rapport de plantage affiché automatiquement au lancement suivant.
private struct CrashReportSheet: View {
    let report: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Theme.Palette.ember)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Minuit s'est fermé de façon inattendue").font(Theme.Typeface.title(36)).foregroundStyle(Theme.Palette.textPrimary)
                    Text("Prenez une photo de cet écran et envoyez-la : elle indique où l'application s'est arrêtée. \(buildLabel)")
                        .font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            ScrollView {
                Text(report.prefix(2600))
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            Button { close() } label: {
                Text("Fermer").font(Theme.Typeface.label(26)).primaryText()
            }
            .buttonStyle(GlassRowButtonStyle(cornerRadius: 40, horizontalPadding: 40, verticalPadding: 14))
            .fixedSize()
        }
        .padding(60)
        .background(Theme.Palette.backdrop.ignoresSafeArea())
    }
}

/// Capsule de navigation flottante : Recherche · Direct · Guide · Réglages.
private struct NavCapsule: View {
    @Environment(AppRouter.self) private var router
    var navFocus: FocusState<AppRouter.Tab?>.Binding

    var body: some View {
        HStack(spacing: 6) {
            item(.search, icon: "magnifyingglass")
            item(.live, title: "Direct")
            item(.guide, title: "Guide")
            item(.settings, icon: "gearshape")
        }
        .padding(6)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func item(_ tab: AppRouter.Tab, title: String? = nil, icon: String? = nil) -> some View {
        Button { router.selectedTab = tab } label: {
            Group {
                if let title { Text(title).font(Theme.Typeface.label(24)) }
                if let icon { Image(systemName: icon).font(.system(size: 24, weight: .semibold)) }
            }
            .frame(minWidth: title == nil ? 44 : 110)
        }
        .buttonStyle(NavSegmentStyle(isSelected: router.selectedTab == tab))
        .accessibilityIdentifier("nav-\(String(describing: tab))")
        .focused(navFocus, equals: tab)
    }
}

private struct NavSegmentStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isSelected: isSelected)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .foregroundStyle(isFocused ? Theme.Palette.onFocus : (isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary))
                .background(
                    Capsule(style: .continuous)
                        .fill(isFocused ? Theme.Palette.focusFill : (isSelected ? Color.white.opacity(0.2) : Color.clear))
                )
                .scaleEffect(isFocused ? 1.06 : 1)
                .animation(Theme.Motion.quick, value: isFocused)
        }
    }
}

private struct LoadingView: View {
    let step: String

    var body: some View {
        VStack(spacing: 28) {
            MinuitMark(size: 110)
            Text("Minuit").font(Theme.Typeface.display(96)).foregroundStyle(Theme.Palette.textPrimary)
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
                Text("\(message) Données en cache affichées.").font(Theme.Typeface.caption()).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Button("Réessayer") { Task { await app.refresh(silently: false) } }
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(Capsule().fill(Theme.Palette.glass))
        }
    }
}
