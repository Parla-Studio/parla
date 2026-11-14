import ParlaCore
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel

    @State private var register = false
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var server = ""
    @State private var showServer = false
    @State private var localError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("Logo")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .padding(.top, 48)
                    .accessibilityLabel("Parla")
                Text("Parla")
                    .font(.largeTitle.bold())
                    .padding(.top, 18)
                Text("Sprachen lernen – einfach,\nkostenlos und ohne Werbung")
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                VStack(spacing: 12) {
                    Picker("", selection: $register) {
                        Text("Anmelden").tag(false)
                        Text("Neues Konto").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: register) { localError = nil }
                    .padding(.bottom, 4)

                    VStack(spacing: 0) {
                        field { TextField("Benutzername", text: $username) }
                            .textContentType(.username)
                        Divider().padding(.leading, 16)
                        field { SecureField("Passwort", text: $password) }
                            .textContentType(register ? .newPassword : .password)
                        if register {
                            Divider().padding(.leading, 16)
                            field { SecureField("Passwort wiederholen", text: $confirm) }
                                .textContentType(.newPassword)
                        }
                        if showServer {
                            Divider().padding(.leading, 16)
                            field { TextField("Serveradresse", text: $server) }
                                .keyboardType(.URL)
                        }
                    }
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if register {
                        Text("Wähle einen Namen, den du dir gut merken kannst. Das Passwort braucht mindestens 8 Zeichen.")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                    }
                    if let message = localError ?? model.error {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(Palette.redDark)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                    }

                    Button(model.busy ? "Einen Moment …" : (register ? "Konto erstellen" : "Anmelden")) { submit() }
                        .buttonStyle(.primary)
                        .disabled(model.busy)
                        .padding(.top, 4)

                    Button(showServer ? "Serveradresse ausblenden" : "Server: \(displayServer)") {
                        withAnimation { showServer.toggle() }
                    }
                    .font(.callout)
                    .frame(minHeight: 44)
                }
                .frame(maxWidth: 440)
                .padding(.top, 32)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.groupedBackground)
        .onAppear { if server.isEmpty { server = repo.state.serverUrl } }
    }

    private var displayServer: String {
        server.hasPrefix("https://") ? String(server.dropFirst("https://".count)) : server
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
    }

    private func submit() {
        let url = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty {
            localError = "Bitte Benutzername und Passwort eingeben."
        } else if register && password.count < 8 {
            localError = "Das Passwort muss mindestens 8 Zeichen lang sein."
        } else if register && password != confirm {
            localError = "Die beiden Passwörter sind nicht gleich."
        } else if !url.hasPrefix("https://") && !url.hasPrefix("http://") {
            localError = "Die Serveradresse muss mit https:// beginnen."
        } else if url.hasPrefix("http://") && !isLocalAddress(url) {
            localError = "http:// geht nur für Server im eigenen Netz (z. B. 192.168.… oder 10.…). Nutze sonst https://."
        } else {
            localError = nil
            model.authenticate(server: url, username: username, password: password, register: register)
        }
    }
}

/// True for servers in the local network: private IPv4 ranges (10/8, 172.16/12, 192.168/16, 100.64/10 as used by
/// VPNs like Tailscale), loopback, link-local, IPv6 ULA/link-local and local host names (localhost, *.local,
/// *.lan, *.home.arpa, *.internal). Only these may be used with plain http:// (same rule as the Android app).
func isLocalAddress(_ url: String) -> Bool {
    guard var host = URLComponents(string: url)?.host?.lowercased() else { return false }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || [".local", ".lan", ".home.arpa", ".internal"].contains(where: { host.hasSuffix($0) }) {
        return true
    }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    if parts.count == 4, parts.allSatisfy({ $0 != nil }) {
        let a = parts[0]!
        let b = parts[1]!
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
    }
    if host.contains(":") {
        return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
    }
    return false
}
