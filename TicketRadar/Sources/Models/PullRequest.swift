import Foundation

enum PRState: String, Codable, Equatable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"
}

enum CIStatus: Codable, Equatable {
    case unknown
    case passing
    case failing
    case pending
    case mixed(passed: Int, total: Int)

    var displayText: String {
        switch self {
        case .unknown: return "--"
        case .passing: return "All green"
        case .failing: return "Failing"
        case .pending: return "Pending"
        case .mixed(let passed, let total): return "\(passed)/\(total) pass"
        }
    }
}

struct ReviewComment: Identifiable, Codable, Equatable {
    let id: UUID
    var author: String
    var reviewState: String
    var body: String

    init(id: UUID = UUID(), author: String, reviewState: String, body: String) {
        self.id = id
        self.author = author
        self.reviewState = reviewState
        self.body = body
    }
}

struct PullRequest: Identifiable, Codable, Equatable {
    let id: UUID
    var url: String
    var repository: String
    var number: Int
    var title: String
    var state: PRState
    var reviewDecision: String?
    var totalThreads: Int
    var unresolvedThreads: Int
    var ciStatus: CIStatus
    var mergeStatus: String?
    var comments: [ReviewComment]
    /// When the PR was opened.
    var createdAt: Date?
    /// When the PR was merged (nil unless merged).
    var mergedAt: Date?
    /// When the PR was closed without merging (nil unless closed).
    var closedAt: Date?
    /// Timestamp of the first review activity from a non-author, non-bot account.
    var firstReviewAt: Date?

    init(
        id: UUID = UUID(),
        url: String,
        repository: String,
        number: Int,
        title: String,
        state: PRState = .open,
        reviewDecision: String? = nil,
        totalThreads: Int = 0,
        unresolvedThreads: Int = 0,
        ciStatus: CIStatus = .unknown,
        mergeStatus: String? = nil,
        comments: [ReviewComment] = [],
        createdAt: Date? = nil,
        mergedAt: Date? = nil,
        closedAt: Date? = nil,
        firstReviewAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.repository = repository
        self.number = number
        self.title = title
        self.state = state
        self.reviewDecision = reviewDecision
        self.totalThreads = totalThreads
        self.unresolvedThreads = unresolvedThreads
        self.ciStatus = ciStatus
        self.mergeStatus = mergeStatus
        self.comments = comments
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.firstReviewAt = firstReviewAt
    }

    var isActionable: Bool {
        state == .open && (
            reviewDecision == "CHANGES_REQUESTED" ||
            unresolvedThreads > 0 ||
            ciStatus == .failing
        )
    }

    // MARK: - Timing

    /// The reference end time for measuring how long the PR was open:
    /// merge time if merged, close time if closed, otherwise "now".
    var endReference: Date {
        switch state {
        case .merged: return mergedAt ?? Date()
        case .closed: return closedAt ?? Date()
        case .open: return Date()
        }
    }

    /// How long the PR has been (or was) open, in seconds.
    var openDuration: TimeInterval? {
        guard let createdAt else { return nil }
        return endReference.timeIntervalSince(createdAt)
    }

    /// Compact age string, e.g. "3d", "5h", "<1h", or "--" when unknown.
    var openedAgeText: String {
        guard let openDuration else { return "--" }
        return Self.compactDuration(openDuration)
    }

    /// Whether the PR is still awaiting its first review (open with no review activity yet).
    var isWaitingForReview: Bool {
        state == .open && firstReviewAt == nil
    }

    /// Time from open until the first review activity.
    /// - Frozen value once a review arrived.
    /// - Live "…"-suffixed value while an open PR is still waiting.
    /// - "none" for merged/closed PRs that never got a review.
    /// - "--" when the open time is unknown.
    var reviewWaitText: String {
        guard let createdAt else { return "--" }
        if let firstReviewAt {
            return Self.compactDuration(firstReviewAt.timeIntervalSince(createdAt))
        }
        if state == .open {
            return Self.compactDuration(Date().timeIntervalSince(createdAt)) + "…"
        }
        return "none"
    }

    /// Formats a duration into a compact unit string.
    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let minutes = s / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return "\(Int(days))d" }
        if hours >= 1 { return "\(Int(hours))h" }
        if minutes >= 1 { return "\(Int(minutes))m" }
        return "<1m"
    }
}
