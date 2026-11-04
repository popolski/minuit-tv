import SwiftUI
import MinuitCore

/// Connexion Xtream : à gauche la saisie à la télécommande, à droite la configuration
/// depuis le téléphone (QR code, code à 6 chiffres). Aucun secret affiché en clair hors
/// du champ mot de passe sécurisé.
struct LoginView: View {
    @Environment(AppModel.self) private var app
    let message: String?

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @FocusState private var field: Field?

    enum Field { case server, username, password, submit }

    var body: some View {
        HStack(alignment: .center, spacing: 110) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    MinuitMark(size: 72)
                    Text("Minuit").font(Theme.Typeface.display(64)).foregroundStyle(Theme.Palette.textPrimary)
                }
                Text("Saisissez les informations Xtream Codes fournies par votre fournisseur. Les identifiants sont conservés dans le trousseau sécurisé de l'Apple TV.")
                    .font(Theme.Typeface.body(23))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.bottom, 8)
                TextField("Adresse du serveur (ex. exemple.tv:8080)", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($field, equals: .server)
                    .foregroundStyle(field == .server ? Theme.Palette.night : Theme.Palette.textPrimary)
                TextField("Identifiant", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($field, equals: .username)
                    .foregroundStyle(field == .username ? Theme.Palette.night : Theme.Palette.textPrimary)
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                    .focused($field, equals: .password)
                    .foregroundStyle(field == .password ? Theme.Palette.night : Theme.Palette.textPrimary)
                if let message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(Theme.Typeface.label(24))
                        .foregroundStyle(Theme.Palette.danger)
                }
                Text("Adresse HTTP ou HTTPS acceptée, port compris (ex. http://exemple.tv:8080).")
                    .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textTertiary)
                Button {
                    isWorking = true
                    Task {
                        await app.signIn(server: server, username: username, password: password)
                        isWorking = false
                    }
                } label: {
                    HStack {
                        if isWorking { ProgressView() }
                        Text(isWorking ? "Connexion…" : "Se connecter").font(Theme.Typeface.label(28)).primaryText()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(GlassRowButtonStyle(cornerRadius: 40, horizontalPadding: 30, verticalPadding: 14))
                .disabled(isWorking || server.isEmpty || username.isEmpty || password.isEmpty)
                .focused($field, equals: .submit)
            }
            .frame(width: 780)

            PhoneSetupPanel(setup: app.phoneSetup)
                .frame(width: 600)
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal)
        .onAppear {
            field = .server
            if !DemoMode.isEnabled { app.phoneSetup.start() }
        }
    }
}

/// QR code + code à 6 chiffres + adresse de secours, et l'état de la liaison avec le téléphone.
private struct PhoneSetupPanel: View {
    let setup: PhoneSetupServer

    var body: some View {
        VStack(spacing: 26) {
            Text("Ou avec votre téléphone").font(Theme.Typeface.title(34)).foregroundStyle(Theme.Palette.textPrimary)
            switch setup.status {
            case .unavailable(let reason):
                Label(reason, systemImage: "wifi.exclamationmark")
                    .font(Theme.Typeface.body(23)).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            default:
                if let image = setup.qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 300, height: 300)
                        .padding(28)
                        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.white))
                        .accessibilityLabel("QR code de configuration")
                }
                VStack(spacing: 8) {
                    Text("Scannez avec l’appareil photo du téléphone, puis saisissez vos identifiants sur la page qui s’ouvre.")
                        .font(Theme.Typeface.body(22)).foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    if let address = setup.address {
                        Text("Sans QR code : ouvrez \(address) et tapez \(setup.session.displayCode)")
                            .font(Theme.Typeface.caption(20)).foregroundStyle(Theme.Palette.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                statusLine
            }
            Text("Le téléphone doit être sur le même réseau que l’Apple TV.")
                .font(Theme.Typeface.caption(19)).foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch setup.status {
        case .phoneConnected:
            Label("Téléphone connecté : remplissez la page, puis « Envoyer ».", systemImage: "iphone")
                .font(Theme.Typeface.label(22)).foregroundStyle(Theme.Palette.textPrimary)
        case .signingIn:
            HStack(spacing: 12) {
                ProgressView()
                Text("Vérification du compte…").font(Theme.Typeface.label(22)).foregroundStyle(Theme.Palette.textPrimary)
            }
        default:
            Text("Code \(setup.session.displayCode)").font(Theme.Typeface.time(30)).foregroundStyle(Theme.Palette.textPrimary)
        }
    }
}
