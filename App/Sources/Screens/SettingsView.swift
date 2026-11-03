import SwiftUI
import MinuitCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.backToTopBar) private var backToTopBar

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 60) {
                // Identité, à gauche.
                VStack(spacing: 22) {
                    Spacer()
                    Image(systemName: "moon.stars.fill").font(.system(size: 92)).foregroundStyle(Theme.Palette.moon)
                    Text("Minuit").font(Theme.Typeface.display(110)).foregroundStyle(Theme.Palette.textPrimary)
                    Text("La télévision en direct, sans détour.")
                        .font(Theme.Typeface.caption(22)).foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, 22).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.Palette.glass))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textTertiary)
                    Spacer()
                }
                .frame(width: 700)

                // Réglages groupés, à droite.
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        group("Compte") {
                            link("Compte et serveur", detail: app.serverDisplayName, icon: "person.crop.circle") { AccountSettings() }
                        }
                        group("Préférences") {
                            link("Lecture", icon: "play.rectangle") { PlaybackSettings() }
                            link("Catégories", icon: "folder") { CategorySettings() }
                            link("Guide TV", icon: "calendar") { GuideSettings() }
                            link("Replay", icon: "clock.arrow.circlepath") { ReplaySettings() }
                            link("Réseau et sécurité", icon: "network") { NetworkSettings() }
                        }
                        group("Assistance") {
                            link("Diagnostics", icon: "stethoscope") { DiagnosticsView() }
                            link("À propos", icon: "info.circle") { AboutView() }
                        }
                    }
                    .padding(.vertical, 30)
                    .padding(.horizontal, 12)
                }
                .focusSection()
            }
            .padding(.horizontal, Theme.Metrics.safeHorizontal)
            .onExitCommand { backToTopBar() }
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Text(title).sectionHeader().padding(.leading, 22).padding(.top, 22).padding(.bottom, 4)
        content()
    }

    private func link<Destination: View>(_ title: String, detail: String? = nil, icon: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 34).secondaryText()
                Text(title).font(Theme.Typeface.label(26)).primaryText()
                Spacer()
                if let detail { Text(detail).font(Theme.Typeface.caption(21)).tertiaryText().lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 20, weight: .bold)).tertiaryText()
            }
        }
        .buttonStyle(GlassRowButtonStyle(horizontalPadding: 24, verticalPadding: 16))
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if let account = app.session?.account {
                LabeledContent("Serveur", value: app.serverDisplayName)
                LabeledContent("Connexion", value: app.isSecureConnection ? "Chiffrée (HTTPS)" : "Non chiffrée (HTTP)")
                LabeledContent("Statut", value: account.status == .active ? "Actif" : account.status.rawValue)
                LabeledContent("Expiration", value: account.expiresAt?.formatted(date: .long, time: .omitted) ?? "Illimitée")
                LabeledContent("Connexions", value: "\(account.activeConnections ?? 0) / \(account.maxConnections.map(String.init) ?? "?")")
                LabeledContent("Formats autorisés", value: account.allowedFormats.map(\.rawValue).sorted().joined(separator: ", "))
                if account.isTrial { LabeledContent("Type", value: "Essai") }
            }
            if let date = app.catalogUpdatedAt {
                LabeledContent("Catalogue", value: "\(app.library.channels.count) chaînes · \(date.formatted(date: .abbreviated, time: .shortened))")
            }
            Button("Actualiser le compte et les chaînes") { Task { await app.refresh(silently: false) } }
            Button("Se déconnecter", role: .destructive) { app.signOut() }
        }
        .navigationTitle("Compte")
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Toggle("Reprendre la dernière chaîne au lancement", isOn: binding(\.resumeLastChannelOnLaunch))
            Toggle("Bandeau d'information au zapping", isOn: binding(\.showInfoOnZap))
            Toggle("Inverser haut / bas pour zapper", isOn: binding(\.invertZapDirection))
            Toggle("Faire correspondre fréquence et plage dynamique", isOn: binding(\.matchContentFrameRate))
            Picker("Moteur vidéo", selection: binding(\.enginePreference)) {
                ForEach(EnginePreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("Automatique : AetherEngine en MPEG-TS, puis AVPlayer en HLS en cas d'échec. Moteurs présents dans cette version : "
                 + EngineFactory.availableKinds.map(\.displayName).sorted().joined(separator: ", ") + ".")
                .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .navigationTitle("Lecture")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { value in app.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

private struct CategorySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let order = app.preferences.categoryOrder
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let categories = app.library.categories.sorted { (rank[$0.id] ?? Int.max, $0.serverOrder) < (rank[$1.id] ?? Int.max, $1.serverOrder) }
        List {
            Toggle("Masquer les contenus pour adultes", isOn: Binding(get: { app.preferences.hideAdultContent },
                                                                       set: { app.setHideAdult($0) }))
            Section("Appui long sur une catégorie pour la déplacer") {
                ForEach(categories) { category in
                    let hidden = app.preferences.hiddenCategories.contains(category.id)
                    Button { app.setCategoryHidden(category.id, hidden: !hidden) } label: {
                        HStack {
                            Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(hidden ? Theme.Palette.textTertiary : Theme.Palette.moon)
                            Text(category.name).foregroundStyle(hidden ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                        }
                    }
                    .contextMenu {
                        Button("Monter") { app.moveCategory(category.id, by: -1) }
                        Button("Descendre") { app.moveCategory(category.id, by: 1) }
                        Button("Tout en haut") { app.moveCategory(category.id, by: -10_000) }
                    }
                }
            }
        }
        .navigationTitle("Catégories")
    }
}

private struct GuideSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Toggle("Utiliser le guide XMLTV complet", isOn: Binding(get: { app.settings.useXMLTV },
                                                                     set: { v in app.updateSettings { $0.useXMLTV = v } }))
            Picker("Jours à venir", selection: Binding(get: { app.settings.epgDaysAhead },
                                                         set: { v in app.updateSettings { $0.epgDaysAhead = v } })) {
                ForEach([1, 2, 3, 5, 7], id: \.self) { Text("\($0) j").tag($0) }
            }
            LabeledContent("Programmes en mémoire", value: "\(app.epg.index.programmeCount) sur \(app.epg.index.channelCount) chaînes")
            if let date = app.epg.lastFullRefresh {
                LabeledContent("Dernier import complet", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let summary = app.epg.lastImportSummary {
                Text(summary).font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
            }
            Button(app.epg.isImportingXMLTV ? "Import en cours…" : "Actualiser le guide maintenant") {
                app.epg.refreshFullIfNeeded(force: true)
            }
            .disabled(app.epg.isImportingXMLTV)
        }
        .navigationTitle("Guide TV")
    }
}

private struct ReplaySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Picker("Marge avant le début", selection: Binding(get: { Int(app.settings.catchup.paddingBefore / 60) },
                                                               set: { v in app.updateSettings { $0.catchup.paddingBefore = Double(v) * 60 } })) {
                ForEach([0, 1, 2, 5], id: \.self) { Text("\($0) min").tag($0) }
            }
            Picker("Marge après la fin", selection: Binding(get: { Int(app.settings.catchup.paddingAfter / 60) },
                                                             set: { v in app.updateSettings { $0.catchup.paddingAfter = Double(v) * 60 } })) {
                ForEach([0, 2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
            }
            LabeledContent("Format d'URL d'archive", value: app.settings.catchup.confirmedStyle?.rawValue ?? "Non encore déterminé")
            Button("Redétecter le format d'archive") { app.updateSettings { $0.catchup.confirmedStyle = nil } }
            Text("Le replay n'est proposé que si la chaîne l'annonce, et n'est lancé qu'après vérification réelle de l'archive auprès du serveur.")
                .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .navigationTitle("Replay")
    }
}

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Picker("Sécurité du transport", selection: Binding(get: { app.settings.transportSecurity },
                                                                 set: { v in app.updateSettings { $0.transportSecurity = v } })) {
                Text("Autoriser HTTP").tag(TransportSecurityPolicy.allowHTTP)
                Text("Préférer HTTPS").tag(TransportSecurityPolicy.preferHTTPS)
                Text("Exiger HTTPS").tag(TransportSecurityPolicy.requireHTTPS)
            }
            Picker("Identification du lecteur (User-Agent)", selection: Binding(get: { app.settings.userAgentPreset },
                                                                                 set: { v in app.updateSettings { $0.userAgentPreset = v } })) {
                ForEach(UserAgentPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Accepter les certificats non vérifiés du fournisseur", isOn: Binding(
                get: { app.settings.acceptInvalidStreamCertificates },
                set: { v in app.updateSettings { $0.acceptInvalidStreamCertificates = v } }))
            Text("Certains fournisseurs redirigent leurs flux vers une adresse HTTPS dont le certificat n'est pas reconnu par tvOS : sans ce réglage, ces chaînes ne se lancent pas. Contrepartie : l'identité du serveur n'est plus vérifiée pour ces connexions.")
                .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
            Text("En HTTP, identifiant et mot de passe circulent en clair dans les URL Xtream (limite du protocole). Ils ne sont jamais écrits dans les journaux de l'application.")
                .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .navigationTitle("Réseau et sécurité")
    }
}

private struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [DiagnosticsLog.Entry] = []

    var body: some View {
        let stats = app.playback.statistics
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Diagnostics").font(Theme.Typeface.title(44)).foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.leading, 22).padding(.bottom, 10)
                if let crash = CrashReporter.lastReport {
                    Text("Dernière fermeture inattendue").sectionHeader().padding(.leading, 22)
                    row(nil, String(crash.prefix(2000)), monospaced: true)
                }
                Text("Lecture").sectionHeader().padding(.leading, 22).padding(.top, 10)
                row("Moteur actif", app.playback.activeAttempt?.description ?? "—")
                row("Détail", app.playback.technicalSummary)
                if let failure = app.playback.failureDetail, !failure.isEmpty {
                    row("Dernier échec", failure, monospaced: true)
                }
                row("Démarrages", "\(stats.tunes)")
                row("Première image (médiane)", stats.medianFirstFrame.map { String(format: "%.2f s", $0) } ?? "—")
                row("Reconnexions / replis / échecs", "\(stats.recoveries) / \(stats.fallbacks) / \(stats.failures)")
                row("Version", buildLabel)

                Text("Stockage").sectionHeader().padding(.leading, 22).padding(.top, 10)
                Button { app.clearCaches() } label: {
                    Text("Vider les caches (catalogue, guide, logos)").font(Theme.Typeface.label(24)).primaryText()
                }
                .buttonStyle(GlassRowButtonStyle(horizontalPadding: 24, verticalPadding: 14))

                Text("Journal (secrets masqués, plus récent en premier)").sectionHeader().padding(.leading, 22).padding(.top, 10)
                if entries.isEmpty {
                    Text("Journal vide.").font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textTertiary).padding(.leading, 22)
                }
                ForEach(entries.reversed()) { entry in
                    row("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.level.rawValue) · \(entry.category)",
                        entry.message, monospaced: true)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 1500)
            .frame(maxWidth: .infinity)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { entries = DiagnosticsLog.shared.snapshot() }
    }

    /// Rangée focalisable (indispensable pour faire défiler l'écran à la télécommande).
    private func row(_ label: String?, _ value: String, monospaced: Bool = false) -> some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 4) {
                if let label {
                    Text(label).font(Theme.Typeface.caption(19)).tertiaryText()
                }
                Text(value)
                    .font(monospaced ? .system(size: 19, design: .monospaced) : Theme.Typeface.body(23))
                    .primaryText()
                    .lineLimit(12)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GlassRowButtonStyle(horizontalPadding: 24, verticalPadding: 12))
    }
}

private struct AboutView: View {
    var body: some View {
        List {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            Text("Minuit — lecteur de télévision en direct pour Xtream Codes. Aucun contenu n'est fourni par l'application.")
            Text("Composants : AetherEngine (LGPL-3.0 avec exception App Store) et FFmpeg (LGPL), liés dynamiquement. Sources : github.com/superuser404notfound/AetherEngine.")
                .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .navigationTitle("À propos")
    }
}
