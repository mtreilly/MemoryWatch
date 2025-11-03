import XCTest
@testable import MemoryWatchCore

class ToolchainAdaptersTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
        tempDirectory = tempDir.appendingPathComponent("test_adapters_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testChromiumAdapterInitialization() {
        let adapter = ChromiumAdapter(workingDirectory: tempDirectory)
        XCTAssertEqual(adapter.runtime, .chrome)
    }

    func testXcodeAdapterInitialization() {
        let adapter = XcodeAdapter(workingDirectory: tempDirectory)
        XCTAssertEqual(adapter.runtime, .xcode)
    }

    func testNodeAdapterInitialization() {
        let adapter = NodeAdapter(workingDirectory: tempDirectory)
        XCTAssertEqual(adapter.runtime, .node)
    }

    func testChromiumAdapterDefaultWorkingDirectory() {
        let adapter = ChromiumAdapter()
        XCTAssertNotNil(adapter.runtime)
        XCTAssertEqual(adapter.runtime, .chrome)
    }

    func testXcodeAdapterDefaultWorkingDirectory() {
        let adapter = XcodeAdapter()
        XCTAssertNotNil(adapter.runtime)
        XCTAssertEqual(adapter.runtime, .xcode)
    }

    func testNodeAdapterDefaultWorkingDirectory() {
        let adapter = NodeAdapter()
        XCTAssertNotNil(adapter.runtime)
        XCTAssertEqual(adapter.runtime, .node)
    }

    func testChromiumAdapterCaptureArtifactCreatesDirectory() {
        let adapter = ChromiumAdapter(workingDirectory: tempDirectory)
        let artifactURL = adapter.captureArtifact(pid: 1234)

        // captureArtifact returns nil because we can't actually trigger heap dumps in tests,
        // but we verify the artifacts directory was created
        let artifactsDir = tempDirectory.appendingPathComponent("artifacts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactsDir.path))
    }

    func testXcodeAdapterCaptureArtifactCreatesDirectory() {
        let adapter = XcodeAdapter(workingDirectory: tempDirectory)
        let artifactURL = adapter.captureArtifact(pid: 1234)

        // capturArtifact may return nil in test environment, but directory should be created
        let artifactsDir = tempDirectory.appendingPathComponent("artifacts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactsDir.path))
    }

    func testNodeAdapterCaptureArtifactCreatesDirectory() {
        let adapter = NodeAdapter(workingDirectory: tempDirectory)
        let artifactURL = adapter.captureArtifact(pid: 1234)

        // captureArtifact returns nil, but directory should be created
        let artifactsDir = tempDirectory.appendingPathComponent("artifacts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactsDir.path))
    }

    func testChromiumAdapterAnalyzeArtifactWithValidJSON() {
        let adapter = ChromiumAdapter(workingDirectory: tempDirectory)

        // Create a minimal valid V8 heap dump JSON
        let heapDump: [String: Any] = [
            "snapshot": [
                "nodes": [0, 1, 2, 3]  // 4 values per node, so 1 object
            ]
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: heapDump)
        let artifactURL = tempDirectory.appendingPathComponent("test_heap.json")
        try! jsonData.write(to: artifactURL)

        let analysis = adapter.analyzeArtifact(url: artifactURL)

        XCTAssertNotNil(analysis)
        XCTAssertEqual(analysis?.runtime, "Chromium")
        XCTAssertEqual(analysis?.artifactType, "V8 Heap Dump")
        XCTAssertTrue(analysis?.keyFindings.contains { $0.contains("heap objects") } ?? false)
    }

    func testChromiumAdapterAnalyzeArtifactWithInvalidJSON() {
        let adapter = ChromiumAdapter(workingDirectory: tempDirectory)

        let invalidData = "not json".data(using: .utf8)!
        let artifactURL = tempDirectory.appendingPathComponent("invalid.json")
        try! invalidData.write(to: artifactURL)

        let analysis = adapter.analyzeArtifact(url: artifactURL)
        XCTAssertNil(analysis)
    }

    func testNodeAdapterAnalyzeArtifactDetectsLeakPatterns() {
        let adapter = NodeAdapter(workingDirectory: tempDirectory)

        // Create a heap snapshot with leak-suspicious strings
        let heapSnapshot: [String: Any] = [
            "nodes": [0, 1, 2, 3, 4, 5, 6],  // 7 fields per node
            "strings": ["Object", "detached", "node", "listener", "function", "closure"]
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: heapSnapshot)
        let artifactURL = tempDirectory.appendingPathComponent("test_heap.heapsnapshot")
        try! jsonData.write(to: artifactURL)

        let analysis = adapter.analyzeArtifact(url: artifactURL)

        XCTAssertNotNil(analysis)
        XCTAssertEqual(analysis?.runtime, "Node.js")
        XCTAssertFalse(analysis?.suspectedLeaks.isEmpty ?? true)
    }

    func testNodeAdapterAnalyzeArtifactNoLeakPatterns() {
        let adapter = NodeAdapter(workingDirectory: tempDirectory)

        // Create a heap snapshot with no suspicious strings
        let heapSnapshot: [String: Any] = [
            "nodes": [0, 1, 2, 3, 4, 5, 6],
            "strings": ["Object", "String", "Number", "Array"]
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: heapSnapshot)
        let artifactURL = tempDirectory.appendingPathComponent("test_heap.heapsnapshot")
        try! jsonData.write(to: artifactURL)

        let analysis = adapter.analyzeArtifact(url: artifactURL)

        XCTAssertNotNil(analysis)
        XCTAssertTrue(analysis?.suspectedLeaks.isEmpty ?? true)
    }

    func testXcodeAdapterAnalyzeArtifactReturnsAnalysis() {
        let adapter = XcodeAdapter(workingDirectory: tempDirectory)

        // Create a dummy trace file (doesn't need to be valid binary for this test)
        let dummyData = "xctrace output".data(using: .utf8)!
        let artifactURL = tempDirectory.appendingPathComponent("test.trace")
        try! dummyData.write(to: artifactURL)

        let analysis = adapter.analyzeArtifact(url: artifactURL)

        XCTAssertNotNil(analysis)
        XCTAssertEqual(analysis?.runtime, "Xcode")
        XCTAssertEqual(analysis?.artifactType, "Malloc Stack Log")
    }

    func testArtifactAnalysisCodable() {
        let leak = ArtifactAnalysis.SuspectedLeak(
            description: "Test leak",
            severity: "high",
            estimatedBytes: 1024
        )

        let analysis = ArtifactAnalysis(
            runtime: "TestRuntime",
            artifactType: "TestType",
            summary: "Test summary",
            keyFindings: ["finding1", "finding2"],
            suspectedLeaks: [leak],
            analysisTimestamp: Date()
        )

        // Test encoding
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try! encoder.encode(analysis)

        // Test decoding
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try! decoder.decode(ArtifactAnalysis.self, from: encoded)

        XCTAssertEqual(decoded.runtime, "TestRuntime")
        XCTAssertEqual(decoded.artifactType, "TestType")
        XCTAssertEqual(decoded.keyFindings.count, 2)
        XCTAssertEqual(decoded.suspectedLeaks.count, 1)
    }

    func testToolchainAdapterRegistryInitialization() {
        let registry = ToolchainAdapterRegistry()

        XCTAssertNotNil(registry.adapter(for: .chrome))
        XCTAssertNotNil(registry.adapter(for: .xcode))
        XCTAssertNotNil(registry.adapter(for: .node))
        XCTAssertNotNil(registry.adapter(for: .electron))
    }

    func testToolchainAdapterRegistryCorrectRuntimes() {
        let registry = ToolchainAdapterRegistry()

        let chromeAdapter = registry.adapter(for: .chrome)
        XCTAssertEqual(chromeAdapter?.runtime, .chrome)

        let xcodeAdapter = registry.adapter(for: .xcode)
        XCTAssertEqual(xcodeAdapter?.runtime, .xcode)

        let nodeAdapter = registry.adapter(for: .node)
        XCTAssertEqual(nodeAdapter?.runtime, .node)
    }

    func testToolchainAdapterRegistryCustomAdapter() {
        let registry = ToolchainAdapterRegistry()

        // Create a custom adapter
        let customAdapter = ChromiumAdapter(workingDirectory: tempDirectory)
        registry.register(customAdapter, for: .electron)

        let retrievedAdapter = registry.adapter(for: .electron)
        XCTAssertNotNil(retrievedAdapter)
        XCTAssertEqual(retrievedAdapter?.runtime, .chrome)  // Custom adapter is Chromium-based
    }

    func testToolchainAdapterUnregisteredRuntime() {
        let registry = ToolchainAdapterRegistry()

        // Safari is not registered by default
        let safariAdapter = registry.adapter(for: .safari)
        XCTAssertNil(safariAdapter)
    }

    func testArtifactAnalysisSuspectedLeakProperties() {
        let leak = ArtifactAnalysis.SuspectedLeak(
            description: "Memory not released",
            severity: "high",
            estimatedBytes: 5242880  // 5MB
        )

        XCTAssertEqual(leak.description, "Memory not released")
        XCTAssertEqual(leak.severity, "high")
        XCTAssertEqual(leak.estimatedBytes, 5242880)
    }

    func testArtifactAnalysisWithMultipleSuspectedLeaks() {
        let leaks = [
            ArtifactAnalysis.SuspectedLeak(description: "Leak 1", severity: "high", estimatedBytes: 1024),
            ArtifactAnalysis.SuspectedLeak(description: "Leak 2", severity: "medium", estimatedBytes: 512),
            ArtifactAnalysis.SuspectedLeak(description: "Leak 3", severity: "low", estimatedBytes: nil)
        ]

        let analysis = ArtifactAnalysis(
            runtime: "TestRuntime",
            artifactType: "TestType",
            summary: "Multiple leaks detected",
            keyFindings: [],
            suspectedLeaks: leaks,
            analysisTimestamp: Date()
        )

        XCTAssertEqual(analysis.suspectedLeaks.count, 3)
        XCTAssertEqual(analysis.suspectedLeaks[0].severity, "high")
        XCTAssertEqual(analysis.suspectedLeaks[1].severity, "medium")
        XCTAssertEqual(analysis.suspectedLeaks[2].severity, "low")
    }
}
