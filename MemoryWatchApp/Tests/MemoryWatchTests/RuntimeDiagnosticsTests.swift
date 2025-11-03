import XCTest
@testable import MemoryWatchCore

final class RuntimeDiagnosticsTests: XCTestCase {
    func testChromeSuggestionsDetected() {
        let suggestions = RuntimeDiagnostics.suggestions(pid: 1234, name: "Google Chrome", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.contains { $0.title.contains("V8") })
    }

    func testUnknownFallsBackToDefault() {
        let suggestions = RuntimeDiagnostics.suggestions(pid: 4321, name: "myapp", executablePath: nil)
        XCTAssertGreaterThanOrEqual(suggestions.count, 2)
    }

    func testPythonSuggestions() {
        let suggestions = RuntimeDiagnostics.suggestions(pid: 2468, name: "Python", executablePath: "/usr/bin/python3")
        XCTAssertTrue(suggestions.contains { $0.command.contains("py-spy") })
        XCTAssertTrue(suggestions.contains { ($0.artifactPath ?? "").contains("pyspy") })
    }

    func testJavaSuggestions() {
        let suggestions = RuntimeDiagnostics.suggestions(pid: 1357, name: "java", executablePath: "/usr/bin/java")
        XCTAssertTrue(suggestions.contains { $0.command.contains("jcmd") })
        XCTAssertTrue(suggestions.contains { ($0.artifactPath ?? "").contains("java_\(1357)_nm") })
    }
}
