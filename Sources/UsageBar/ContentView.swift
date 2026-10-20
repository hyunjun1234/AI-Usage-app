import SwiftUI
import AppKit

enum Theme {
    static let claude = Color(red: 0.83, green: 0.46, blue: 0.31)
    static let codex  = Color(red: 0.15, green: 0.63, blue: 0.51)
    static let brand  = Color(red: 0.47, green: 0.40, blue: 0.92)

    static func limitColor(_ fraction: Double, base: Color) -> Color {
        if fraction >= 1.0 { return .red }
        if fraction >= 0.8 { return .orange }
        return base
    }
    static func quipColor(_ level: Int) -> Color {
        switch level {
        case 0:  return .green
        case 1:  return .yellow
        case 2:  return .orange
        default: return .red
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            quipBanner
            if store.toolFilter.showsClaude { claudeCard }
            if store.toolFilter.showsCodex { codexCard }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.title3)
                .foregroundStyle(Theme.brand)
            Text("AI Usage").font(.headline)
            Spacer()
            Text(updatedText).font(.caption2).foregroundStyle(.secondary)
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { store.manualRefresh() }
                    .help("새로고침")
            }
        }
        .frame(height: 22)
    }

    private var updatedText: String {
        if store.isRefreshing { return "업데이트 중…" }
        guard let d = store.snapshot.lastUpdated else { return "불러오는 중…" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "방금 업데이트" }
        if s < 3600 { return "\(s / 60)분 전" }
        return "\(s / 3600)시간 전"
    }

    // MARK: Quip

    private var quipBanner: some View {
        let quip = store.snapshot.quip
        let color = Theme.quipColor(quip.level)
        return HStack(spacing: 7) {
            Image(systemName: quip.symbol).foregroundStyle(color)
            Text(quip.text).font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Cards

    private var claudeCard: some View {
        let snap = store.snapshot
        let hasData = !snap.claudeWindows.isEmpty
        let note: String?
        let login: (() -> Void)?
        if hasData {
            note = nil; login = nil
        } else if snap.claudeLoggedOut {
            note = "claude.ai에 로그인하면 실제 5시간·주간 한도가 표시됩니다."
            login = { store.showClaudeLogin() }
        } else {
            note = "claude.ai에서 한도를 불러오는 중…"
            login = nil
        }
        return ToolCard(tool: .claude, accent: Theme.claude,
                        badge: hasData ? "실시간" : "", badgeReal: true,
                        subtitle: snap.claudePlan ?? "",
                        windows: snap.claudeWindows,
                        note: note,
                        loginAction: login)
    }

    private var codexCard: some View {
        let snap = store.snapshot
        let hasData = !snap.codexWindows.isEmpty
        let note: String?
        if store.codexLoginInProgress {
            note = "브라우저에서 ChatGPT 로그인을 완료하면 사용량을 바로 불러옵니다."
        } else if let error = snap.codexError {
            note = hasData ? "\(error)\n마지막으로 확인한 사용량을 표시합니다." : error
        } else if hasData {
            note = nil
        } else {
            note = "Codex 사용량을 불러오는 중…"
        }
        return ToolCard(tool: .codex, accent: Theme.codex,
                        badge: hasData ? (snap.codexOK ? "실시간" : "갱신 지연") : "",
                        badgeReal: hasData && snap.codexOK,
                        subtitle: snap.codexPlan.map { $0.capitalized } ?? "",
                        windows: snap.codexWindows,
                        note: note,
                        loginAction: { store.showCodexLogin() },
                        loginTitle: store.codexLoginInProgress
                            ? "브라우저에서 로그인 중…" : "ChatGPT 계정으로 로그인",
                        loginDisabled: store.codexLoginInProgress,
                        cancelLoginAction: store.codexLoginInProgress
                            ? { store.cancelCodexLogin() } : nil)
    }
}

/// One tool card with shared limits and any model-specific weekly limits.
struct ToolCard: View {
    let tool: Tool
    let accent: Color
    let badge: String
    let badgeReal: Bool
    let subtitle: String
    let windows: [LimitWindow]
    let note: String?
    var loginAction: (() -> Void)? = nil
    var loginTitle = "Claude.ai 로그인 → 실시간 사용량"
    var loginDisabled = false
    var cancelLoginAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(tool.label).font(.subheadline.weight(.semibold))
                if !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((badgeReal ? accent : Color.secondary).opacity(0.18), in: Capsule())
                        .foregroundStyle(badgeReal ? accent : Color.secondary)
                }
                Spacer()
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if windows.isEmpty {
                Text(note ?? "데이터 없음")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(windows) {
                    WindowRow(window: $0, accent: accent,
                              labelWidth: windows.contains { $0.modelName != nil } ? 82 : 42)
                }
                if let note = note {
                    Text(note)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let loginAction = loginAction {
                Button(action: loginAction) {
                    Text(loginTitle)
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(loginDisabled)
                .help(tool == .codex
                      ? "Codex 앱·CLI와 로그인 상태를 공유합니다."
                      : "claude.ai 계정으로 로그인합니다.")
            }
            if let cancelLoginAction {
                Button("로그인 취소", action: cancelLoginAction)
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.22)))
    }
}

/// One window row: label · gauge bar · percent, with a reset hint below.
struct WindowRow: View {
    let window: LimitWindow
    let accent: Color
    var labelWidth: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(window.label)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: labelWidth, alignment: .leading)
                GaugeBar(fraction: window.usedPercent / 100, accent: accent)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Theme.limitColor(window.usedPercent / 100, base: .primary))
                    .frame(width: 46, alignment: .trailing)
            }
            if let reset = window.resetText {
                Text(reset)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, labelWidth + 8)
            }
        }
    }
}

/// Horizontal gauge bar: fills, turning orange/red as it nears/exceeds 100%.
struct GaugeBar: View {
    let fraction: Double
    let accent: Color

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        let color = Theme.limitColor(fraction, base: accent)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.15))
                Capsule().fill(color).frame(width: max(3, geo.size.width * clamped))
            }
        }
        .frame(height: 7)
    }
}
