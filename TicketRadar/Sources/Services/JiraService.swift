import Foundation

/// Service for fetching Jira ticket data via the `acli` CLI tool
enum JiraService {

    struct TicketInfo {
        let key: String
        let title: String
        let prURLs: [String]
    }

    /// Fetch ticket details and extract linked PR URLs
    /// - Parameters:
    ///   - ticketKey: Jira ticket key (e.g. "DEMO-4821")
    ///   - site: Jira site to fetch from (e.g. "acme-labs.atlassian.net"), or
    ///     nil to use acli's active site without switching
    ///   - customPath: Optional PATH override
    /// - Returns: TicketInfo with title and PR URLs
    static func fetchTicket(key ticketKey: String, site: String? = nil, customPath: String? = nil) async throws -> TicketInfo {
        let output = try await siteGate.run(
            site: site,
            switchSite: { site in
                _ = try await ShellExecutor.runOrThrow(
                    command: "acli",
                    arguments: ["jira", "auth", "switch", "--site", site],
                    customPath: customPath
                )
            },
            retryable: { ($0 as? ShellError)?.kind == .notFound },
            {
                try await ShellExecutor.runOrThrow(
                    command: "acli",
                    arguments: ["jira", "workitem", "view", ticketKey, "--json"],
                    customPath: customPath
                )
            }
        )

        guard let data = output.data(using: .utf8) else {
            throw JiraError.invalidResponse("Could not decode acli output as UTF-8")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.invalidResponse("Could not parse JSON from acli output")
        }

        let fields = json["fields"] as? [String: Any] ?? [:]

        // Extract title
        let title = fields["summary"] as? String ?? ticketKey

        // Extract PR URLs from description (Atlassian Document Format)
        let description = fields["description"] as? [String: Any] ?? [:]
        let prURLs = extractPRURLs(from: description)

        return TicketInfo(key: ticketKey, title: title, prURLs: prURLs)
    }

    // MARK: - ADF Parsing

    /// Recursively walk the ADF tree to find inlineCard nodes with GitHub PR URLs.
    ///
    /// Only `inlineCard` nodes count. Plain hyperlinks (ADF `link` marks) are
    /// deliberately ignored: any `github.com/*/pull/*` URL mentioned in prose —
    /// typically a reference to a review comment on somebody else's PR, e.g.
    /// `.../pull/126#discussion_r3111613708` — would otherwise be treated as a
    /// PR linked to this ticket. Smart-links pasted by the user become
    /// `inlineCard` nodes and remain the reliable signal.
    static func extractPRURLs(from node: Any) -> [String] {
        var urls: [String] = []

        if let dict = node as? [String: Any] {
            // Check if this is an inlineCard with a GitHub PR URL
            if let type = dict["type"] as? String, type == "inlineCard",
               let attrs = dict["attrs"] as? [String: Any],
               let url = attrs["url"] as? String,
               isGitHubPRURL(url) {
                urls.append(url)
            }

            // Recurse into all values
            for value in dict.values {
                urls.append(contentsOf: extractPRURLs(from: value))
            }
        } else if let array = node as? [Any] {
            for item in array {
                urls.append(contentsOf: extractPRURLs(from: item))
            }
        }

        // Deduplicate while preserving order
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static func isGitHubPRURL(_ url: String) -> Bool {
        url.contains("github.com") && url.contains("/pull/")
    }

    /// Serializes every acli Jira call: switching the site is global acli state.
    static let siteGate = JiraSiteGate()
}

/// Runs Jira fetches one at a time, switching acli's active site when needed.
///
/// acli has no per-call `--site`, only `acli jira auth switch`, which changes
/// global state. Without serialization a manual refresh overlapping the poll
/// could switch sites between another fetch's switch and its fetch.
///
/// The switch and fetch steps are passed in so the self-check can drive the
/// gate with fakes.
actor JiraSiteGate {
    /// Site this gate last switched to. Nil until the first switch, or when a
    /// switch failed halfway.
    private var activeSite: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - site: target site, or nil to run `body` on whatever site is active
    ///   - retryable: errors worth one switch-and-retry. Only used when the
    ///     switch was skipped because `activeSite` already matched: someone may
    ///     have switched acli in a terminal since.
    func run<T>(
        site: String?,
        switchSite: (String) async throws -> Void,
        retryable: (Error) -> Bool,
        _ body: () async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }

        guard let site else { return try await body() }

        let skippedSwitch = activeSite == site
        if !skippedSwitch {
            try await switchTo(site, using: switchSite)
        }
        do {
            return try await body()
        } catch where skippedSwitch && retryable(error) {
            try await switchTo(site, using: switchSite)
            return try await body()
        }
    }

    private func switchTo(_ site: String, using switchSite: (String) async throws -> Void) async throws {
        activeSite = nil
        try await switchSite(site)
        activeSite = site
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock straight to the next waiter, so `busy` stays true.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Errors

enum JiraError: LocalizedError {
    case invalidResponse(String)
    case ticketNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return "Invalid Jira response: \(detail)"
        case .ticketNotFound(let key):
            return "Ticket \(key) not found"
        }
    }
}
