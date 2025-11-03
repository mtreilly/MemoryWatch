import Foundation
import Dispatch
#if canImport(ServiceManagement)
import ServiceManagement
#endif
import Darwin

@MainActor
final class DaemonController: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var launchAtLogin: Bool = false

    private var launchedProcess: Process?
    private let shouldAutoStart: Bool
    private var didBootstrap = false
    private let launchAgentURL: URL
    private let launchAgentIdentifier = "com.memorywatch.app.login"
    private var cachedExecutablePath: String?
    private let fileManager = FileManager.default

    init(autoStart: Bool = true) {
        shouldAutoStart = autoStart
        let agentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        launchAgentURL = agentsDir.appendingPathComponent("\(launchAgentIdentifier).plist")

        launchAtLogin = FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        NSLog("MemoryWatchMenuBar: Bootstrapping daemon controller")
        refreshStatus()

        if shouldAutoStart, !isRunning {
            startDaemon()
        }
    }

    func refreshStatus() {
        isRunning = isDaemonActive()
    }

    func startDaemon() {
        refreshStatus()
        guard !isRunning else { return }
        guard let executable = resolvedDaemonExecutable() else {
            NSLog("MemoryWatchMenuBar: Unable to locate `memwatch` CLI for daemon start.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["daemon"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.launchedProcess = nil
                self?.refreshStatus()
            }
        }

        do {
            try process.run()
            NSLog("MemoryWatchMenuBar: Launching daemon via \(executable)")
            launchedProcess = process
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshStatus()
            }
        } catch {
            NSLog("MemoryWatchMenuBar: Failed to start daemon - \(error.localizedDescription)")
        }
    }

    func stopDaemon() {
        if let process = launchedProcess, process.isRunning {
            process.terminate()
            launchedProcess = nil
        }

        _ = runShell("/usr/bin/env", arguments: ["pkill", "-f", "memwatch daemon"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshStatus()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            do {
                try installLaunchAgent()
                launchAtLogin = true
            } catch {
                launchAtLogin = false
                NSLog("MemoryWatchMenuBar: Failed to enable launch at login - \(error.localizedDescription)")
            }
        } else {
            removeLaunchAgent()
            launchAtLogin = false
        }
    }

    // MARK: - Private helpers

    private func resolvedDaemonExecutable() -> String? {
        if let cachedExecutablePath,
           fileManager.isExecutableFile(atPath: cachedExecutablePath) {
            return cachedExecutablePath
        }

        for candidate in executableCandidates() {
            if fileManager.isExecutableFile(atPath: candidate) {
                cachedExecutablePath = candidate
                return candidate
            }
        }

        cachedExecutablePath = nil
        return nil
    }

    private func executableCandidates() -> [String] {
        var candidates = bundleExecutableCandidates()

        let whichResult = runShell("/usr/bin/env", arguments: ["which", "memwatch"])
        if whichResult.status == 0 {
            let trimmed = whichResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(trimmed)
            }
        }

        return candidates
    }

    private func bundleExecutableCandidates() -> [String] {
        var candidates: Set<String> = []
        let bundle = Bundle.main

        if let resourceURL = bundle.url(forResource: "memwatch", withExtension: nil) {
            candidates.insert(resourceURL.path)
        }

        let bundleRoot = bundle.bundleURL
        let potentialPaths = [
            bundleRoot.appendingPathComponent("Contents/Resources/memwatch", isDirectory: false),
            bundleRoot.appendingPathComponent("Contents/MacOS/memwatch", isDirectory: false),
            bundleRoot.appendingPathComponent("Contents/SharedSupport/memwatch", isDirectory: false)
        ]

        for url in potentialPaths where fileManager.fileExists(atPath: url.path) {
            candidates.insert(url.path)
        }

        return Array(candidates)
    }

    private func isDaemonActive() -> Bool {
        runShell("/usr/bin/env", arguments: ["pgrep", "-f", "memwatch daemon"]).status == 0
    }

    private func installLaunchAgent() throws {
        let fm = FileManager.default
        let agentsDir = launchAgentURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: agentsDir.path) {
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true, attributes: nil)
        }

        guard let executableURL = Bundle.main.executableURL else {
            throw NSError(domain: "MemoryWatchMenuBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to resolve app executable path"])
        }

        let plist: [String: Any] = [
            "Label": launchAgentIdentifier,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)

        try loadLaunchAgent()
    }

    private func removeLaunchAgent() {
        unloadLaunchAgent()
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private func loadLaunchAgent() throws {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                NSLog("MemoryWatchMenuBar: Failed to register login item with SMAppService - \(error.localizedDescription)")
            }
        }
        #endif

        let domain = "gui/\(getuid())"
        let bootstrap = runShell("/bin/launchctl", arguments: ["bootstrap", domain, launchAgentURL.path])

        if bootstrap.status != 0 && !bootstrap.output.lowercased().contains("already") {
            throw NSError(domain: "MemoryWatchMenuBar",
                          code: Int(bootstrap.status),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }

        _ = runShell("/bin/launchctl", arguments: ["kickstart", "-k", "\(domain)/\(launchAgentIdentifier)"])
    }

    private func unloadLaunchAgent() {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                NSLog("MemoryWatchMenuBar: Failed to unregister login item with SMAppService - \(error.localizedDescription)")
            }
        }
        #endif

        let domain = "gui/\(getuid())"
        let identifier = "\(domain)/\(launchAgentIdentifier)"
        let result = runShell("/bin/launchctl", arguments: ["bootout", identifier])

        if result.status != 0 && !result.output.lowercased().contains("no such process") {
            NSLog("MemoryWatchMenuBar: launchctl bootout failed - \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func runShell(_ launchPath: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return (status: -1, output: "")
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (status: process.terminationStatus, output: output)
    }
}
