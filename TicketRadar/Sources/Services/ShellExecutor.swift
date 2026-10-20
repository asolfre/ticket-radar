import Foundation

/// Result of a shell command execution
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// Async wrapper around Process for executing CLI tools (acli, gh)
/// Handles PATH resolution for GUI apps that don't inherit terminal environment.
enum ShellExecutor {

    /// Thread-safe data accumulator for pipe output
    private final class DataBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func consume() -> Data {
            lock.lock()
            let result = data
            lock.unlock()
            return result
        }
    }

    /// Execute a shell command asynchronously
    /// - Parameters:
    ///   - command: The command to run (e.g. "acli", "gh")
    ///   - arguments: Command arguments
    ///   - customPath: Optional PATH override from settings
    /// - Returns: ShellResult with stdout, stderr, and exit code
    static func run(
        command: String,
        arguments: [String],
        customPath: String? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            // Use /usr/bin/env to resolve the command in PATH
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Build environment with proper PATH for GUI apps
            var env = ProcessInfo.processInfo.environment
            let resolvedPath = buildPath(customPath: customPath, existingPath: env["PATH"])
            env["PATH"] = resolvedPath
            process.environment = env

            // Accumulate pipe data on background threads BEFORE process terminates.
            // Reading in terminationHandler causes deadlocks when output exceeds
            // the 64KB pipe buffer (process blocks on write -> never terminates ->
            // handler never fires).
            let stdoutBuffer = DataBuffer()
            let stderrBuffer = DataBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(chunk)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(chunk)
                }
            }

            process.terminationHandler = { process in
                let result = ShellResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutBuffer.consume(), encoding: .utf8) ?? "",
                    stderr: String(data: stderrBuffer.consume(), encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ShellError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Convenience: run and require success (throws on non-zero exit)
    static func runOrThrow(
        command: String,
        arguments: [String],
        customPath: String? = nil
    ) async throws -> String {
        let result = try await run(command: command, arguments: arguments, customPath: customPath)
        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = classifyError(command: command, stderr: stderr, exitCode: result.exitCode)
            throw ShellError.commandFailed(
                command: command,
                message: message,
                exitCode: result.exitCode,
                kind: ShellError.FailureKind(stderr: stderr)
            )
        }
        return result.stdout
    }

    /// Provide user-friendly error messages for common failures
    private static func classifyError(command: String, stderr: String, exitCode: Int32) -> String {
        let lower = stderr.lowercased()

        // GitHub org SSO (SAML / conditional access). Checked before the generic
        // auth branch: the message contains "token", which would otherwise turn
        // it into "run gh auth login" — the wrong fix. Keep the word "SAML" in
        // the result; TicketStore detects SSO failures by it.
        if lower.contains("saml") {
            return "GitHub SAML single sign-on required: \(stderr.prefix(200))"
        }
        // Command not found
        if exitCode == 127 || lower.contains("not found") || lower.contains("no such file") {
            return "\(command) not found. Install it or set the PATH in Settings."
        }

        // Authentication / authorization errors
        if lower.contains("unauthorized") || lower.contains("401") || lower.contains("authentication") ||
           lower.contains("login") || lower.contains("token") || lower.contains("credential") {
            return "\(command) authentication failed. Run '\(command) auth login' in a terminal."
        }

        // Network errors
        if lower.contains("network") || lower.contains("timeout") || lower.contains("could not resolve") ||
           lower.contains("connection refused") {
            return "Network error running \(command). Check your internet connection."
        }

        // Rate limiting
        if lower.contains("rate limit") || lower.contains("429") {
            return "Rate limited by API. Try again in a few minutes."
        }

        // Not found (ticket/PR doesn't exist)
        if lower.contains("not found") || lower.contains("404") || lower.contains("does not exist") {
            return "Resource not found: \(stderr.prefix(100))"
        }

        // Default: show the raw stderr (truncated)
        if stderr.isEmpty {
            return "Exit code \(exitCode)"
        }
        let truncated = stderr.count > 200 ? String(stderr.prefix(200)) + "..." : stderr
        return truncated
    }

    // MARK: - PATH Resolution

    /// Build a comprehensive PATH for GUI apps.
    /// macOS GUI apps don't inherit the user's shell PATH, so we add common locations.
    private static func buildPath(customPath: String?, existingPath: String?) -> String {
        var paths: [String] = []

        // User-configured override takes highest priority
        if let custom = customPath, !custom.isEmpty {
            paths.append(contentsOf: custom.components(separatedBy: ":"))
        }

        // Common locations for Homebrew-installed tools
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ])

        // User-local bins
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
        ])

        // Try to read additional paths from user's shell profile
        if let profilePaths = readPathFromShellProfile(home: home) {
            paths.append(contentsOf: profilePaths)
        }

        // Existing process PATH
        if let existing = existingPath {
            paths.append(contentsOf: existing.components(separatedBy: ":"))
        }

        // System defaults
        paths.append(contentsOf: [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ])

        // Deduplicate while preserving order
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Attempt to read PATH exports from ~/.zprofile or ~/.zshrc
    private static func readPathFromShellProfile(home: String) -> [String]? {
        let profilePaths = [
            "\(home)/.zprofile",
            "\(home)/.zshrc",
            "\(home)/.bash_profile",
            "\(home)/.profile",
        ]

        for profilePath in profilePaths {
            guard let content = try? String(contentsOfFile: profilePath, encoding: .utf8) else {
                continue
            }

            // Extract PATH additions from export statements
            var extractedPaths: [String] = []
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Match patterns like: export PATH="...:$PATH" or PATH=...:$PATH
                if trimmed.contains("PATH") && !trimmed.hasPrefix("#") {
                    // Extract path-like segments (absolute paths)
                    let segments = trimmed.components(separatedBy: CharacterSet(charactersIn: "=:\"'"))
                    for segment in segments {
                        let clean = segment.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "$HOME", with: home)
                            .replacingOccurrences(of: "~", with: home)
                        if clean.hasPrefix("/") && FileManager.default.fileExists(atPath: clean) {
                            extractedPaths.append(clean)
                        }
                    }
                }
            }

            if !extractedPaths.isEmpty {
                return extractedPaths
            }
        }
        return nil
    }
}

// MARK: - Errors

enum ShellError: LocalizedError {
    case launchFailed(String)
    case commandFailed(command: String, message: String, exitCode: Int32, kind: FailureKind = .other)

    /// Failure category taken from the raw stderr, before `classifyError`
    /// rewords it, so callers can branch without matching message text.
    enum FailureKind {
        case unauthorized
        case notFound
        case other

        init(stderr: String) {
            let lower = stderr.lowercased()
            if lower.contains("unauthorized") {
                self = .unauthorized
            } else if lower.contains("does not exist") || lower.contains("404") {
                self = .notFound
            } else {
                self = .other
            }
        }
    }

    var kind: FailureKind {
        if case .commandFailed(_, _, _, let kind) = self { return kind }
        return .other
    }

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Failed to launch process: \(reason)"
        case .commandFailed(let command, let message, let exitCode, _):
            return "\(command) failed (exit \(exitCode)): \(message)"
        }
    }
}
