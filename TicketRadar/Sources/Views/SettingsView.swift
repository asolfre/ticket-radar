import SwiftUI

struct SettingsView: View {
    @Bindable var ticketStore: TicketStore
    var onSettingsChanged: (() -> Void)?
    @State private var pollInterval: Double = 5
    @State private var notificationsEnabled: Bool = true
    @State private var customToolPath: String = ""
    @State private var jiraBaseURL: String = ""
    @State private var githubOwner: String = ""
    @State private var projectsText: String = ""

    /// Orgs as currently typed, so the SSO links update before saving.
    private var previewOwners: [String] {
        AppSettings(githubOwner: githubOwner, githubOwners: AppSettings.parseProjectMap(projectsText).orgs).allGithubOwners
    }

    var body: some View {
        Form {
            Section("Polling") {
                HStack {
                    Text("Refresh every")
                    Slider(value: $pollInterval, in: 1...30, step: 1)
                    Text("\(Int(pollInterval)) min")
                        .monospacedDigit()
                        .frame(width: 50)
                }
            }

            Section("Notifications") {
                Toggle("Send notifications on PR status changes", isOn: $notificationsEnabled)
            }

            Section("Projects") {
                TextEditor(text: $projectsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 72)
                Text("One per line: PREFIX = jira-site, github-org (e.g. DATA = acme.atlassian.net, acme-data). Both are optional and override the defaults below for that prefix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Jira") {
                TextField("https://yourcompany.atlassian.net", text: $jiraBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Default site for prefixes not listed above, and for \"Open in Jira\" links. Leave empty to use acli's active site and hide the links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GitHub") {
                TextField("Default organization (optional)", text: $githubOwner)
                    .textFieldStyle(.roundedBorder)
                Text("Also finds PRs whose title mentions the ticket key, even if they aren't linked in Jira yet. Leave empty to infer it from PRs already linked in the ticket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !previewOwners.isEmpty {
                    SSOHelpView(orgs: previewOwners)
                }
            }

            Section("CLI Tools") {
                TextField("Custom PATH override (optional)", text: $customToolPath)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to use system PATH. Set if acli/gh are not found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 640)
        .padding()
        .onAppear {
            pollInterval = Double(ticketStore.settings.pollIntervalMinutes)
            notificationsEnabled = ticketStore.settings.notificationsEnabled
            customToolPath = ticketStore.settings.customToolPath ?? ""
            jiraBaseURL = ticketStore.settings.jiraBaseURL ?? ""
            githubOwner = ticketStore.settings.githubOwner ?? ""
            projectsText = AppSettings.formatProjectMap(
                orgs: ticketStore.settings.githubOwners,
                sites: ticketStore.settings.jiraSites
            )
        }
        // Save on every change, not in onDisappear: closing the macOS Settings
        // window does not reliably fire onDisappear, so edits were never saved.
        .onChange(of: draft) { _, newSettings in
            guard newSettings != ticketStore.settings else { return }
            // Only the interval affects the timer; restarting on every
            // keystroke kept pushing the next poll back while typing.
            let intervalChanged = newSettings.pollIntervalMinutes != ticketStore.settings.pollIntervalMinutes
            ticketStore.updateSettings(newSettings)
            if intervalChanged { onSettingsChanged?() }
        }
    }

    private var draft: AppSettings {
        let projects = AppSettings.parseProjectMap(projectsText)
        return AppSettings(
            pollIntervalMinutes: Int(pollInterval),
            notificationsEnabled: notificationsEnabled,
            customToolPath: customToolPath.isEmpty ? nil : customToolPath,
            jiraBaseURL: jiraBaseURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : jiraBaseURL,
            githubOwner: githubOwner.trimmingCharacters(in: .whitespaces).isEmpty ? nil : githubOwner,
            githubOwners: projects.orgs.isEmpty ? nil : projects.orgs,
            jiraSites: projects.sites.isEmpty ? nil : projects.sites
        )
    }
}

/// A shell command shown as selectable text with a Copy button.
struct CopyCommandRow: View {
    let label: String
    let command: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .controlSize(.small)
        }
        .font(.caption)
    }
}

/// Fix for an expired acli Jira sign-in.
///
/// `acli jira auth login --web` renews only the *active* site's sign-in, so the
/// command switches to the site first; the user must also pick that site in
/// the browser.
struct JiraLoginHelpView: View {
    /// Site to sign in to again, or "" when unknown (no configured site).
    let site: String

    private var command: String {
        site.isEmpty
            ? "acli jira auth login --web"
            : "acli jira auth switch --site \(site) && acli jira auth login --web"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(site.isEmpty
                 ? "Jira sign-in expired. Sign in again:"
                 : "Jira sign-in for \(site) expired. Sign in again, and pick \(site) in the browser:")
                .font(.caption)
                .foregroundStyle(.secondary)
            CopyCommandRow(label: "Run in Terminal:", command: command)
        }
    }
}

/// Two-step fix for GitHub org SSO (SAML) blocking `gh search`.
///
/// Both steps are needed, in order: the browser sign-in alone does not
/// authorize the existing `gh` token, and `gh auth refresh` only produces an
/// SSO-authorized token while a browser SSO session is active.
struct SSOHelpView: View {
    let orgs: [String]
    private let refreshCommand = "gh auth refresh -h github.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("If PR search fails with \"SAML single sign-on\", do both steps, in this order:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(orgs, id: \.self) { org in
                if let url = URL(string: "https://github.com/orgs/\(org)/sso") {
                    Link("1. Sign in to \(org) via SSO", destination: url)
                        .font(.caption)
                }
            }
            CopyCommandRow(label: "2. Then run in Terminal:", command: refreshCommand)
        }
    }
}
