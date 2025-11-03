import Foundation

public struct DiagnosticSuggestion: Codable, Equatable {
    public let title: String
    public let command: String
    public let note: String?
    public let artifactPath: String?

    public init(title: String, command: String, note: String?, artifactPath: String?) {
        self.title = title
        self.command = command
        self.note = note
        self.artifactPath = artifactPath
    }
}

public enum RuntimeKind: String {
    case chrome
    case electron
    case node
    case safari
    case xcode
    case webkit
    case python
    case java
    case ruby
    case go
    case docker
    case postgres
    case mysql
    case unknown
}

public enum RuntimeDiagnostics {
    public static func suggestions(pid: Int32, name: String, executablePath: String?) -> [DiagnosticSuggestion] {
        let runtime = identifyRuntime(name: name, executablePath: executablePath)
        switch runtime {
        case .chrome:
            return chromeSuggestions(pid: pid)
        case .electron:
            return electronSuggestions(pid: pid)
        case .node:
            return nodeSuggestions(pid: pid)
        case .safari, .webkit:
            return safariSuggestions(pid: pid)
        case .xcode:
            return xcodeSuggestions(pid: pid)
        case .python:
            return pythonSuggestions(pid: pid)
        case .java:
            return javaSuggestions(pid: pid)
        case .ruby:
            return rubySuggestions(pid: pid)
        case .go:
            return goSuggestions(pid: pid)
        case .docker:
            return dockerSuggestions(pid: pid)
        case .postgres:
            return postgresSuggestions(pid: pid)
        case .mysql:
            return mysqlSuggestions(pid: pid)
        case .unknown:
            return defaultSuggestions(pid: pid)
        }
    }

    private static func identifyRuntime(name: String, executablePath: String?) -> RuntimeKind {
        let lowerName = name.lowercased()
        let lowerPath = executablePath?.lowercased() ?? ""

        if lowerName.contains("chrome") || lowerPath.contains("google chrome") {
            return .chrome
        }
        if lowerName.contains("electron") || lowerPath.contains("electron") {
            return .electron
        }
        if lowerName == "node" || lowerName.contains("node") {
            return .node
        }
        if lowerName.contains("python") || lowerPath.contains("python") {
            return .python
        }
        if lowerName.contains("java") || lowerPath.contains("java") {
            return .java
        }
        if lowerName.contains("ruby") || lowerPath.contains("ruby") {
            return .ruby
        }
        if lowerName.contains("go") || lowerPath.contains("golang") || lowerPath.contains("/go/") {
            return .go
        }
        if lowerName.contains("safari") || lowerPath.contains("safari") {
            return .safari
        }
        if lowerName.contains("webkit") {
            return .webkit
        }
        if lowerName.contains("xcode") || lowerPath.contains("xcode") {
            return .xcode
        }
        if lowerName.contains("docker") || lowerName.contains("containerd") || lowerPath.contains("docker") {
            return .docker
        }
        if lowerName.contains("postgres") || lowerName.contains("postgre") || lowerPath.contains("postgres") {
            return .postgres
        }
        if lowerName.contains("mysqld") || lowerName == "mysql" || lowerPath.contains("mysql") {
            return .mysql
        }

        return .unknown
    }

    private static func chromeSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let heapDump = DiagnosticSuggestion(
            title: "Trigger V8 heap snapshot",
            command: "kill -USR2 \(pid)",
            note: "Chrome/Electron renderers generate a heap snapshot in the profile directory upon SIGUSR2.",
            artifactPath: nil
        )

        let tracing = DiagnosticSuggestion(
            title: "Capture Chrome tracing session",
            command: "open -g 'chrome://tracing'",
            note: "Record memory timeline to correlate leak growth with events.",
            artifactPath: nil
        )

