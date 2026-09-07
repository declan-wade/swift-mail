import SwiftUI

struct AccountSetupView: View {
    @ObservedObject var store: MailStore

    @State private var displayName = ""
    @State private var sessionAddress = ""
    @State private var bearerToken = ""
    @State private var setupError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Set Up JMAP Mail")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Connect with a JMAP session endpoint and bearer token.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Account name", text: $displayName)
                TextField("JMAP session URL", text: $sessionAddress)
                    .textContentType(.URL)
                SecureField("Bearer token", text: $bearerToken)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 460)

            if let setupError {
                Text(setupError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button {
                Task {
                    await saveAndConnect()
                }
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || sessionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bearerToken.isEmpty)
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func saveAndConnect() async {
        isSaving = true
        setupError = nil

        do {
            let url = try normalizedSessionURL(from: sessionAddress)
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.saveAccount(
                displayName: name.isEmpty ? url.host(percentEncoded: false) ?? "JMAP Account" : name,
                sessionURL: url,
                bearerToken: bearerToken
            )
            await store.refresh()
        } catch {
            setupError = error.localizedDescription
        }

        isSaving = false
    }

    private func normalizedSessionURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard var components = URLComponents(string: address), components.host != nil else {
            throw AccountSetupError.invalidURL
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/.well-known/jmap"
        }

        guard let url = components.url else {
            throw AccountSetupError.invalidURL
        }

        return url
    }
}

enum AccountSetupError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "Enter a valid JMAP session URL."
    }
}
