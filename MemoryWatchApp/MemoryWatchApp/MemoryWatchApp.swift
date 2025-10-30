import SwiftUI

@main
struct MemoryWatchApp: App {
    @StateObject private var memoryMonitor = MemoryMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(memoryMonitor)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Memory Leaks") {
                    memoryMonitor.checkLeaks()
                }
                .keyboardShortcut("L", modifiers: [.command])
            }
        }

        // Menu bar extra
        MenuBarExtra("Memory Watch", systemImage: "memorychip") {
            MenuBarView()
                .environmentObject(memoryMonitor)
        }
    }
}
