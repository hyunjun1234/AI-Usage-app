import Foundation
import CoreFoundation

/// Reads the current limits array (including Fable's weekly_scoped entry),
/// falling back to the original fields for the shared session/weekly limits.
enum ClaudeUsageParser {
    static func parse(_ usage: [String: Any]) -> [LimitWindow]? {
        var fiveHour: LimitWindow?
        var weekly: LimitWindow?
        var scoped: [LimitWindow] = []
        var scopedIDs = Set<String>()

        for case let limit as [String: Any] in usage["limits"] as? [Any] ?? [] {
            switch limit["kind"] as? String {
            case "session":
                if fiveHour == nil {
                    fiveHour = window(limit, percentKey: "percent", kind: .fiveHour)
                }
            case "weekly_all":
                if weekly == nil {
                    weekly = window(limit, percentKey: "percent", kind: .weekly)
                }
            case "weekly_scoped":
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String else { continue }
                let modelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelName.isEmpty,
                      let parsed = window(limit, percentKey: "percent", kind: .weekly,
                                          modelName: modelName),
                      scopedIDs.insert(parsed.id).inserted else { continue }
                scoped.append(parsed)
            default:
                continue
            }
        }

        if fiveHour == nil, let legacy = usage["five_hour"] as? [String: Any] {
            fiveHour = window(legacy, percentKey: "utilization", kind: .fiveHour)
        }
        if weekly == nil, let legacy = usage["seven_day"] as? [String: Any] {
            weekly = window(legacy, percentKey: "utilization", kind: .weekly)
        }

        let windows = [fiveHour, weekly].compactMap { $0 } + scoped
        return windows.isEmpty ? nil : windows
    }

    private static func window(_ value: [String: Any], percentKey: String,
                               kind: WindowKind, modelName: String? = nil) -> LimitWindow? {
        guard let number = value[percentKey] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let percent = number.doubleValue
        // Values above 100 are valid overages; reject values unsafe to display.
        guard percent.isFinite, percent >= 0, percent < Double(Int.max) else { return nil }
        let reset = (value["resets_at"] as? String).flatMap(Fmt.claudeUsageResetDate)
        return LimitWindow(kind: kind, usedPercent: percent, resetsAt: reset,
                           isReal: true, modelName: modelName)
    }
}
