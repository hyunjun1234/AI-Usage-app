import Foundation

/// Standalone regression tests, runnable with Command Line Tools (no XCTest).
@main
struct ClaudeUsageParserTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("current response with Fable", testCurrentResponseIncludesFableAndPrefersCurrentSharedLimits),
            ("limits-only response", testLimitsOnlyResponseDoesNotRequireLegacyFields),
            ("legacy response", testLegacyResponseKeepsOriginalWindowsWithoutInventingFable),
            ("mixed response and zero usage", testMixedResponsePreservesLegacyWindowsAndZeroFableUsage),
            ("malformed entries", testMalformedEntriesDoNotHideValidUsage),
            ("model identities", testMultipleModelsHaveDistinctIDsAndDuplicateRowsAreIgnored),
            ("menu bar weekly selection", testMenuBarWeeklyPercentDoesNotUseModelSpecificLimit),
            ("menu bar weekly-only Codex fallback", testMenuBarFallsBackToWeeklyCodex),
            ("menu bar five-hour-only fallback", testMenuBarFallsBackToFiveHour),
            ("menu bar prefers the selected available window", testMenuBarPrefersSelectedWindow),
            ("menu bar excludes scoped fallback windows", testMenuBarFallbackExcludesModelSpecificLimits),
            ("menu bar distinguishes missing data and zero", testMenuBarMissingDataAndZero),
            ("invalid response", testInvalidResponseDoesNotMasqueradeAsZeroUsage),
            ("fractional usage and overage", testFractionalPercentAndOverageAreNotRescaledOrClamped)
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("\(tests.count) tests passed")
    }

    static func testCurrentResponseIncludesFableAndPrefersCurrentSharedLimits() throws {
        let windows = try parse("""
        {
          "five_hour": {"utilization": 91},
          "seven_day": {"utilization": 92},
          "limits": [
            {"kind": "weekly_scoped", "percent": 63.5,
             "resets_at": "2026-10-25T10:00:00.123456+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}}},
            {"kind": "weekly_all", "percent": 24, "resets_at": "2026-10-25T10:00:00Z"},
            {"kind": "session", "percent": 12, "resets_at": "2026-10-20T11:00:00Z"}
          ]
        }
        """)

        precondition(windows.map(\.label) == ["5시간", "주간", "Fable 주간"])
        precondition(windows.map(\.usedPercent) == [12, 24, 63.5])
        precondition(windows.allSatisfy(\.isReal))
        precondition(windows.allSatisfy { $0.resetsAt != nil })
        let resetDifference = windows[2].resetsAt!.timeIntervalSince(windows[1].resetsAt!)
        precondition(abs(resetDifference - 0.123456) < 0.001)
        precondition(Set(windows.map(\.id)).count == 3)
    }

    static func testLimitsOnlyResponseDoesNotRequireLegacyFields() throws {
        let windows = try parse("""
        {"limits": [
          {"kind": "session", "percent": 1},
          {"kind": "weekly_all", "percent": 2},
          {"kind": "weekly_scoped", "percent": 3,
           "scope": {"model": {"display_name": "Fable"}}}
        ]}
        """)
        precondition(windows.map(\.usedPercent) == [1, 2, 3])
    }

    static func testLegacyResponseKeepsOriginalWindowsWithoutInventingFable() throws {
        let windows = try parse("""
        {
          "five_hour": {"utilization": 0, "resets_at": null},
          "seven_day": {"utilization": 42, "resets_at": "2026-10-25T10:00:00Z"},
          "seven_day_sonnet": null
        }
        """)
        precondition(windows.map(\.label) == ["5시간", "주간"])
        precondition(windows.map(\.usedPercent) == [0, 42])
        precondition(windows[0].resetsAt == nil)
    }

    static func testMixedResponsePreservesLegacyWindowsAndZeroFableUsage() throws {
        let windows = try parse("""
        {
          "five_hour": {"utilization": 10},
          "seven_day": {"utilization": 20},
          "limits": [
            {"kind": "weekly_scoped", "percent": 0, "resets_at": null,
             "scope": {"model": {"display_name": "Fable"}}}
          ]
        }
        """)
        precondition(windows.map(\.usedPercent) == [10, 20, 0])
        precondition(windows.last?.label == "Fable 주간")
        precondition(windows.last?.resetsAt == nil)
    }

    static func testMalformedEntriesDoNotHideValidUsage() throws {
        let windows = try parse("""
        {
          "five_hour": {"utilization": 10},
          "limits": [
            null, "invalid",
            {"kind": "session", "percent": null},
            {"kind": "weekly_all", "percent": 20},
            {"kind": "weekly_scoped", "percent": "80",
             "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "weekly_scoped", "percent": true,
             "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "weekly_scoped", "percent": -1,
             "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "weekly_scoped", "percent": 80, "scope": null},
            {"kind": "weekly_scoped", "percent": 80,
             "scope": {"model": {"display_name": "   "}}},
            {"kind": "future_limit", "percent": 95},
            {"kind": "weekly_scoped", "percent": 80, "resets_at": "invalid",
             "scope": {"model": {"display_name": "Fable"}}}
          ]
        }
        """)
        precondition(windows.map(\.usedPercent) == [10, 20, 80])
        precondition(windows.last?.resetsAt == nil)
    }

    static func testMultipleModelsHaveDistinctIDsAndDuplicateRowsAreIgnored() throws {
        let windows = try parse("""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 25,
           "scope": {"model": {"display_name": " Fable "}}},
          {"kind": "weekly_scoped", "percent": 25,
           "scope": {"model": {"display_name": "fable"}}},
          {"kind": "weekly_scoped", "percent": 30,
           "scope": {"model": {"display_name": "Sonnet"}}}
        ]}
        """)
        precondition(windows.map(\.label) == ["Fable 주간", "Sonnet 주간"])
        precondition(Set(windows.map(\.id)).count == 2)
    }

    static func testMenuBarWeeklyPercentDoesNotUseModelSpecificLimit() throws {
        let windows = try parse("""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 90,
           "scope": {"model": {"display_name": "Fable"}}},
          {"kind": "weekly_all", "percent": 20}
        ]}
        """)
        var snapshot = Snapshot(claudeWindows: Array(windows.reversed()))
        precondition(snapshot.percent(.claude, .weekly) == 20)
        snapshot.claudeWindows.removeAll { $0.modelName == nil }
        precondition(snapshot.percent(.claude, .weekly) == nil)
    }

    static func testMenuBarFallsBackToWeeklyCodex() {
        let reset = Date(timeIntervalSince1970: 1_800_600_000)
        let snapshot = Snapshot(
            claudeWindows: [LimitWindow(kind: .fiveHour, usedPercent: 8, resetsAt: nil, isReal: true)],
            codexWindows: [LimitWindow(kind: .weekly, usedPercent: 65.75, resetsAt: reset, isReal: true)])
        let displayed = snapshot.menuWindow(for: .codex, preferred: .fiveHour)
        precondition(displayed?.kind == .weekly)
        precondition(displayed?.usedPercent == 65.75)
        precondition(displayed?.resetsAt == reset)
        precondition(snapshot.percent(.codex, .fiveHour) == nil)
        precondition(snapshot.percent(.codex, .weekly) == 65.75)
        precondition(snapshot.menuWindow(for: .claude, preferred: .fiveHour)?.usedPercent == 8)
    }

    static func testMenuBarFallsBackToFiveHour() {
        let snapshot = Snapshot(codexWindows: [
            LimitWindow(kind: .fiveHour, usedPercent: 12.5, resetsAt: nil, isReal: true)
        ])
        let displayed = snapshot.menuWindow(for: .codex, preferred: .weekly)
        precondition(displayed?.kind == .fiveHour)
        precondition(displayed?.usedPercent == 12.5)
        precondition(snapshot.percent(.codex, .weekly) == nil)
    }

    static func testMenuBarPrefersSelectedWindow() {
        let snapshot = Snapshot(codexWindows: [
            LimitWindow(kind: .weekly, usedPercent: 65.75, resetsAt: nil, isReal: true),
            LimitWindow(kind: .fiveHour, usedPercent: 12.5, resetsAt: nil, isReal: true)
        ])
        let fiveHour = snapshot.menuWindow(for: .codex, preferred: .fiveHour)
        let weekly = snapshot.menuWindow(for: .codex, preferred: .weekly)
        precondition(fiveHour?.kind == .fiveHour && fiveHour?.usedPercent == 12.5)
        precondition(weekly?.kind == .weekly && weekly?.usedPercent == 65.75)
    }

    static func testMenuBarFallbackExcludesModelSpecificLimits() {
        let scopedFiveHour = LimitWindow(
            kind: .fiveHour, usedPercent: 90, resetsAt: nil, isReal: true, modelName: "Fable")
        let scopedWeekly = LimitWindow(
            kind: .weekly, usedPercent: 95, resetsAt: nil, isReal: true, modelName: "Fable")
        let sharedWeekly = LimitWindow(kind: .weekly, usedPercent: 25, resetsAt: nil, isReal: true)
        let mixed = [scopedFiveHour, scopedWeekly, sharedWeekly]
        let sharedSnapshot = Snapshot(claudeWindows: mixed, codexWindows: mixed)
        let scopedSnapshot = Snapshot(
            claudeWindows: [scopedFiveHour, scopedWeekly],
            codexWindows: [scopedFiveHour, scopedWeekly])
        for tool in Tool.allCases {
            let fallback = sharedSnapshot.menuWindow(for: tool, preferred: .fiveHour)
            precondition(fallback?.kind == .weekly && fallback?.usedPercent == 25)
            precondition(fallback?.modelName == nil)
            precondition(sharedSnapshot.menuWindow(for: tool, preferred: .weekly)?.usedPercent == 25)
            precondition(scopedSnapshot.menuWindow(for: tool, preferred: .fiveHour) == nil)
            precondition(scopedSnapshot.menuWindow(for: tool, preferred: .weekly) == nil)
        }
    }

    static func testMenuBarMissingDataAndZero() {
        let empty = Snapshot()
        for tool in Tool.allCases {
            precondition(empty.menuWindow(for: tool, preferred: .fiveHour) == nil)
            precondition(empty.menuWindow(for: tool, preferred: .weekly) == nil)
        }
        let zeroWeekly = LimitWindow(kind: .weekly, usedPercent: 0, resetsAt: nil, isReal: true)
        let onlyWeekly = Snapshot(codexWindows: [zeroWeekly])
        precondition(onlyWeekly.menuWindow(for: .codex, preferred: .fiveHour)?.usedPercent == 0)
        precondition(onlyWeekly.menuWindow(for: .codex, preferred: .weekly)?.usedPercent == 0)
        let both = Snapshot(codexWindows: [
            zeroWeekly,
            LimitWindow(kind: .fiveHour, usedPercent: 30, resetsAt: nil, isReal: true)
        ])
        precondition(both.menuWindow(for: .codex, preferred: .weekly)?.usedPercent == 0)
        precondition(both.percent(.codex, .weekly) == 0)
    }

    static func testInvalidResponseDoesNotMasqueradeAsZeroUsage() {
        precondition(ClaudeUsageParser.parse([:]) == nil)
        precondition(ClaudeUsageParser.parse(["limits": NSNull()]) == nil)
        for value in [Double.nan, .infinity, -.infinity, -1, Double(Int.max)] {
            precondition(ClaudeUsageParser.parse([
                "five_hour": ["utilization": value]
            ]) == nil)
        }
    }

    static func testFractionalPercentAndOverageAreNotRescaledOrClamped() throws {
        let windows = try parse("""
        {"limits": [
          {"kind": "session", "percent": 0.5},
          {"kind": "weekly_all", "percent": 100},
          {"kind": "weekly_scoped", "percent": 105,
           "scope": {"model": {"display_name": "Fable"}}}
        ]}
        """)
        precondition(windows.map(\.usedPercent) == [0.5, 100, 105])
    }

    private static func parse(_ json: String) throws -> [LimitWindow] {
        let usage = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        guard let windows = ClaudeUsageParser.parse(usage) else {
            preconditionFailure("Expected valid usage windows")
        }
        return windows
    }
}
