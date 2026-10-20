#if DEBUG
import Foundation

/// Runnable check for PR-discovery logic. DEBUG only, and only with
/// `TR_SELFCHECK=1`; exits 0 on success, 1 on the first failure:
///
/// ```bash
/// TR_SELFCHECK=1 "<BUILT_PRODUCTS_DIR>/TicketRadar.app/Contents/MacOS/TicketRadar"; echo "exit=$?"
/// ```
///
/// Uses `guard` + `exit(1)` instead of `assert`, which optimized builds strip.
@MainActor
enum DebugSelfCheck {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TR_SELFCHECK"] == "1"
    }

    static func run() -> Never {
        // 1. Plain hyperlinks (ADF link marks) are not linked PRs; inlineCards are.
        let adf: [String: Any] = ["content": [
            ["type": "text", "text": "see",
             "marks": [["type": "link", "attrs": ["href": "https://github.com/Org/Repo/pull/126#discussion_r1"]]]],
            ["type": "inlineCard", "attrs": ["url": "https://github.com/Org/Repo/pull/7"]],
        ]]
        check(JiraService.extractPRURLs(from: adf) == ["https://github.com/Org/Repo/pull/7"],
              "link marks must be ignored, inlineCards kept")

        // 2. URL variants collapse to one key; stored URL keeps its case.
        let variants = [
            "https://github.com/Org/Repo/pull/12",
            "https://github.com/Org/Repo/pull/12/files",
            "https://github.com/Org/Repo/pull/12#x",
            "https://github.com/Org/Repo/pull/12?w=1",
            "https://github.com/org/repo/pull/12",
        ]
        check(Set(variants.map(GitHubService.prKey)).count == 1, "PR URL variants must share one key")
        check(GitHubService.normalizePRURL(variants[1]) == variants[0], "normalize must keep case and drop sub-pages")
        check(GitHubService.normalizePRURL("not a url") == "not a url", "unparseable URLs pass through unchanged")

        // 3. Whole-key title match.
        check(!GitHubService.titleMentions("[DATA-8332] x", key: "DATA-833"), "DATA-833 must not match DATA-8332")
        check(GitHubService.titleMentions("[data-833] x", key: "DATA-833"), "match is case-insensitive")
        check(!GitHubService.titleMentions("XDATA-833 x", key: "DATA-833"), "no match inside a longer word")

        // 4. Owner resolution: prefix map, then default.
        let settings = AppSettings(githubOwner: "Default-Org", githubOwners: AppSettings.parseProjectMap("data = Data-Org\nbad line").orgs)
        check(settings.githubOwner(forTicketKey: "DATA-1") == "Data-Org", "mapped prefix must win")
        check(settings.githubOwner(forTicketKey: "API-1") == "Default-Org", "unmapped prefix uses default")

        // 4b. Project lines: site and org optional, either order; round trip is lossless.
        let projects = AppSettings.parseProjectMap("""
            DATA = acme.atlassian.net, Data-Org
            api = Health-Org, https://acme-labs.atlassian.net/
            OPS = acme.atlassian.net
            nothing here
            """)
        check(projects.orgs == ["DATA": "Data-Org", "API": "Health-Org"], "project lines: orgs")
        check(projects.sites == ["DATA": "acme.atlassian.net", "API": "acme-labs.atlassian.net", "OPS": "acme.atlassian.net"],
              "project lines: sites")
        let reparsed = AppSettings.parseProjectMap(AppSettings.formatProjectMap(orgs: projects.orgs, sites: projects.sites))
        check(reparsed.orgs == projects.orgs && reparsed.sites == projects.sites, "format → parse must lose nothing")

        // 4c. Jira site: prefix map, then base URL host, then none. Links follow the site.
        let jira = AppSettings(jiraBaseURL: "https://acme.atlassian.net/", jiraSites: ["API": "acme-labs.atlassian.net"])
        check(jira.jiraSite(forTicketKey: "API-1") == "acme-labs.atlassian.net", "mapped Jira site must win")
        check(jira.jiraSite(forTicketKey: "OPS-1") == "acme.atlassian.net", "unmapped prefix uses base URL host")
        check(AppSettings().jiraSite(forTicketKey: "OPS-1") == nil, "no site configured → no switch")
        check(jira.browseURL(for: "API-1")?.absoluteString == "https://acme-labs.atlassian.net/browse/API-1",
              "link uses the prefix's site")
        check(jira.browseURL(for: "OPS-1")?.absoluteString == "https://acme.atlassian.net/browse/OPS-1",
              "link falls back to base URL")

        // 4d. Site gate: overlapping fetches never cross sites; retry only after a skipped switch.
        check(waitFor { await siteGateCheck() }, "site gate")

        // 5. settings.json from before the prefix map still decodes.
        let oldSettings = #"{"pollIntervalMinutes":5,"notificationsEnabled":true,"githubOwner":"X"}"#
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(oldSettings.utf8))
        check(decoded?.githubOwner == "X" && decoded?.githubOwners == nil && decoded?.jiraSites == nil,
              "old settings.json must decode")

        // 6. Tickets saved before searchPRURLs/ssoBlockedOrg still decode, then migrate.
        let old = WatchedTicket(ticketKey: "DATA-1", knownPRURLs: ["https://github.com/Org/Repo/pull/5#discussion_r9"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? encoder.encode([old]),
              let json = String(data: data, encoding: .utf8),
              !json.contains("searchPRURLs"),
              let loaded = try? decoder.decode([WatchedTicket].self, from: data) else {
            fail("old tickets.json must decode")
        }
        check(TicketStore.migratePRURLs(loaded).first?.knownPRURLs == ["https://github.com/Org/Repo/pull/5"],
              "migration must canonicalize knownPRURLs")

        print("TR_SELFCHECK: all checks passed")
        exit(0)
    }

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    /// Run an async check to completion from this synchronous launch path.
    /// Safe to block the main thread: the check never touches the main actor.
    private static func waitFor(_ check: @escaping @Sendable () async -> Bool) -> Bool {
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await check()
            done.signal()
        }
        done.wait()
        return box.value
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("TR_SELFCHECK FAILED: \(message)\n".utf8))
        exit(1)
    }
}

