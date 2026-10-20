import Foundation

enum Tool: String, CaseIterable, Hashable {
    case claude, codex
    var label: String { self == .claude ? "Claude" : "Codex" }
}

/// The two limit windows both tools share.
enum WindowKind: String {
    case fiveHour, weekly
    var label: String { self == .fiveHour ? "5시간" : "주간" }
}

/// An account-wide or model-specific usage window reported by the service.
struct LimitWindow: Identifiable {
    let kind: WindowKind
    var usedPercent: Double      // 0...100+
    var resetsAt: Date?
    var isReal: Bool
    var modelName: String? = nil

    var id: String {
        modelName.map { "\(kind.rawValue):\($0.lowercased())" } ?? kind.rawValue
    }
    var label: String {
        modelName.map { "\($0) \(kind.label)" } ?? kind.label
    }

    /// Human reset hint, e.g. "오후 3:41 초기화" or "5/25 초기화".
    var resetText: String? {
        guard let r = resetsAt else { return nil }
        if r.timeIntervalSinceNow <= 0 { return "곧 초기화" }
        return Fmt.resetText(r)
    }
}

/// A light-hearted status line shown in the popover.
struct Quip {
    var text: String
    var symbol: String
    var level: Int   // 0 calm · 1 watch · 2 warn · 3 over
}
