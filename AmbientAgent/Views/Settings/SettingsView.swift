import SwiftUI
import ServiceManagement
import Security
import AmbientCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("syncIntervalMinutes") private var syncIntervalMinutes = 5

    var body: some View {
        TabView {
            GeneralSettingsView(
                launchAtLogin: $launchAtLogin,
                showMenuBarIcon: $showMenuBarIcon,
                syncIntervalMinutes: $syncIntervalMinutes
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }

            DataSourcesSettingsView()
                .tabItem {
                    Label("Data Sources", systemImage: "arrow.triangle.2.circlepath")
                }

            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised.fill")
                }

            APISettingsView()
                .tabItem {
                    Label("API", systemImage: "key.fill")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Binding var launchAtLogin: Bool
    @Binding var showMenuBarIcon: Bool
    @Binding var syncIntervalMinutes: Int

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLoginItem(enabled: newValue)
                    }

                Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
            }

            Section("Sync") {
                Picker("Sync Interval", selection: $syncIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            AmbientLogger.general.error("Failed to update login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - Data Sources Settings

struct DataSourcesSettingsView: View {
    @AppStorage("enableCalendar") private var enableCalendar = true
    @AppStorage("enableMessages") private var enableMessages = true
    @AppStorage("enableMail") private var enableMail = false
    @AppStorage("enableSafari") private var enableSafari = false
    @AppStorage("enableNotes") private var enableNotes = false

    var body: some View {
        Form {
            Section("Active Sources") {
                Toggle("Calendar & Reminders", isOn: $enableCalendar)
                Toggle("Messages", isOn: $enableMessages)
                Toggle("Apple Mail", isOn: $enableMail)
                    .disabled(true)
                Toggle("Safari", isOn: $enableSafari)
                    .disabled(true)
                Toggle("Notes", isOn: $enableNotes)
                    .disabled(true)
            }

            Section {
                Text("Some sources require Full Disk Access permission in System Settings > Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Privacy Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Privacy Settings

struct PrivacySettingsView: View {
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        Form {
            Section("Privacy Mode") {
                Toggle("Blur Contact Names", isOn: Binding(
                    get: { service.privacyBlurEnabled },
                    set: { _ in service.togglePrivacyBlur() }
                ))

                Text("Enable this when sharing screenshots to hide contact information.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Blocked Contacts") {
                Text("Blocked contacts are completely hidden from insights. Right-click any contact in the People tab to block them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if service.blockedContacts.isEmpty {
                    Label("No contacts blocked", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label("\(service.blockedContacts.count) contact\(service.blockedContacts.count == 1 ? "" : "s") blocked", systemImage: "hand.raised.fill")
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Unblock All") {
                            for contact in service.blockedContacts {
                                service.unblockContact(contact)
                            }
                        }
                        .foregroundStyle(.red)
                    }
                }
            }

        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - API Settings

struct APISettingsView: View {
    @ObservedObject private var gemini = GeminiService.shared
    @State private var geminiKey: String = ""
    @State private var claudeKey: String = ""
    @State private var showGeminiKey = false
    @State private var showClaudeKey = false
    @State private var savedSuccessfully = false

    var body: some View {
        Form {
            Section("Gemini API (AI Insights)") {
                HStack {
                    if showGeminiKey {
                        TextField("Gemini API Key", text: $geminiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Gemini API Key", text: $geminiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showGeminiKey.toggle()
                    } label: {
                        Image(systemName: showGeminiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save") {
                        gemini.apiKey = geminiKey
                        savedSuccessfully = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            savedSuccessfully = false
                        }
                    }
                    .disabled(geminiKey.isEmpty)

                    if savedSuccessfully && !geminiKey.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    Link("Get API Key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.caption)
                }

                Text("Powers AI relationship analysis, life event detection, and smart suggestions. Free tier: 15 requests/min.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude API (Optional)") {
                HStack {
                    if showClaudeKey {
                        TextField("Claude API Key", text: $claudeKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Claude API Key", text: $claudeKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showClaudeKey.toggle()
                    } label: {
                        Image(systemName: showClaudeKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save") {
                        saveClaudeKey()
                    }
                    .disabled(claudeKey.isEmpty)

                    Spacer()

                    Link("Get API Key", destination: URL(string: "https://console.anthropic.com")!)
                        .font(.caption)
                }

                Text("For advanced analysis. Currently not used - Gemini handles all AI features.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            geminiKey = gemini.apiKey ?? ""
            loadClaudeKey()
        }
    }

    private func loadClaudeKey() {
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty {
            claudeKey = envKey
        } else if let storedKey = try? KeychainHelper.load(key: "anthropic_api_key") {
            claudeKey = storedKey
        }
    }

    private func saveClaudeKey() {
        do {
            try KeychainHelper.save(key: "anthropic_api_key", value: claudeKey)
            setenv("ANTHROPIC_API_KEY", claudeKey, 1)
        } catch {
            print("Failed to save Claude API key: \(error)")
        }
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(key: String, value: String) throws {
        let data = Data(value.utf8)

        // Delete existing item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.ambient.agent"
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.ambient.agent",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.ambient.agent",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.loadFailed(status)
        }

        return string
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Ambient Agent")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("An intelligent assistant that monitors your digital life and extracts events and tasks using AI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Text("Built with Swift, SwiftUI, and Claude AI")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
