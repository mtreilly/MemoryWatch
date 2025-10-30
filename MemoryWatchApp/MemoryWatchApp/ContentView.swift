import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject var memoryMonitor: MemoryMonitor
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            OverviewView()
                .tabItem {
                    Label("Overview", systemImage: "chart.bar.fill")
                }
                .tag(0)

            ProcessListView()
                .tabItem {
                    Label("Processes", systemImage: "list.bullet")
                }
                .tag(1)

            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: "exclamationmark.triangle.fill")
                }
                .tag(2)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct OverviewView: View {
    @EnvironmentObject var memoryMonitor: MemoryMonitor

    var body: some View {
        VStack(spacing: 20) {
            // System Memory
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("System Memory")
                            .font(.headline)
                        Spacer()
                        Text(memoryMonitor.systemMemory.pressure)
                            .foregroundColor(pressureColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(pressureColor.opacity(0.2))
                            .cornerRadius(6)
                    }

                    HStack {
                        VStack(alignment: .leading) {
                            Text("Total: \(String(format: "%.1f", memoryMonitor.systemMemory.totalGB)) GB")
                            Text("Used: \(String(format: "%.1f", memoryMonitor.systemMemory.usedGB)) GB")
                            Text("Free: \(String(format: "%.1f", memoryMonitor.systemMemory.freeGB)) GB")
                        }
                        .font(.system(.body, design: .monospaced))

                        Spacer()

                        CircularProgressView(
                            progress: (100 - memoryMonitor.systemMemory.freePct) / 100,
                            color: pressureColor
                        )
                        .frame(width: 100, height: 100)
                    }
                }
                .padding()
            }

            // Swap Usage
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Swap Usage")
                        .font(.headline)

                    HStack {
                        VStack(alignment: .leading) {
                            Text("Used: \(String(format: "%.0f", memoryMonitor.swapInfo.usedMB)) MB")
                            Text("Total: \(String(format: "%.0f", memoryMonitor.swapInfo.totalMB)) MB")
                            Text("Free: \(String(format: "%.1f", memoryMonitor.swapInfo.freePct))%")
                        }
                        .font(.system(.body, design: .monospaced))

                        Spacer()

                        if memoryMonitor.swapInfo.usedMB > 1024 {
                            VStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.largeTitle)
                                Text("High swap usage")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                .padding()
            }

            // Top Processes
            GroupBox {
                VStack(alignment: .leading) {
                    Text("Top Memory Consumers")
                        .font(.headline)
                        .padding(.bottom, 8)

                    ForEach(memoryMonitor.processes.prefix(5)) { process in
                        HStack {
                            if process.isPotentialLeak {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }

                            Text(process.name)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("\(String(format: "%.0f", process.memoryMB)) MB")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 100, alignment: .trailing)

                            if process.growthMB > 0 {
                                Text("+\(String(format: "%.0f", process.growthMB)) MB")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .frame(width: 80, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }

            Spacer()
        }
        .padding()
    }

    private var pressureColor: Color {
        switch memoryMonitor.systemMemory.pressure {
        case "Normal": return .green
        case "Warning": return .orange
        case "Critical": return .red
        default: return .gray
        }
    }
}

struct ProcessListView: View {
    @EnvironmentObject var memoryMonitor: MemoryMonitor
    @State private var searchText = ""

    var filteredProcesses: [ProcessInfo] {
        if searchText.isEmpty {
            return memoryMonitor.processes
        }
        return memoryMonitor.processes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search processes...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()

            Table(filteredProcesses) {
                TableColumn("PID") { process in
                    Text("\(process.id)")
                        .font(.system(.body, design: .monospaced))
                }
                .width(60)

                TableColumn("Name") { process in
                    HStack {
                        if process.isPotentialLeak {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        }
                        Text(process.name)
                    }
                }

                TableColumn("Memory") { process in
                    Text("\(String(format: "%.1f", process.memoryMB)) MB")
                        .font(.system(.body, design: .monospaced))
                }
                .width(120)

                TableColumn("% Memory") { process in
                    Text(String(format: "%.1f%%", process.percentMemory))
                        .font(.system(.body, design: .monospaced))
                }
                .width(100)

                TableColumn("Growth") { process in
                    if process.growthMB > 0 {
                        Text("+\(String(format: "%.0f", process.growthMB)) MB")
                            .foregroundColor(.orange)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("-")
                            .foregroundColor(.secondary)
                    }
                }
                .width(100)
            }
        }
    }
}

struct AlertsView: View {
    @EnvironmentObject var memoryMonitor: MemoryMonitor

    var body: some View {
        VStack {
            if memoryMonitor.alerts.isEmpty {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("No alerts")
                        .font(.title2)
                        .padding()
                }
            } else {
                List {
                    ForEach(memoryMonitor.alerts.indices, id: \.self) { index in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(memoryMonitor.alerts[index])
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Alerts")
        .toolbar {
            Button("Clear") {
                memoryMonitor.alerts.removeAll()
            }
            .disabled(memoryMonitor.alerts.isEmpty)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var memoryMonitor: MemoryMonitor

    var body: some View {
        VStack(alignment: .leading) {
            Text("Memory: \(String(format: "%.1f", memoryMonitor.systemMemory.usedGB))/\(String(format: "%.1f", memoryMonitor.systemMemory.totalGB)) GB")
            Text("Swap: \(String(format: "%.0f", memoryMonitor.swapInfo.usedMB)) MB")

            Divider()

            Button("Check for Leaks") {
                memoryMonitor.checkLeaks()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
    }
}

struct CircularProgressView: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 12)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: progress)

            Text("\(Int(progress * 100))%")
                .font(.title2)
                .bold()
        }
    }
}
