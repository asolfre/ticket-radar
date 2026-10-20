import Foundation

/// Service for fetching PR status via the `gh` CLI tool
enum GitHubService {

    /// Fetch full PR details (status + reviews) for a given GitHub PR URL
    static func fetchPR(url prURL: String, customPath: String? = nil) async throws -> PullRequest {
        // Parse owner/repo/number from URL
        let parsed = try parsePRURL(prURL)

        // Run both queries in parallel
        async let statusResult = fetchPRStatus(url: prURL, customPath: customPath)
        async let reviewResult = fetchReviewData(
            owner: parsed.owner,
            repo: parsed.repo,
            number: parsed.number,
            customPath: customPath
        )

        let status = try await statusResult
        let reviews = try await reviewResult

        return PullRequest(
            url: prURL,
            repository: parsed.repo,
            number: parsed.number,
            title: status.title,
            state: status.state,
            reviewDecision: status.reviewDecision,
            totalThreads: reviews.totalThreads,
            unresolvedThreads: reviews.unresolvedThreads,
            ciStatus: status.ciStatus,
            mergeStatus: status.mergeStatus,
            comments: reviews.comments,
            createdAt: status.createdAt,
            mergedAt: status.mergedAt,
            closedAt: status.closedAt,
            firstReviewAt: reviews.firstReviewAt
        )
    }

    // MARK: - PR Discovery (gh search prs)

    /// Find PRs whose *title* mentions a ticket key, across every repo in an org.
    ///
    /// Complements Jira `inlineCard` discovery: it finds PRs that were opened but
    /// not yet smart-linked in the ticket description.
    ///
    /// Notes on the query:
    /// - `--match title` restricts matching to titles server-side. Without it the
    ///   search also matches bodies and comments and returns heavy noise.
    /// - The **bare** key is used, not `[KEY]`. Both `[KEY] Title` and `KEY Title`
    ///   conventions occur in practice and the bare key matches both.
    /// - `--state` is deliberately not passed: it only accepts `open|closed`, and
    ///   merged PRs are the common case for a completed ticket.
    ///
    /// GitHub tokenizes on the hyphen, so a title containing the key's parts
    /// separately could theoretically match. Results are therefore confirmed
    /// client-side against the literal key.
    ///
    /// - Returns: normalized PR URLs whose titles contain `ticketKey`.
    static func searchPRs(
        ticketKey: String,
        owner: String,
        customPath: String? = nil
    ) async throws -> [String] {
        let output = try await ShellExecutor.runOrThrow(
            command: "gh",
            arguments: [
                "search", "prs", ticketKey,
                "--owner", owner,
                "--match", "title",
                "--json", "url,title",
                "--limit", "50"
            ],
            customPath: customPath
        )

        guard let data = output.data(using: .utf8),
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.invalidResponse("Could not parse gh search prs JSON")
        }

