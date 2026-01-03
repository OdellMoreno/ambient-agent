import SwiftUI
import SwiftData
import AmbientCore

@main
struct AmbientAgentApp: App {
    @State private var appState = AppState()
    @State private var permissionsManager = PermissionsManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true // Skip onboarding for dev
    @State private var showingOnboarding = false

    var body: some Scene {
        // Main Dashboard Window
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    // Auto-sync on app launch
                    await appState.syncAll()
                }
                .sheet(isPresented: $showingOnboarding) {
                    OnboardingView()
                        .interactiveDismissDisabled(!hasCompletedOnboarding)
                        .onDisappear {
                            hasCompletedOnboarding = true
                        }
                }
        }
        .modelContainer(DatabaseManager.shared.container)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Ambient Agent") {
                    appState.showingAbout = true
                }
            }

            CommandGroup(after: .appSettings) {
                Button("Sync Now") {
                    Task {
                        await appState.syncAll()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button("Run Setup Wizard...") {
                    showingOnboarding = true
                }
            }
        }

        // Menu Bar Extra
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .modelContainer(DatabaseManager.shared.container)
        } label: {
            Label {
                Text("Ambient")
            } icon: {
                Image(systemName: appState.hasUnreadItems ? "bell.badge.fill" : "bell.fill")
            }
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(DatabaseManager.shared.container)
        }
    }
}
