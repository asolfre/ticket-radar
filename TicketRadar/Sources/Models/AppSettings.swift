import Foundation

struct AppSettings: Codable, Equatable {
    var pollIntervalMinutes: Int
    var notificationsEnabled: Bool
    var customToolPath: String?
    /// Base URL of the Jira instance, e.g. "https://yourcompany.atlassian.net".
    /// When nil/empty, "Open in Jira" links are hidden.
    var jiraBaseURL: String?
    /// GitHub organization searched for PRs whose title mentions a ticket key,
    /// e.g. "my-org". When nil/empty the owner is derived from PR links already
    /// present in the Jira ticket; if there are none, the search is skipped.
    ///
    /// Optional on purpose: a non-optional field would fail to decode from an
    /// existing settings.json, and PersistenceService silently falls back to
    /// defaults on decode failure.
    var githubOwner: String?
    /// Ticket prefix → GitHub organization, e.g. `["DATA": "acme-data"]`.
    /// Takes precedence over `githubOwner`, which stays as the default for
    /// prefixes not listed here. Optional for the same decode reason as above.
    var githubOwners: [String: String]?
    /// Ticket prefix → Jira site, e.g. `["API": "acme-labs.atlassian.net"]`.
    /// The app runs `acli jira auth switch --site` before fetching a ticket from
    /// another site. Optional for the same decode reason as above.
    var jiraSites: [String: String]?

    init(
        pollIntervalMinutes: Int = 5,
        notificationsEnabled: Bool = true,
        customToolPath: String? = nil,
        jiraBaseURL: String? = nil,
        githubOwner: String? = nil,
        githubOwners: [String: String]? = nil,
        jiraSites: [String: String]? = nil
    ) {
        self.pollIntervalMinutes = pollIntervalMinutes
        self.notificationsEnabled = notificationsEnabled
        self.customToolPath = customToolPath
        self.jiraBaseURL = jiraBaseURL
        self.githubOwner = githubOwner
        self.githubOwners = githubOwners
        self.jiraSites = jiraSites
    }

    static let `default` = AppSettings()

    /// The configured GitHub organization, trimmed, or nil if unset.
    var normalizedGithubOwner: String? {
        guard let raw = githubOwner?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// Organization to search for a ticket: its prefix mapping, else the default.
    func githubOwner(forTicketKey key: String) -> String? {
        githubOwners?[Self.prefix(of: key)] ?? normalizedGithubOwner
    }

    /// Jira site for a ticket: its prefix mapping, else the host of
    /// `jiraBaseURL`, else nil (leave acli's active site alone).
    ///
    /// The base-URL default matters once the app switches sites: an unmapped
    /// prefix would otherwise be fetched on whichever site the previous ticket
    /// used, and fail depending on refresh order.
    func jiraSite(forTicketKey key: String) -> String? {
        jiraSites?[Self.prefix(of: key)] ?? normalizedJiraBaseURL.flatMap { URL(string: $0)?.host }
    }

    static func prefix(of key: String) -> String {
        key.split(separator: "-").first.map { $0.uppercased() } ?? ""
    }

    /// Every configured organization (mapped + default), sorted, without duplicates.
    var allGithubOwners: [String] {
        Array(Set(Array((githubOwners ?? [:]).values) + [normalizedGithubOwner].compactMap { $0 })).sorted()
    }

    /// Parse `PREFIX = jira-site, github-org` lines. Both values are optional
    /// and may come in either order: a value with a dot is the Jira site
    /// (GitHub org names cannot contain dots), anything else is the org.
    /// Blank and malformed lines are ignored.
    static func parseProjectMap(_ text: String) -> (orgs: [String: String], sites: [String: String]) {
        var orgs: [String: String] = [:]
        var sites: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let prefix = parts[0].uppercased()
            for value in parts[1].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !value.isEmpty {
                if value.contains(".") {
                    sites[prefix] = URL(string: value)?.host ?? value
                } else {
                    orgs[prefix] = value
                }
            }
        }
        return (orgs, sites)
    }

    /// Inverse of `parseProjectMap`. Must write both maps: Settings saves on
    /// every change, so a line missing its site would delete that site.
    static func formatProjectMap(orgs: [String: String]?, sites: [String: String]?) -> String {
        let orgs = orgs ?? [:], sites = sites ?? [:]
        return Set(orgs.keys).union(sites.keys).sorted().map { prefix in
            "\(prefix) = " + [sites[prefix], orgs[prefix]].compactMap { $0 }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    /// The Jira base URL trimmed of whitespace and trailing slash, or nil if unset.
    var normalizedJiraBaseURL: String? {
        guard let raw = jiraBaseURL?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// Build a "browse" URL for a ticket key: on its prefix's Jira site, else
    /// on the base URL, else nil.
    func browseURL(for key: String) -> URL? {
        if let site = jiraSites?[Self.prefix(of: key)] {
            return URL(string: "https://\(site)/browse/\(key)")
        }
        guard let base = normalizedJiraBaseURL else { return nil }
        return URL(string: "\(base)/browse/\(key)")
    }
}
