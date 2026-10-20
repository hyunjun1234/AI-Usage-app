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
