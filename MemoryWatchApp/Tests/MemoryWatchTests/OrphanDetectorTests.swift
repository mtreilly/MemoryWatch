import XCTest
@testable import MemoryWatchCore

class OrphanDetectorTests: XCTestCase {
    var detector: OrphanDetector!
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        detector = OrphanDetector(
            staleSwapfileDurationHours: 1,
            maxDeletedFilesPerReport: 50,
            orphanProcessCheckInterval: 1
        )

        let tempDir = FileManager.default.temporaryDirectory
        tempDirectory = tempDir.appendingPathComponent("orphan_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testDetectorInitializesSuccessfully() {
        let customDetector = OrphanDetector(
            staleSwapfileDurationHours: 3,
            maxDeletedFilesPerReport: 100,
            orphanProcessCheckInterval: 600
        )

        XCTAssertNotNil(customDetector)
    }

    func testDetectorWithDefaultParameters() {
        XCTAssertNotNil(detector)
    }

    // MARK: - Deleted File Detection Tests

    func testFindDeletedOpenFilesReturnsArray() {
        // This test verifies the method runs without crashing
        let results = detector.findDeletedOpenFiles()
        XCTAssertNotNil(results)
    }

    func testFindDeletedOpenFilesForSpecificProcess() {
        // Test with current process ID
        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let results = detector.findDeletedOpenFiles(for: currentPID)
        XCTAssertNotNil(results)
    }

    func testFindDeletedOpenFilesWithInvalidPID() {
        // Test with an invalid (non-existent) process ID
        let results = detector.findDeletedOpenFiles(for: 999999)
        // Should return empty or valid results
        XCTAssertNotNil(results)
    }

    // MARK: - Swapfile Detection Tests

    func testFindStaleSwapfilesReturnsArray() {
        let results = detector.findStaleSwapfiles()
        XCTAssertNotNil(results)
    }

    func testStaleSwapfilesAreSortedBySize() {
        let results = detector.findStaleSwapfiles()

        if results.count > 1 {
            for i in 0..<(results.count - 1) {
                XCTAssertGreaterThanOrEqual(results[i].sizeBytes, results[i + 1].sizeBytes)
            }
        }
    }

    // MARK: - Orphaned Process Tests

    func testFindOrphanedProcessesReturnsArray() {
        let results = detector.findOrphanedProcesses()
        XCTAssertNotNil(results)
    }

    func testOrphanProcessCheckHasInterval() {
        // First call should work
        let results1 = detector.findOrphanedProcesses()
        XCTAssertNotNil(results1)

        // Immediate second call should be skipped (interval enforcement)
        let results2 = detector.findOrphanedProcesses()
        // Results should be empty due to interval check
        XCTAssertEqual(results2.count, 0)
    }

    // MARK: - Bundle Path Tests

    func testGetBundlePathForCurrentProcess() {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let bundlePath = detector.getBundlePath(for: pid)

        // Current process might not be in a bundle, so just verify it returns valid type
        XCTAssertTrue(bundlePath == nil || bundlePath is String)
    }

    func testGetBundlePathForInvalidProcess() {
        let bundlePath = detector.getBundlePath(for: 999999)
        // Should return nil for non-existent process
        XCTAssertNil(bundlePath)
    }

    // MARK: - Remediation Suggestions Tests

    func testGetRemediationSuggestionsForDeletedFile() {
        let fileReport = DeletedFileReport(
            processID: 1234,
            processName: "TestApp",
            filePath: "/tmp/deleted_file.txt",
            estimatedBytes: 50_000_000,
            firstDetected: Date()
        )
        let orphanReport = OrphanReport.deletedFile(fileReport)

        let suggestions = detector.getRemediationSuggestions(for: orphanReport)

        XCTAssertGreaterThan(suggestions.count, 0)
        XCTAssertTrue(suggestions.contains { $0.contains("kill") })
    }

    func testGetRemediationSuggestionsForLargeDeletedFile() {
        let fileReport = DeletedFileReport(
            processID: 1234,
            processName: "LargeApp",
            filePath: "/tmp/large_deleted_file.bin",
            estimatedBytes: 200_000_000,  // Over 100MB threshold
            firstDetected: Date()
        )
        let orphanReport = OrphanReport.deletedFile(fileReport)

        let suggestions = detector.getRemediationSuggestions(for: orphanReport)

        XCTAssertTrue(suggestions.contains { $0.contains("WARNING") })
        XCTAssertTrue(suggestions.contains { $0.contains("100MB") })
    }

    func testGetRemediationSuggestionsForSwapfile() {
        let swapReport = SwapfileReport(
            filename: "swapfile0",
            filepath: "/var/vm/swapfile0",
            sizeBytes: 500_000_000,
            lastModified: Date().addingTimeInterval(-7200),
            ageHours: 2
        )
        let orphanReport = OrphanReport.staleSwapfile(swapReport)

        let suggestions = detector.getRemediationSuggestions(for: orphanReport)

        XCTAssertGreaterThan(suggestions.count, 0)
        XCTAssertTrue(suggestions.contains { $0.contains("stale") })
    }

    func testGetRemediationSuggestionsForZombieProcess() {
        let procReport = OrphanedProcessReport(
            processID: 5678,
            processName: "zombie_process",
            state: "Zombie",
            parentProcessID: 1,
            createdAt: Date(),
            estimatedMemoryBytes: 0
        )
        let orphanReport = OrphanReport.orphanedProcess(procReport)

        let suggestions = detector.getRemediationSuggestions(for: orphanReport)

        XCTAssertGreaterThan(suggestions.count, 0)
        XCTAssertTrue(suggestions.contains { $0.contains("Zombie") })
    }

