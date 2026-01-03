import SwiftUI
import EventKit
import AmbientCore

/// Onboarding view that guides users through permission setup
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep: OnboardingStep = .welcome
    @State private var permissionsManager = PermissionsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 10)

            // Content
            TabView(selection: $currentStep) {
                WelcomeStepView(onContinue: { currentStep = .calendar })
                    .tag(OnboardingStep.welcome)

                CalendarPermissionStepView(
                    permissionsManager: permissionsManager,
                    onContinue: { currentStep = .fullDiskAccess }
                )
                .tag(OnboardingStep.calendar)

                FullDiskAccessStepView(
                    permissionsManager: permissionsManager,
                    onContinue: { currentStep = .automation }
                )
                .tag(OnboardingStep.fullDiskAccess)

                AutomationStepView(
                    permissionsManager: permissionsManager,
                    onContinue: { currentStep = .complete }
                )
                .tag(OnboardingStep.automation)

                CompleteStepView(onFinish: {
                    dismiss()
                })
                .tag(OnboardingStep.complete)
            }
            .tabViewStyle(.automatic)
        }
        .frame(width: 500, height: 450)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Onboarding Steps

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case calendar = 1
    case fullDiskAccess = 2
    case automation = 3
    case complete = 4
}

// MARK: - Welcome Step

struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            Text("Welcome to Ambient Agent")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ambient Agent monitors your digital life and uses AI to extract events and tasks automatically.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("Let's set up the permissions needed to get started.")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        }
    }
}

// MARK: - Calendar Permission Step

struct CalendarPermissionStepView: View {
    @Bindable var permissionsManager: PermissionsManager
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Calendar & Reminders")
                .font(.title)
                .fontWeight(.semibold)

            Text("Allow access to your Calendar and Reminders to automatically track events and tasks.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Permission status
            HStack(spacing: 16) {
                PermissionStatusRow(
                    title: "Calendar",
                    state: permissionsManager.calendarPermission
                )
                PermissionStatusRow(
                    title: "Reminders",
                    state: permissionsManager.remindersPermission
                )
            }
            .padding(.vertical)

            Spacer()

            VStack(spacing: 12) {
                if permissionsManager.calendarPermission != .granted {
                    Button("Grant Calendar Access") {
                        Task {
                            _ = await permissionsManager.requestCalendarPermission()
                            _ = await permissionsManager.requestRemindersPermission()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Button(action: onContinue) {
                    Text(permissionsManager.calendarPermission == .granted ? "Continue" : "Skip for Now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        }
    }
}

// MARK: - Full Disk Access Step

struct FullDiskAccessStepView: View {
    @Bindable var permissionsManager: PermissionsManager
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 60))
                .foregroundStyle(.purple)

            Text("Full Disk Access")
                .font(.title)
                .fontWeight(.semibold)

            Text("Full Disk Access is required to read your Messages and Safari history for intelligent extraction.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Permission status
            PermissionStatusRow(
                title: "Full Disk Access",
                state: permissionsManager.fullDiskAccessPermission
            )
            .padding(.vertical)

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("To enable Full Disk Access:")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("1. Click \"Open System Settings\" below")
                Text("2. Click the + button")
                Text("3. Add Ambient Agent from Applications")
                Text("4. Enable the toggle next to Ambient Agent")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 12) {
                if permissionsManager.fullDiskAccessPermission != .granted {
                    Button("Open System Settings") {
                        permissionsManager.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Check Permission") {
                        permissionsManager.checkFullDiskAccess()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Button(action: onContinue) {
                    Text(permissionsManager.fullDiskAccessPermission == .granted ? "Continue" : "Skip for Now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        }
    }
}

// MARK: - Automation Step

struct AutomationStepView: View {
    @Bindable var permissionsManager: PermissionsManager
    let onContinue: () -> Void

    @State private var safariGranted = false
    @State private var mailGranted = false
    @State private var notesGranted = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "gear.badge.checkmark")
                .font(.system(size: 60))
                .foregroundStyle(.cyan)

            Text("Automation Access")
                .font(.title)
                .fontWeight(.semibold)

            Text("Grant automation access to Safari, Mail, and Notes for full monitoring capabilities.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // App permissions
            VStack(spacing: 12) {
                AutomationAppRow(
                    appName: "Safari",
                    icon: "safari",
                    isGranted: $safariGranted
                ) {
                    Task {
                        safariGranted = await permissionsManager.requestAutomationPermission(for: "com.apple.Safari")
                    }
                }

                AutomationAppRow(
                    appName: "Mail",
                    icon: "envelope.fill",
                    isGranted: $mailGranted
                ) {
                    Task {
                        mailGranted = await permissionsManager.requestAutomationPermission(for: "com.apple.mail")
                    }
                }

                AutomationAppRow(
                    appName: "Notes",
                    icon: "note.text",
                    isGranted: $notesGranted
                ) {
                    Task {
                        notesGranted = await permissionsManager.requestAutomationPermission(for: "com.apple.Notes")
                    }
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 12) {
                Button("Open Automation Settings") {
                    permissionsManager.openAutomationSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: onContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        }
    }
}

struct AutomationAppRow: View {
    let appName: String
    let icon: String
    @Binding var isGranted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.secondary)

            Text(appName)
                .fontWeight(.medium)

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Request") {
                    onRequest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Complete Step

struct CompleteStepView: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ambient Agent is now configured and ready to help you stay organized.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "calendar", text: "Calendar events will be tracked")
                FeatureRow(icon: "message.fill", text: "Messages scanned for events & tasks")
                FeatureRow(icon: "sparkles", text: "AI extraction runs automatically")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 40)

            Spacer()

            Button(action: onFinish) {
                Text("Start Using Ambient Agent")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(text)
                .font(.callout)
        }
    }
}

// MARK: - Permission Status Row

struct PermissionStatusRow: View {
    let title: String
    let state: PermissionState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.icon)
                .foregroundStyle(Color(state.color))

            Text(title)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
}
