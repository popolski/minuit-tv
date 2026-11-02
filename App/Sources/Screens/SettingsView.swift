import SwiftUI
import MinuitCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            List {
                Section("Compte") {
                    NavigationLink("Compte et serveur") { AccountSettings() }
                }
                Section("Préférences") {
                    NavigationLink("Lecture") { PlaybackSettings() }
                    NavigationLink("Catégories") { CategorySettings() }
                    NavigationLink("Guide TV") { GuideSettings() }
                    NavigationLink("Replay") { ReplaySettings() }
                    NavigationLink("Réseau et sécurité") { NetworkSettings() }
                }
                Section("Assistance") {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                    NavigationLink("À propos") { AboutView() }
                }
            }
            .navigationTitle("Réglages")
        }
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
        List {
            Section("Lecture") {
                LabeledContent("Moteur actif", value: app.playback.activeAttempt?.description ?? "—")
                LabeledContent("Détail", value: app.playback.technicalSummary)
                LabeledContent("Démarrages", value: "\(stats.tunes)")
                LabeledContent("Première image (médiane)", value: stats.medianFirstFrame.map { String(format: "%.2f s", $0) } ?? "—")
                LabeledContent("Reconnexions / replis / échecs", value: "\(stats.recoveries) / \(stats.fallbacks) / \(stats.failures)")
            }
            Section("Stockage") {
                Button("Vider les caches (catalogue, guide, logos)") { app.clearCaches() }
            }
            Section("Journal (secrets masqués)") {
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.level.rawValue) · \(entry.category)")
                            .font(Theme.Typeface.caption(18)).foregroundStyle(Theme.Palette.textTertiary)
                        Text(entry.message).font(Theme.Typeface.body(20))
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { entries = DiagnosticsLog.shared.snapshot() }
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
