import SwiftUI
import MinuitCore

/// Connexion Xtream : trois champs, validation explicite, aucun secret affiché en clair
/// hors du champ mot de passe sécurisé.
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
        HStack(spacing: 120) {
            VStack(spacing: 22) {
                Image(systemName: "moon.stars.fill").font(.system(size: 96)).foregroundStyle(Theme.Palette.moon)
                Text("Minuit").font(Theme.Typeface.display(110)).foregroundStyle(Theme.Palette.textPrimary)
                Text("La télévision en direct, sans détour.")
                    .font(Theme.Typeface.title(32))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Saisissez les informations Xtream Codes fournies par votre fournisseur. Les identifiants sont conservés dans le trousseau sécurisé de l'Apple TV.")
                    .font(Theme.Typeface.body(23))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: 620)
            }
            .frame(width: 700)
            VStack(alignment: .leading, spacing: 22) {
                Text("Compte Xtream Codes").sectionHeader()
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
            .frame(width: 760)
        }
        .padding(.horizontal, Theme.Metrics.safeHorizontal * 2)
        .onAppear { field = .server }
    }
}