// File-level on purpose: nothing here may inherit DebugSelfCheck's @MainActor,
// because waitFor blocks the main thread while this runs.

/// Fake acli: `active` is its global site; switching takes time, so an
/// unserialized gate lets another fetch run mid-switch.
private actor FakeACLI {
    var active: String?
    var switches = 0
    var crossed = false

    func switchTo(_ site: String) async {
        active = nil
        try? await Task.sleep(nanoseconds: 2_000_000)
        active = site
        switches += 1
    }

    func fetch(expecting site: String) async throws {
        try? await Task.sleep(nanoseconds: 2_000_000)
        if active != site {
            crossed = true
            throw ShellError.commandFailed(command: "acli", message: "", exitCode: 1, kind: .notFound)
        }
    }

    /// Simulates the user switching acli in a terminal behind the gate.
    func externallySwitch(to site: String) { active = site }
}

private func siteGateCheck() async -> Bool {
    let gate = JiraSiteGate()
    let fake = FakeACLI()
    let retryable: (Error) -> Bool = { ($0 as? ShellError)?.kind == .notFound }

    // Overlapping fetches on alternating sites must never see the wrong site.
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<12 {
            let site = i.isMultiple(of: 2) ? "a.atlassian.net" : "b.atlassian.net"
            group.addTask {
                _ = try? await gate.run(site: site, switchSite: { await fake.switchTo($0) }, retryable: { _ in false }) {
                    try await fake.fetch(expecting: site)
                }
            }
        }
    }
    guard await !fake.crossed else { return false }

    func fetchB() async -> Bool {
        (try? await gate.run(site: "b.atlassian.net", switchSite: { await fake.switchTo($0) }, retryable: retryable) {
            try await fake.fetch(expecting: "b.atlassian.net")
        }) != nil
    }

    // Same site twice in a row → the second fetch does not switch.
    guard await fetchB() else { return false }
    let switches = await fake.switches
    guard await fetchB(), await fake.switches == switches else { return false }

    // Someone switched acli behind the gate → the skipped switch is retried once.
    await fake.externallySwitch(to: "other.atlassian.net")
    return await fetchB()
}
#endif
