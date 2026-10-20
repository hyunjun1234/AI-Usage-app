import Foundation
import CoreFoundation

struct CodexLimitsResult {
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
    var planType: String?
}

struct CodexServiceError: Error {
    let message: String
    let requiresLogin: Bool
}

enum CodexLoginState {
    case idle
    case waitingForBrowser
    case failed(String)
}

/// Keeps Codex's authenticated app-server connection open between refreshes.
/// Codex manages credentials; this client only receives account limits and login URLs.
final class CodexAppServer {
    var onLimits: ((Result<CodexLimitsResult, CodexServiceError>) -> Void)?
    var onLoginStateChanged: ((CodexLoginState) -> Void)?
    var onOpenLoginURL: ((URL) -> Void)?
    var onAccountChanged: (() -> Void)?

    private typealias Response = Result<[String: Any], CodexServiceError>
    private struct Pending {
        let method: String
        let timeout: DispatchWorkItem
        let completion: (Response) -> Void
    }
    private let queue = DispatchQueue(label: "aiusage.codex.connection")
    private let binaryPath: String?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = 0
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var initialized = false
    private var needsRefresh = false
    private var refreshInFlight = false
    private var wantsLogin = false
    private var loginStarting = false
    private var loginAttempt = 0
    private var loginID: String?
    private var loginTimeout: DispatchWorkItem?

    init(binaryPath: String? = nil) { self.binaryPath = binaryPath }

    deinit {
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        pending.values.forEach { $0.timeout.cancel() }
        loginTimeout?.cancel()
    }

