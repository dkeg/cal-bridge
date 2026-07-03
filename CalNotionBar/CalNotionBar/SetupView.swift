import SwiftUI

struct SetupView: View {
    @State private var currentStep = 0
    @State private var notionKey = ""
    @State private var isConnecting = false
    @State private var googleConnected = false
    @State private var errorMessage: String? = nil

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                Text("Cal Notion Bar")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Connect your accounts to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()

            // Steps
            VStack(spacing: 0) {
                stepRow(
                    number: 1,
                    title: "Connect Google Calendar",
                    subtitle: "Authorize access to your calendars",
                    isComplete: googleConnected,
                    isCurrent: currentStep == 0
                ) {
                    connectGoogle
                }

                Divider().padding(.leading, 52)

                stepRow(
                    number: 2,
                    title: "Connect Notion",
                    subtitle: "Enter your Notion integration token",
                    isComplete: false,
                    isCurrent: currentStep == 1
                ) {
                    notionStep
                }
            }
            .padding(.vertical, 8)

            Divider()

            // Error
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            // Footer
            HStack {
                Button("Need help?") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/dkeg/cal-bridge#setup")!)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)

                Spacer()

                if currentStep == 1 {
                    Button("Finish Setup") { finishSetup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(notionKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Step Row

    func stepRow<Content: View>(
        number: Int,
        title: String,
        subtitle: String,
        isComplete: Bool,
        isCurrent: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // Step indicator
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : isCurrent ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isCurrent ? .white : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isCurrent || isComplete ? .primary : .secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if isCurrent {
                    content()
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Google Step

    var connectGoogle: some View {
        HStack(spacing: 10) {
            Button {
                startGoogleOAuth()
            } label: {
                HStack(spacing: 6) {
                    if isConnecting {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "globe")
                    }
                    Text(isConnecting ? "Waiting for authorization…" : "Connect with Google")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)

            if googleConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Notion Step

    var notionStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("secret_xxxxxxxxxxxx", text: $notionKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Get your token at notion.so/my-integrations")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("Open →") {
                    NSWorkspace.shared.open(URL(string: "https://notion.so/my-integrations")!)
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - Actions

    func startGoogleOAuth() {
        isConnecting = true
        errorMessage = nil

        let clientID = "89308251794-5vntu2vjqs36mdpcetqn0lb4oi0tke8t.apps.googleusercontent.com"
        let redirectURI = "com.googleusercontent.apps.89308251794-5vntu2vjqs36mdpcetqn0lb4oi0tke8t:/oauth2callback"
        let scope = "https://www.googleapis.com/auth/calendar.readonly"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }

        // Poll backend for the auth code
        Task { @MainActor in
            await pollForOAuthCode()
        }
    }

    func pollForOAuthCode() async {
        guard let url = URL(string: "http://localhost:8420/oauth/code") else { return }
        for _ in 0..<60 { // poll for up to 2 minutes
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? String else { continue }
            await exchangeCodeForToken(code: code)
            return
        }
        errorMessage = "Authorization timed out. Please try again."
        isConnecting = false
    }

    func exchangeCodeForToken(code: String) async {
        // Use backend to exchange code — keeps Desktop client secret off the client
        guard let url = URL(string: "http://localhost:8420/oauth/exchange") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let redirectURI = "com.googleusercontent.apps.89308251794-5vntu2vjqs36mdpcetqn0lb4oi0tke8t:/oauth2callback"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code, "redirectURI": redirectURI])

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let refreshToken = json["refresh_token"] as? String {
                    KeychainHelper.shared.save(refreshToken, for: KeychainHelper.googleRefreshToken)
                    googleConnected = true
                    isConnecting = false
                    currentStep = 1
                } else if let error = json["error"] as? String {
                    errorMessage = "Auth error: \(error)"
                    isConnecting = false
                }
            }
        } catch {
            errorMessage = "Connection error: \(error.localizedDescription)"
            isConnecting = false
        }
    }

    func finishSetup() {
        let key = notionKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        KeychainHelper.shared.save(key, for: KeychainHelper.notionAPIKey)
        UserDefaults.standard.set(true, forKey: "setupComplete")

        // Sync credentials to backend
        syncCredentialsToBackend()
        onComplete()
    }

    func syncCredentialsToBackend() {
        guard let url = URL(string: "http://localhost:8420/credentials") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let refreshToken = KeychainHelper.shared.load(KeychainHelper.googleRefreshToken) ?? ""
        let notionKey = KeychainHelper.shared.load(KeychainHelper.notionAPIKey) ?? ""

        let body: [String: Any] = [
            "googleRefreshToken": refreshToken,
            "notionAPIKey": notionKey
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}
