import SwiftUI

struct AnisetteOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = AnisetteConfiguration.load().mode
    @State private var server = AnisetteConfiguration.load().server
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Sign-in Settings")
                .font(.title2.bold())
            Text("Automatic works for most users. You can use your own server or restrict sign-in data generation to this Mac.")
                .foregroundStyle(.secondary)

            Form {
                Picker("Sign-in data", selection: $mode) {
                    ForEach(AnisetteConfiguration.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if mode != .local {
                    TextField("Anisette V3 server", text: $server)
                        .textFieldStyle(.roundedBorder)
                    Text("The server receives a generated device identity and its provisioning data. Your Apple Account email, password and verification codes are not sent to this server. Use a server you trust.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("The default server is operated by SideStore. You can enter your own HTTPS server address, including a custom port.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No external sign-in service will be contacted. If this Mac cannot prepare the required data, sign-in will stop. Choose Automatic to allow a server fallback.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Changes apply to new sign-ins. If a verification code is pending, go back to the sign-in form after saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func save() {
        do {
            let address = mode == .local ? server : try AnisetteConfiguration.serverURL(server).absoluteString
            UserDefaults.standard.set(address, forKey: AnisetteConfiguration.serverKey)
            UserDefaults.standard.set(mode.rawValue, forKey: AnisetteConfiguration.modeKey)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
