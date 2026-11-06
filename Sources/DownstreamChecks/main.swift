// A minimal test runner. The Command Line Tools have no XCTest and no
// Swift Testing macro plugin, so checks are plain functions run in order.
// Exits non-zero if any check fails.
import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("  ✗ \(file):\(line) \(message())")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) {
    expect(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
}

@MainActor func suite(_ name: String, _ body: @MainActor () async throws -> Void) async {
    print("• \(name)")
    do { try await body() } catch {
        failures += 1
        print("  ✗ threw \(error)")
    }
}

await toolLocatorChecks()
await processRunnerChecks()
await mediaInfoChecks()
await argumentBuilderChecks()
await progressParserChecks()
await downloadJobChecks()
await libraryChecks()
if CommandLine.arguments.contains("--live") { await liveChecks() }

print(failures == 0 ? "\nAll \(passes) checks passed." : "\n\(failures) failed, \(passes) passed.")
exit(failures == 0 ? 0 : 1)