        return [heapDump, tracing]
    }

    private static func electronSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let heapDump = DiagnosticSuggestion(
            title: "Capture Electron heap snapshot",
            command: "kill -USR2 \(pid)",
            note: "Electron/Node processes emit a V8 heap dump in the app folder when sent SIGUSR2.",
            artifactPath: nil
        )

        let chromiumSample = DiagnosticSuggestion(
            title: "Collect Chromium sample",
            command: "/usr/bin/sample \(pid) 10 -file ~/MemoryWatch/samples/electron_\(pid)_sample.txt",
            note: "Sample threads for 10 seconds to correlate spikes with renderer activity.",
            artifactPath: "~/MemoryWatch/samples/electron_\(pid)_sample.txt"
        )

        return [heapDump, chromiumSample]
    }

    private static func nodeSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let inspector = DiagnosticSuggestion(
            title: "Attach Node inspector",
            command: "kill -USR1 \(pid)",
            note: "Enables the inspector; attach via chrome://inspect for heap profiling.",
            artifactPath: nil
        )

        let mallocHistory = DiagnosticSuggestion(
            title: "Dump malloc history",
            command: "/usr/bin/malloc_history \(pid) > ~/MemoryWatch/samples/node_\(pid)_malloc.txt",
            note: "Capture objective-C allocation sites for native add-ons.",
            artifactPath: "~/MemoryWatch/samples/node_\(pid)_malloc.txt"
        )

        return [inspector, mallocHistory]
    }

    private static func safariSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let sample = DiagnosticSuggestion(
            title: "Sample Safari process",
            command: "/usr/bin/sample \(pid) 10 -file ~/MemoryWatch/samples/safari_\(pid)_sample.txt",
            note: "Use alongside Safari's Develop > Show Web Inspector > Timelines for JS heap view.",
            artifactPath: "~/MemoryWatch/samples/safari_\(pid)_sample.txt"
        )

        let leaksRun = DiagnosticSuggestion(
            title: "Run leaks tool",
            command: "/usr/bin/leaks \(pid) > ~/MemoryWatch/samples/safari_\(pid)_leaks.txt",
            note: "Look for persistent CFType or ObjC class growth.",
            artifactPath: "~/MemoryWatch/samples/safari_\(pid)_leaks.txt"
        )

        return [sample, leaksRun]
    }

    private static func xcodeSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let allocations = DiagnosticSuggestion(
            title: "Record Allocations trace",
            command: "xcrun xctrace record --template 'Allocations' --output ~/MemoryWatch/samples/xcode_alloc_\(pid).trace --attach \(pid) --time-limit 60",
            note: "Collect a 60s allocation profile; inspect in Instruments to pinpoint growth.",
            artifactPath: "~/MemoryWatch/samples/xcode_alloc_\(pid).trace"
        )

        return [allocations]
    }

    private static func pythonSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let tracemalloc = DiagnosticSuggestion(
            title: "Capture tracemalloc snapshot",
            command: "python3 - <<'PY'\nimport tracemalloc, os\ntracemalloc.start()\nprint(tracemalloc.take_snapshot().statistics('lineno')[:10])\nPY",
            note: "Run inside the target virtualenv to inspect top allocating lines.",
            artifactPath: nil
        )

        let pyspy = DiagnosticSuggestion(
            title: "Dump heap via py-spy",
            command: "py-spy dump --pid \(pid) --output ~/MemoryWatch/samples/python_\(pid)_pyspy.txt",
            note: "Requires py-spy; captures live stack and allocator stats without stopping the process.",
            artifactPath: "~/MemoryWatch/samples/python_\(pid)_pyspy.txt"
        )

        return [pyspy, tracemalloc]
    }

    private static func javaSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let jcmd = DiagnosticSuggestion(
            title: "Inspect native memory",
            command: "jcmd \(pid) VM.native_memory summary > ~/MemoryWatch/samples/java_\(pid)_nm.txt",
            note: "Requires JDK tools; shows Java heap vs native allocations.",
            artifactPath: "~/MemoryWatch/samples/java_\(pid)_nm.txt"
        )

        let jmap = DiagnosticSuggestion(
            title: "Capture heap histogram",
            command: "jmap -histo:live \(pid) > ~/MemoryWatch/samples/java_\(pid)_histo.txt",
            note: "Identifies leaking classes and instance counts.",
            artifactPath: "~/MemoryWatch/samples/java_\(pid)_histo.txt"
        )

        return [jcmd, jmap]
    }

    private static func rubySuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let rbtrace = DiagnosticSuggestion(
            title: "Attach rbtrace",
            command: "rbtrace -p \(pid) --firehose > ~/MemoryWatch/samples/ruby_\(pid)_rbtrace.log",
            note: "Streams allocation events if rbtrace gem is installed.",
            artifactPath: "~/MemoryWatch/samples/ruby_\(pid)_rbtrace.log"
        )

        let gcStat = DiagnosticSuggestion(
            title: "Dump GC statistics",
            command: "kill -INFO \(pid)",
            note: "Ruby prints GC stats to stderr; useful for identifying retained objects.",
            artifactPath: nil
        )

        return [gcStat, rbtrace]
    }

    private static func goSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let pprofSignal = DiagnosticSuggestion(
            title: "Emit Go pprof dump",
            command: "kill -USR1 \(pid)",
            note: "Go runtime writes heap/CPU profiles to stderr when built with pprof support.",
            artifactPath: nil
        )

        let pprofHTTP = DiagnosticSuggestion(
            title: "Fetch heap profile",
            command: "curl -o ~/MemoryWatch/samples/go_\(pid)_heap.pprof http://127.0.0.1:6060/debug/pprof/heap",
            note: "Requires net/http/pprof listener; inspect with go tool pprof.",
            artifactPath: "~/MemoryWatch/samples/go_\(pid)_heap.pprof"
        )

        return [pprofSignal, pprofHTTP]
    }

    private static func dockerSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let stats = DiagnosticSuggestion(
            title: "Inspect container memory",
            command: "docker stats --no-stream",
            note: "Find containers with runaway RSS driving the daemon.",
            artifactPath: nil
        )

        let inspect = DiagnosticSuggestion(
            title: "Check container limits",
            command: "docker inspect --format '{{.Name}} - MemLimit={{.HostConfig.Memory}}' $(docker ps -q)",
            note: "Ensure containers have memory limits to avoid host pressure.",
            artifactPath: nil
        )

        return [stats, inspect]
    }

    private static func postgresSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let activity = DiagnosticSuggestion(
            title: "View top backend memory",
            command: "psql -c \"SELECT pid, application_name, memory_usage FROM pg_stat_activity\"",
            note: "Requires pg_stat_activity extension exposing memory_usage.",
            artifactPath: nil
        )

        let sharedBuffers = DiagnosticSuggestion(
            title: "Summarise shared buffers",
            command: "psql -c \"SELECT pg_size_pretty(sum(pg_column_size(*))) FROM pg_buffercache;\"",
            note: "Identify relations monopolising shared buffers (needs pg_buffercache).",
            artifactPath: nil
        )

        return [activity, sharedBuffers]
    }

    private static func mysqlSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let status = DiagnosticSuggestion(
            title: "Check InnoDB memory stats",
            command: "mysql -e \"SHOW ENGINE INNODB STATUS\" > ~/MemoryWatch/samples/mysql_innodb_status.txt",
            note: "Highlights buffer pool usage and long-running transactions.",
            artifactPath: "~/MemoryWatch/samples/mysql_innodb_status.txt"
        )

        let performanceSchema = DiagnosticSuggestion(
            title: "Query performance schema memory",
            command: "mysql -e \"SELECT EVENT_NAME, CURRENT_NUMBER_OF_BYTES_USED FROM performance_schema.memory_summary_global_by_event_name ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC LIMIT 10;\"",
            note: "Requires performance_schema enabled.",
            artifactPath: nil
        )

        return [status, performanceSchema]
    }

    private static func defaultSuggestions(pid: Int32) -> [DiagnosticSuggestion] {
        let sample = DiagnosticSuggestion(
            title: "Collect sample",
            command: "/usr/bin/sample \(pid) 10 -file ~/MemoryWatch/samples/process_\(pid)_sample.txt",
            note: "Baseline stack capture for the top process.",
            artifactPath: "~/MemoryWatch/samples/process_\(pid)_sample.txt"
        )

        let leaksRun = DiagnosticSuggestion(
            title: "Run leaks",
            command: "/usr/bin/leaks \(pid) > ~/MemoryWatch/samples/process_\(pid)_leaks.txt",
            note: "Check for retain cycles or CF leaks.",
            artifactPath: "~/MemoryWatch/samples/process_\(pid)_leaks.txt"
        )

        return [sample, leaksRun]
    }
}
