import Foundation
import ArgumentParser
import MemoryWatchCore

@main
struct MemoryWatchCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memwatch",
        abstract: "macOS Memory Monitoring & Leak Detection",
        version: "1.0",
        subcommands: [
            MemoryWatchCore.SnapshotCommand.self,
            MemoryWatchCore.StatusCommand.self,
            MemoryWatchCore.DaemonCommand.self,
            MemoryWatchCore.ReportCommand.self,
            MemoryWatchCore.SuspectsCommand.self,
            MemoryWatchCore.IOCommand.self,
            MemoryWatchCore.DanglingFilesCommand.self,
            MemoryWatchCore.PortsCommand.self,
            MemoryWatchCore.CheckPortCommand.self,
            MemoryWatchCore.FindFreePortCommand.self,
            MemoryWatchCore.KillCommand.self,
            MemoryWatchCore.ForceKillCommand.self,
            MemoryWatchCore.KillPatternCommand.self,
            MemoryWatchCore.InteractiveKillCommand.self,
            MemoryWatchCore.NotificationsCommand.self,
            MemoryWatchCore.HelpCommand.self,
            MemoryWatchCore.DiagnosticsCommand.self
        ],
        defaultSubcommand: MemoryWatchCore.SnapshotCommand.self
    )
}