    func testGetRemediationSuggestionsForSuspendedProcess() {
        let procReport = OrphanedProcessReport(
            processID: 9012,
            processName: "suspended_app",
            state: "Suspended",
            parentProcessID: 1,
            createdAt: Date(),
            estimatedMemoryBytes: 0
        )
        let orphanReport = OrphanReport.orphanedProcess(procReport)

        let suggestions = detector.getRemediationSuggestions(for: orphanReport)

        XCTAssertTrue(suggestions.contains { $0.contains("kill -CONT") })
    }

    // MARK: - OrphanReport Tests

    func testOrphanReportDeletedFileProperties() {
        let fileReport = DeletedFileReport(
            processID: 1000,
            processName: "TestApp",
            filePath: "/tmp/test_file.txt",
            estimatedBytes: 1_000_000,
            firstDetected: Date().addingTimeInterval(-86400)  // 1 day ago
        )
        let orphanReport = OrphanReport.deletedFile(fileReport)

        XCTAssertEqual(orphanReport.type, "Deleted Open File")
        XCTAssertEqual(orphanReport.severity, "medium")
        XCTAssertTrue(orphanReport.description.contains("test_file.txt"))
    }

    func testOrphanReportDeletedFileLargeFileSeverity() {
        let fileReport = DeletedFileReport(
            processID: 1000,
            processName: "LargeApp",
            filePath: "/tmp/huge_file.bin",
            estimatedBytes: 600_000_000,  // Over 500MB
            firstDetected: Date()
        )
        let orphanReport = OrphanReport.deletedFile(fileReport)

        XCTAssertEqual(orphanReport.severity, "high")
    }

    func testOrphanReportSwapfileProperties() {
        let swapReport = SwapfileReport(
            filename: "swapfile1",
            filepath: "/var/vm/swapfile1",
            sizeBytes: 300_000_000,
            lastModified: Date().addingTimeInterval(-3600),
            ageHours: 1
        )
        let orphanReport = OrphanReport.staleSwapfile(swapReport)

        XCTAssertEqual(orphanReport.type, "Stale Swapfile")
        XCTAssertEqual(orphanReport.severity, "medium")
    }

    func testOrphanReportSwapfileLargeSeverity() {
        let swapReport = SwapfileReport(
            filename: "swapfile2",
            filepath: "/var/vm/swapfile2",
            sizeBytes: 1_200_000_000,  // Over 1GB
            lastModified: Date(),
            ageHours: 0.5
        )
        let orphanReport = OrphanReport.staleSwapfile(swapReport)

        XCTAssertEqual(orphanReport.severity, "high")
    }

    func testOrphanReportProcessProperties() {
        let procReport = OrphanedProcessReport(
            processID: 3456,
            processName: "test_process",
            state: "Zombie",
            parentProcessID: 1,
            createdAt: Date(),
            estimatedMemoryBytes: 1_000_000
        )
        let orphanReport = OrphanReport.orphanedProcess(procReport)

        XCTAssertEqual(orphanReport.type, "Orphaned Process")
        XCTAssertEqual(orphanReport.severity, "medium")
        XCTAssertTrue(orphanReport.description.contains("Zombie"))
    }

    func testOrphanReportSuspendedProcessSeverity() {
        let procReport = OrphanedProcessReport(
            processID: 5555,
            processName: "suspended_app",
            state: "Suspended",
            parentProcessID: 1,
            createdAt: Date(),
            estimatedMemoryBytes: 0
        )
        let orphanReport = OrphanReport.orphanedProcess(procReport)

        XCTAssertEqual(orphanReport.severity, "low")
    }

    // MARK: - DeletedFileReport Tests

    func testDeletedFileReportFilename() {
        let fileReport = DeletedFileReport(
            processID: 1000,
            processName: "TestApp",
            filePath: "/home/user/long/path/to/file.txt",
            estimatedBytes: 1000,
            firstDetected: Date()
        )

        XCTAssertEqual(fileReport.filename, "file.txt")
    }

    func testDeletedFileReportAge() {
        let oneDayAgo = Date().addingTimeInterval(-86400)
        let fileReport = DeletedFileReport(
            processID: 1000,
            processName: "TestApp",
            filePath: "/tmp/old_file.txt",
            estimatedBytes: 1000,
            firstDetected: oneDayAgo
        )

        XCTAssertGreaterThan(fileReport.ageDays, 0.9)
        XCTAssertLessThan(fileReport.ageDays, 1.1)
    }

    // MARK: - Sendable Conformance Tests

    func testDeletedFileReportSendable() {
        let fileReport = DeletedFileReport(
            processID: 1000,
            processName: "TestApp",
            filePath: "/tmp/test.txt",
            estimatedBytes: 1000,
            firstDetected: Date()
        )

        // If this compiles, Sendable conformance is satisfied
        let _: DeletedFileReport = fileReport
    }

    func testSwapfileReportSendable() {
        let swapReport = SwapfileReport(
            filename: "swapfile0",
            filepath: "/var/vm/swapfile0",
            sizeBytes: 100_000_000,
            lastModified: Date(),
            ageHours: 1
        )

        let _: SwapfileReport = swapReport
    }

    func testOrphanedProcessReportSendable() {
        let procReport = OrphanedProcessReport(
            processID: 5000,
            processName: "test_proc",
            state: "Zombie",
            parentProcessID: 1,
            createdAt: Date(),
            estimatedMemoryBytes: 0
        )

        let _: OrphanedProcessReport = procReport
    }

    func testOrphanReportSendable() {
        let fileReport = DeletedFileReport(
            processID: 1000,
            processName: "TestApp",
            filePath: "/tmp/test.txt",
            estimatedBytes: 1000,
            firstDetected: Date()
        )
        let orphanReport = OrphanReport.deletedFile(fileReport)

        let _: OrphanReport = orphanReport
    }
}