    static func locateBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(home)/.codex/bin/codex", "\(home)/.local/bin/codex",
        ]
        // npm's JS launcher requires Node on PATH, which a Finder-launched app may lack.
        // Prefer the native executable distributed alongside that launcher.
        #if arch(arm64)
        let platform = "darwin-arm64", triple = "aarch64-apple-darwin"
        #else
        let platform = "darwin-x64", triple = "x86_64-apple-darwin"
        #endif
        for prefix in ["\(home)/.npm-global", "/opt/homebrew", "/usr/local"] {
            candidates.append("\(prefix)/lib/node_modules/@openai/codex/node_modules/@openai/codex-\(platform)/vendor/\(triple)/bin/codex")
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        candidates.append("\(home)/.npm-global/bin/codex")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.refreshInFlight else { return }
            self.needsRefresh = true
            self.ensureStarted()
            self.flushRequests()
        }
    }

    func startLogin() {
        queue.async { [weak self] in
            guard let self = self, !self.wantsLogin else { return }
            self.loginAttempt += 1
            self.wantsLogin = true
            self.publishLogin(.waitingForBrowser)
            self.ensureStarted()
            self.flushRequests()
        }
    }

    func cancelLogin() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelActiveLogin()
            self.publishLogin(.idle)
            self.flushRequests()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.needsRefresh = false
            self.wantsLogin = false
            self.disconnect(error: nil)
        }
    }

    private func ensureStarted() {
        guard process == nil else { return }
        guard let binary = binaryPath ?? Self.locateBinary() else {
            failQueued(CodexServiceError(message: "Codex 앱 또는 CLI를 설치해 주세요.", requiresLogin: false))
            return
        }
        let proc = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["app-server"]
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        generation += 1
        let currentGeneration = generation
        output = stdoutPipe.fileHandleForReading
        input = stdinPipe.fileHandleForWriting
        process = proc
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                guard let self = self, self.generation == currentGeneration else { return }
                if data.isEmpty {
                    self.disconnect(error: Self.connectionError)
                } else {
                    self.receive(data)
                }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self = self, self.generation == currentGeneration else { return }
                self.disconnect(error: Self.connectionError)
            }
        }
        do { try proc.run() } catch {
            disconnect(error: CodexServiceError(message: "Codex를 실행하지 못했습니다.", requiresLogin: false))
            return
        }
        request("initialize", params: ["clientInfo": ["name": "aiusage", "title": "AI Usage", "version": "2.8"]]) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .success:
                self.initialized = true
                self.write(["jsonrpc": "2.0", "method": "initialized"])
                self.flushRequests()
            case .failure(let error):
                self.failQueued(error)
                self.disconnect(error: nil)
            }
        }
    }

    private func flushRequests() {
        guard initialized else { return }
        if wantsLogin {
            if !loginStarting && loginID == nil { beginLogin() }
            return
        }
        guard needsRefresh, !refreshInFlight else { return }
        needsRefresh = false
        refreshInFlight = true
        request("account/rateLimits/read", params: [:]) { [weak self] response in
            guard let self = self else { return }
            self.refreshInFlight = false
            switch response {
            case .success(let result):
                self.publishLimits(Self.parseLimits(result))
            case .failure(let error):
                self.publishLimits(.failure(error))
            }
            self.flushRequests()
        }
    }

    private func beginLogin() {
        loginStarting = true
        let attempt = loginAttempt
        request("account/login/start", params: ["type": "chatgpt"]) { [weak self] response in
            guard let self = self else { return }
            self.loginStarting = false
            guard attempt == self.loginAttempt else {
                if case .success(let result) = response, let id = result["loginId"] as? String {
                    self.request("account/login/cancel", params: ["loginId": id]) { _ in }
                }
                self.flushRequests()
                return
            }
            switch response {
            case .success(let result):
                guard let id = result["loginId"] as? String else {
                    self.failLogin("Codex 로그인 응답을 확인하지 못했습니다.")
                    return
                }
                guard self.wantsLogin else {
                    self.request("account/login/cancel", params: ["loginId": id]) { _ in }
                    return
                }
                self.loginID = id
                guard let rawURL = result["authUrl"] as? String,
                      let url = URL(string: rawURL), url.scheme == "https",
                      let host = url.host,
                      host == "openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") else {
                    self.cancelActiveLogin()
                    self.publishLogin(.failed("Codex 로그인 주소를 확인하지 못했습니다."))
                    self.flushRequests()
                    return
                }
                DispatchQueue.main.async { [weak self] in self?.onOpenLoginURL?(url) }
                let timeout = DispatchWorkItem { [weak self] in
                    self?.cancelActiveLogin()
                    self?.publishLogin(.failed("로그인 시간이 만료됐습니다. 다시 로그인해 주세요."))
                    self?.flushRequests()
                }
                self.loginTimeout = timeout
                self.queue.asyncAfter(deadline: .now() + 300, execute: timeout)
            case .failure(let error): self.failLogin(error.message)
            }
        }
    }

    private func cancelActiveLogin() {
        loginAttempt += 1
        wantsLogin = false
        loginTimeout?.cancel()
        loginTimeout = nil
        if let id = loginID, initialized {
            request("account/login/cancel", params: ["loginId": id]) { _ in }
        }
        loginID = nil
    }

    private func failLogin(_ message: String) {
        guard wantsLogin else { return }
        wantsLogin = false
        loginID = nil
        loginTimeout?.cancel()
        loginTimeout = nil
        publishLogin(.failed(message))
        flushRequests()
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping (Response) -> Void) {
        guard process != nil else { completion(.failure(Self.connectionError)); return }
        nextID += 1
        let id = nextID
        let timeout = DispatchWorkItem { [weak self] in
            guard let pending = self?.pending.removeValue(forKey: id) else { return }
            pending.completion(.failure(CodexServiceError(message: "Codex 응답이 지연되고 있습니다. 다시 새로고침해 주세요.", requiresLogin: false)))
        }
        pending[id] = Pending(method: method, timeout: timeout, completion: completion)
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message), let input = input else { return }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { disconnect(error: Self.connectionError) }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = (object["id"] as? NSNumber)?.intValue,
               let pending = pending.removeValue(forKey: id) {
                pending.timeout.cancel()
                if let error = object["error"] as? [String: Any] {
                    let message = (error["message"] as? String ?? "").lowercased()
                    let requiresLogin = ["not logged", "not signed", "not authenticated", "unauthorized", "authentication", "auth required", "chatgpt auth", "missing auth", "requires auth", "sign in", "login", "401"].contains { message.contains($0) }
                    let failureMessage = pending.method == "account/login/start"
                        ? "Codex 로그인을 시작하지 못했습니다. 다시 시도해 주세요."
                        : "Codex 사용량을 가져오지 못했습니다. 다시 새로고침해 주세요."
                    pending.completion(.failure(CodexServiceError(
                        message: requiresLogin ? "Codex 로그인이 필요합니다." : failureMessage,
                        requiresLogin: requiresLogin)))
                } else if let result = object["result"] as? [String: Any] {
                    pending.completion(.success(result))
                } else {
                    pending.completion(.success([:]))
                }
            } else if let method = object["method"] as? String {
                notification(method, params: object["params"] as? [String: Any] ?? [:])
            }
        }
        if buffer.count > 4 * 1024 * 1024 { disconnect(error: Self.connectionError) }
    }

    private func notification(_ method: String, params: [String: Any]) {
        switch method {
        case "account/rateLimits/updated": publishLimits(Self.parseLimits(params))
        case "account/updated":
            invalidateRateRequest()
            DispatchQueue.main.async { [weak self] in self?.onAccountChanged?() }
            if params["authMode"] is NSNull {
                publishLimits(.failure(CodexServiceError(message: "Codex 로그인이 필요합니다.", requiresLogin: true)))
            }
            needsRefresh = true
            flushRequests()
        case "account/login/completed":
            guard wantsLogin, let id = params["loginId"] as? String, id == loginID else { return }
            loginTimeout?.cancel()
            loginTimeout = nil
            loginID = nil
            wantsLogin = false
            if params["success"] as? Bool == true {
                invalidateRateRequest()
                publishLogin(.idle)
                DispatchQueue.main.async { [weak self] in self?.onAccountChanged?() }
                needsRefresh = true
                flushRequests()
            } else {
                publishLogin(.failed("Codex 로그인을 완료하지 못했습니다. 다시 시도해 주세요."))
                flushRequests()
            }
        default: break
        }
    }

    /// Discard replies started before an account change so old-account limits
    /// cannot overwrite the new account's data.
    private func invalidateRateRequest() {
        let ids = pending.filter { $0.value.method == "account/rateLimits/read" }.map(\.key)
        for id in ids { pending.removeValue(forKey: id)?.timeout.cancel() }
        refreshInFlight = false
    }

    private func disconnect(error: CodexServiceError?) {
        generation += 1
        initialized = false
        output?.readabilityHandler = nil
        output = nil
        try? input?.close()
        input = nil
        let oldProcess = process
        process = nil
        oldProcess?.terminationHandler = nil
        if oldProcess?.isRunning == true { oldProcess?.terminate() }
        buffer.removeAll()
        let requests = pending.values
        pending.removeAll()
        requests.forEach { $0.timeout.cancel() }
        refreshInFlight = false
        loginStarting = false
        loginID = nil
        loginTimeout?.cancel()
        loginTimeout = nil
        if let error = error {
            requests.forEach { $0.completion(.failure(error)) }
            failQueued(error)
        }
    }

    private func failQueued(_ error: CodexServiceError) {
        if needsRefresh { needsRefresh = false; publishLimits(.failure(error)) }
        if wantsLogin { wantsLogin = false; publishLogin(.failed(error.message)) }
    }

    private func publishLimits(_ result: Result<CodexLimitsResult, CodexServiceError>) {
        DispatchQueue.main.async { [weak self] in self?.onLimits?(result) }
    }

    private func publishLogin(_ state: CodexLoginState) {
        DispatchQueue.main.async { [weak self] in self?.onLoginStateChanged?(state) }
    }

    private static let connectionError = CodexServiceError(message: "Codex 연결이 끊겼습니다. 다시 새로고침해 주세요.", requiresLogin: false)

    private static func parseLimits(_ result: [String: Any]) -> Result<CodexLimitsResult, CodexServiceError> {
        let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let limits = byID?["codex"] ?? result["rateLimits"] as? [String: Any] else {
            return .failure(CodexServiceError(message: "이 Codex 계정의 사용량 한도를 확인할 수 없습니다.", requiresLogin: false))
        }
        func window(_ key: String, fallbackKind: WindowKind) -> LimitWindow? {
            guard let value = limits[key] as? [String: Any],
                  let number = value["usedPercent"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let percent = number.doubleValue
            guard percent.isFinite, percent >= 0, percent < Double(Int.max) else { return nil }
            let kind: WindowKind
            if let duration = value["windowDurationMins"] as? NSNumber {
                guard CFGetTypeID(duration) != CFBooleanGetTypeID() else { return nil }
                switch duration.doubleValue {
                case 300: kind = .fiveHour
                case 10080: kind = .weekly
                default: return nil
                }
            } else {
                kind = fallbackKind
            }
            var reset: Date?
            if let timestamp = value["resetsAt"] as? NSNumber,
               CFGetTypeID(timestamp) != CFBooleanGetTypeID(), timestamp.doubleValue.isFinite {
                reset = Date(timeIntervalSince1970: timestamp.doubleValue)
            }
            return LimitWindow(kind: kind, usedPercent: percent, resetsAt: reset, isReal: true)
        }
        let windows = [window("primary", fallbackKind: .fiveHour), window("secondary", fallbackKind: .weekly)].compactMap { $0 }
        let parsed = CodexLimitsResult(fiveHour: windows.first { $0.kind == .fiveHour }, weekly: windows.first { $0.kind == .weekly }, planType: limits["planType"] as? String)
        guard parsed.fiveHour != nil || parsed.weekly != nil else {
            return .failure(CodexServiceError(message: "이 Codex 계정의 사용량 한도를 확인할 수 없습니다.", requiresLogin: false))
        }
        return .success(parsed)
    }
}
