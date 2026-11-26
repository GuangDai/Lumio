import XCTest
@testable import LauncherLogic

/// Parity tests for the process-finder ranking, mirroring the Rust reference
/// tests in `apps/linows/src-tauri/src/process.rs`. The fuzzy name score is
/// injected as a lightweight subsequence stub: the real `core/matching` DP is
/// covered by the Rust crate's own tests and reused over FFI. These tests cover
/// ranking by port, PID and name.
final class ProcessScoringTests: XCTestCase {
    /// Deterministic stand-in for `lumio_fuzzy_score`: a positive score when
    /// `query` is a subsequence of `title`, else nil. Both are already
    /// lowercased by the scorer, matching the FFI contract.
    private func stubFuzzy(_ query: String) -> (String) -> Int? {
        { title in
            var qi = query.startIndex
            for ch in title where qi < query.endIndex && ch == query[qi] {
                qi = query.index(after: qi)
            }
            return qi == query.endIndex ? 100 : nil
        }
    }

    private func score(_ candidate: ProcessScoring.Candidate, _ query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessScoring.score(
            name: candidate.name,
            ports: candidate.ports,
            pid: candidate.pid,
            trimmedQuery: trimmed,
            isNumeric: ProcessScoring.isNumeric(trimmed),
            exactPort: ProcessScoring.exactPort(trimmed),
            fuzzy: stubFuzzy(trimmed.lowercased())
        )
    }

    private func row(_ name: String, _ pid: Int32, _ ports: [Int]) -> ProcessScoring.Candidate {
        ProcessScoring.Candidate(name: name, pid: pid, ports: ports)
    }

    // MARK: - score_process parity

    func testExactPortBeatsPartialAndName() {
        let server = row("node", 4321, [3000])
        let other = row("node", 30001, []) // "3000" is a PID substring only
        let named = row("proc3000", 99, []) // name contains the digits
        let exact = score(server, "3000")
        XCTAssertEqual(exact, ProcessScoring.portExactScore)
        XCTAssertGreaterThan(exact!, score(other, "3000")!)
        XCTAssertGreaterThan(exact!, score(named, "3000")!)
    }

    func testPartialPortRanksAbovePIDOnly() {
        let byPort = row("a", 1, [3000]) // "300" is a substring of the port
        let byPID = row("b", 3009, []) // "300" is a substring of the PID
        XCTAssertEqual(score(byPort, "300"), ProcessScoring.numericPartialScore)
        XCTAssertEqual(score(byPID, "300"), ProcessScoring.pidPartialScore)
        XCTAssertGreaterThan(score(byPort, "300")!, score(byPID, "300")!)
    }

    func testPIDSubstringKeepsARealNameMatch() {
        let named = row("proc300", 1300, []) // name and PID both hold "300"
        let pidOnly = row("b", 1300, [])
        XCTAssertGreaterThan(score(named, "300")!, ProcessScoring.pidPartialScore)
        XCTAssertEqual(score(pidOnly, "300"), ProcessScoring.pidPartialScore)
    }

    func testNameQueryStillFuzzyMatches() {
        let ff = row("firefox", 100, [])
        XCTAssertNotNil(score(ff, "fire"))
        XCTAssertNil(score(ff, "zzq"))
    }

    func testOversizedPortNumberMatchesNothing() {
        // 99999 > u16::MAX: no exact port, no substring, no PID -> nil.
        let r = row("svc", 42, [8080])
        XCTAssertNil(score(r, "99999"))
    }

    func testNumericQueryStillFuzzyMatchesDigitName() {
        // A name containing the digits still fuzzy-matches even for numeric queries.
        let r = row("proc3000", 99, [])
        XCTAssertNotNil(score(r, "3000"))
    }
}