        return results.compactMap { item in
            guard let url = item["url"] as? String,
                  let title = item["title"] as? String,
                  titleMentions(title, key: ticketKey) else {
                return nil
            }
            return normalizePRURL(url)
        }
    }

    /// Whether `title` contains `key` as a whole key: `DATA-833` matches
    /// `[data-833] x` but not `[DATA-8332] x` or `XDATA-833`.
    static func titleMentions(_ title: String, key: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: key) + "(?![0-9])"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Rebuild a PR URL as `https://github.com/{owner}/{repo}/pull/{n}`.
    ///
    /// Drops fragments, queries and sub-pages (`/files`, `/commits`), so
    /// `.../pull/126#discussion_r1` and `.../pull/126/files` both resolve to PR
    /// 126. Letter case is kept: `fetchPR` takes the displayed repository name
    /// from this URL. Compare with `prKey` instead.
    ///
    /// Unparseable input is returned unchanged. Already-canonical URLs come back
    /// byte-identical, so `knownPRURLs` from earlier versions still match.
    static func normalizePRURL(_ url: String) -> String {
        guard let parsed = try? parsePRURL(url) else { return url }
        return "https://github.com/\(parsed.owner)/\(parsed.repo)/pull/\(parsed.number)"
    }

    /// Case-insensitive identity of a PR, for deduplication and comparison.
    /// GitHub owner/repo names are case-insensitive, so Jira's `acme-x` and
    /// search's `Acme-X` are the same PR.
    static func prKey(_ url: String) -> String {
        normalizePRURL(url).lowercased()
    }

    /// Best-effort owner extraction from a GitHub PR URL, used when the user has
    /// not configured an organization in Settings.
    static func owner(fromPRURL url: String) -> String? {
        try? parsePRURL(url).owner
    }

    // MARK: - Date Parsing

    /// Shared ISO8601 parser for GitHub timestamps (e.g. "2026-06-12T10:30:00Z").
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String, !str.isEmpty else { return nil }
        return iso8601.date(from: str)
    }

    /// Fetch multiple PRs in parallel
    static func fetchPRs(urls: [String], customPath: String? = nil) async -> [Result<PullRequest, Error>] {
        await withTaskGroup(of: (Int, Result<PullRequest, Error>).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let pr = try await fetchPR(url: url, customPath: customPath)
                        return (index, .success(pr))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results = Array(repeating: Result<PullRequest, Error>.failure(GitHubError.unknown), count: urls.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }
    }

    // MARK: - PR Status (gh pr view)

    private struct PRStatus {
        let title: String
        let state: PRState
        let reviewDecision: String?
        let ciStatus: CIStatus
        let mergeStatus: String?
        let createdAt: Date?
        let mergedAt: Date?
        let closedAt: Date?
    }

    private static func fetchPRStatus(url: String, customPath: String?) async throws -> PRStatus {
        let output = try await ShellExecutor.runOrThrow(
            command: "gh",
            arguments: [
                "pr", "view", url,
                "--json", "title,state,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,createdAt,mergedAt,closedAt"
            ],
            customPath: customPath
        )

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse("Could not parse gh pr view JSON")
        }

        let title = json["title"] as? String ?? "Unknown PR"
        let stateStr = json["state"] as? String ?? "OPEN"
        let state = PRState(rawValue: stateStr) ?? .open
        let reviewDecision = json["reviewDecision"] as? String
        let mergeStateStatus = json["mergeStateStatus"] as? String

        // Parse CI status from statusCheckRollup
        let ciStatus = parseCIStatus(from: json["statusCheckRollup"])

        return PRStatus(
            title: title,
            state: state,
            reviewDecision: reviewDecision,
            ciStatus: ciStatus,
            mergeStatus: mergeStateStatus,
            createdAt: parseDate(json["createdAt"]),
            mergedAt: parseDate(json["mergedAt"]),
            closedAt: parseDate(json["closedAt"])
        )
    }

    private static func parseCIStatus(from rollup: Any?) -> CIStatus {
        guard let checks = rollup as? [[String: Any]], !checks.isEmpty else {
            return .unknown
        }

        var passed = 0
        var failed = 0
        var pending = 0

        for check in checks {
            let status = check["status"] as? String ?? ""
            let conclusion = check["conclusion"] as? String ?? ""

            if status != "COMPLETED" {
                pending += 1
            } else if conclusion == "SUCCESS" || conclusion == "NEUTRAL" || conclusion == "SKIPPED" {
                passed += 1
            } else {
                failed += 1
            }
        }

        let total = checks.count

        if pending > 0 {
            return .pending
        } else if failed == 0 {
            return .passing
        } else if passed == 0 {
            return .failing
        } else {
            return .mixed(passed: passed, total: total)
        }
    }

    // MARK: - Review Data (GraphQL)

    private struct ReviewData {
        let totalThreads: Int
        let unresolvedThreads: Int
        let comments: [ReviewComment]
        let firstReviewAt: Date?
    }

    private static func fetchReviewData(
        owner: String,
        repo: String,
        number: Int,
        customPath: String?
    ) async throws -> ReviewData {
        // Owner/repo/number are passed as typed GraphQL variables rather than
        // interpolated into the query string. `gh api graphql -F` infers types,
        // so `number` arrives as an Int.
        let query = """
        query($owner:String!, $name:String!, $number:Int!) {
          repository(owner:$owner, name:$name) {
            pullRequest(number:$number) {
              author { login }
              reviewThreads(first:100) { totalCount nodes { isResolved } }
              reviews(first:100) { nodes { author { login __typename } state body submittedAt } }
              comments(first:100) { nodes { author { login __typename } body createdAt } }
            }
          }
        }
        """

        let output = try await ShellExecutor.runOrThrow(
            command: "gh",
            arguments: [
                "api", "graphql",
                "-F", "owner=\(owner)",
                "-F", "name=\(repo)",
                "-F", "number=\(number)",
                "-f", "query=\(query)"
            ],
            customPath: customPath
        )

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse("Could not parse GraphQL response")
        }

        // Navigate: data.repository.pullRequest
        guard let dataObj = json["data"] as? [String: Any],
              let repoObj = dataObj["repository"] as? [String: Any],
              let prObj = repoObj["pullRequest"] as? [String: Any] else {
            throw GitHubError.invalidResponse("Unexpected GraphQL response structure")
        }

        // PR author login (used to exclude self-reviews from wait-time calc)
        let prAuthorLogin = (prObj["author"] as? [String: Any])?["login"] as? String

        // Review threads
        let threadsObj = prObj["reviewThreads"] as? [String: Any] ?? [:]
        let totalThreads = threadsObj["totalCount"] as? Int ?? 0
        let threadNodes = threadsObj["nodes"] as? [[String: Any]] ?? []
        let unresolvedThreads = threadNodes.filter { $0["isResolved"] as? Bool == false }.count

        // Reviews (with non-empty bodies)
        var comments: [ReviewComment] = []
        // Candidate timestamps for the first non-author, non-bot review activity.
        var reviewTimestamps: [Date] = []
        let reviewNodes = prObj["reviews"] as? [String: Any] ?? [:]
        let reviews = (reviewNodes["nodes"] as? [[String: Any]]) ?? []
        for review in reviews {
            let authorObj = review["author"] as? [String: Any]
            if isReviewerActivity(author: authorObj, prAuthorLogin: prAuthorLogin),
               let submitted = parseDate(review["submittedAt"]) {
                reviewTimestamps.append(submitted)
            }

            let body = review["body"] as? String ?? ""
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let author = authorObj?["login"] as? String ?? "unknown"
            let state = review["state"] as? String ?? "COMMENTED"
            comments.append(ReviewComment(author: author, reviewState: state, body: body))
        }

        // PR-level comments
        let commentNodes = prObj["comments"] as? [String: Any] ?? [:]
        let prComments = (commentNodes["nodes"] as? [[String: Any]]) ?? []
        for comment in prComments {
            let authorObj = comment["author"] as? [String: Any]
            if isReviewerActivity(author: authorObj, prAuthorLogin: prAuthorLogin),
               let created = parseDate(comment["createdAt"]) {
                reviewTimestamps.append(created)
            }

            let body = comment["body"] as? String ?? ""
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let author = authorObj?["login"] as? String ?? "unknown"
            comments.append(ReviewComment(author: author, reviewState: "COMMENT", body: body))
        }

        return ReviewData(
            totalThreads: totalThreads,
            unresolvedThreads: unresolvedThreads,
            comments: comments,
            firstReviewAt: reviewTimestamps.min()
        )
    }

    /// Whether an author counts as review activity: not a bot, and not the PR author.
    private static func isReviewerActivity(author: [String: Any]?, prAuthorLogin: String?) -> Bool {
        guard let author else { return false }
        if (author["__typename"] as? String) == "Bot" { return false }
        let login = author["login"] as? String
        if let login, let prAuthorLogin, login == prAuthorLogin { return false }
        return true
    }

    // MARK: - URL Parsing

    private struct ParsedPR {
        let owner: String
        let repo: String
        let number: Int
    }

    private static func parsePRURL(_ url: String) throws -> ParsedPR {
        // Expected: https://github.com/Owner/Repo/pull/123
        guard let urlObj = URL(string: url) else {
            throw GitHubError.invalidURL(url)
        }

        let components = urlObj.pathComponents
        // components: ["/", "Owner", "Repo", "pull", "123"]
        guard components.count >= 5,
              components[3] == "pull",
              let number = Int(components[4]) else {
            throw GitHubError.invalidURL(url)
        }

        return ParsedPR(owner: components[1], repo: components[2], number: number)
    }
}

// MARK: - Errors

enum GitHubError: LocalizedError {
    case invalidURL(String)
    case invalidResponse(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid GitHub PR URL: \(url)"
        case .invalidResponse(let detail):
            return "Invalid GitHub response: \(detail)"
        case .unknown:
            return "Unknown GitHub error"
        }
    }
}
