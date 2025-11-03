import Foundation

public struct DiagnosticExecutionResult {
    public let suggestion: DiagnosticSuggestion
    public let didLaunch: Bool
    public let exitCode: Int32?
    public let stdout: String
    public let stderr: String
    public let artifactURL: URL?
}

enum DiagnosticExecutor {
    static func run(suggestion: DiagnosticSuggestion, environment: [String: String] = [:]) -> DiagnosticExecutionResult {
        var stdoutData = Data()
        var stderrData = Data()

        guard !suggestion.command.isEmpty else {
            return DiagnosticExecutionResult(suggestion: suggestion, didLaunch: false, exitCode: nil, stdout: "", stderr: "", artifactURL: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", suggestion.command]
        if !environment.isEmpty {
            process.environment = Foundation.ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return DiagnosticExecutionResult(
                suggestion: suggestion,
                didLaunch: false,
                exitCode: nil,
                stdout: "",
                stderr: String(describing: error),
                artifactURL: nil
            )
        }

        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        var artifactURL: URL? = nil
        if let artifactPath = suggestion.artifactPath {
            let expanded = NSString(string: artifactPath).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: url.path) {
                artifactURL = url
            }
        }

        return DiagnosticExecutionResult(
            suggestion: suggestion,
            didLaunch: true,
            exitCode: process.terminationStatus,
            stdout: stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
            artifactURL: artifactURL
        )
    }
}
