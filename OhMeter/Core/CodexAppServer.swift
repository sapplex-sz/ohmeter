import Foundation
import Darwin

/// Communicates with the local Codex app-server via stdio JSON-RPC.
///
/// Launches: /Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
/// Protocol: Tries newline-delimited JSON-RPC 2.0 first (standard stdio transport),
///           falls back to WebSocket-framed JSON-RPC if the server requires it.
final class CodexAppServer: @unchecked Sendable {

    // MARK: - Types

    struct QuotaData: Sendable {
        let primaryUsedPercent: Double     // 5h window
        let secondaryUsedPercent: Double   // 7d (weekly) window
        let primaryResetsAt: Date?
        let secondaryResetsAt: Date?
        let planType: String?
    }

    /// Which transport protocol the server uses
    private enum TransportMode {
        case unknown
        case rawJSONRPC    // newline-delimited JSON on stdin/stdout
        case webSocket     // WebSocket-framed JSON on stdin/stdout
    }

    enum ServerError: LocalizedError {
        case binaryNotFound
        case processDied(String)
        case handshakeFailed
        case initFailed(String)
        case quotaReadFailed(String)
        case timeout
        case unexpectedFrame(opcode: UInt8)
        case processError(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Codex binary not found at /Applications/Codex.app/Contents/Resources/codex"
            case .processDied(let msg):
                return "Codex process exited: \(msg)"
            case .handshakeFailed:
                return "WebSocket handshake failed"
            case .initFailed(let msg):
                return "JSON-RPC initialize failed: \(msg)"
            case .quotaReadFailed(let msg):
                return "Failed to read rate limits: \(msg)"
            case .timeout:
                return "Request timed out"
            case .unexpectedFrame(let op):
                return "Unexpected WebSocket frame opcode: \(op)"
            case .processError(let msg):
                return "Process error: \(msg)"
            }
        }
    }

    // MARK: - Properties

    private let codexBinary = "/Applications/Codex.app/Contents/Resources/codex"
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var activeCodexHomeAccess: SettingsStore.ScopedCodexHomeAccess?
    private let queue = DispatchQueue(label: "com.ohmeter.codex-server")
    private var nextId = 1
    private var transportMode: TransportMode = .unknown
    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Public API

    /// Fetch current rate limits from the Codex app-server.
    /// This is the main entry point. Thread-safe (serializes on internal queue).
    func fetchQuota() async throws -> QuotaData {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QuotaData, Error>) in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: ServerError.processError("Server deallocated"))
                    return
                }
                do {
                    let result = try self.fetchQuotaSync()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Terminate the running process.
    func terminate() {
        queue.async { [weak self] in
            self?.terminateSync()
        }
    }

    // MARK: - Synchronous Implementation (runs on queue)

    private func fetchQuotaSync() throws -> QuotaData {
        if SettingsStore.shared.hasCodexHomeAccess {
            do {
                let localQuota = try readLocalQuotaFallback()
                NSLog("OhMeter: Using local Codex quota data")
                return localQuota
            } catch {
                NSLog("OhMeter: Local quota read failed: \(error.localizedDescription)")
                if isSandboxed {
                    throw error
                }
            }
        } else if isSandboxed {
            throw ServerError.quotaReadFailed("Codex data access required")
        }

        // Ensure process is running
        if process == nil || !(process?.isRunning ?? false) {
            try launchProcess()
        }

        guard let stdin = stdinPipe, let stdout = stdoutPipe else {
            throw ServerError.processError("Pipes not initialized")
        }

        // Step 1: Initialize — try detected transport mode, fall back if needed
        let initId = nextId; nextId += 1
        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": initId,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "OhMeter", "title": "OhMeter", "version": "1"],
                "capabilities": ["experimentalApi": true, "requestAttestation": false],
            ] as [String: Any]
        ]

        let initResult: [String: Any]
        if transportMode == .webSocket {
            // Already known to be WebSocket
            try sendWSFrame(stdin, json: initRequest)
            initResult = try readWSResponse(stdout, expectedId: initId, timeout: 10)
        } else {
            // Try raw JSON-RPC first (or if already confirmed)
            do {
                try sendRawJSON(stdin, json: initRequest)
                initResult = try readRawResponse(stdout, expectedId: initId, timeout: 10)
                transportMode = .rawJSONRPC
            } catch {
                NSLog("OhMeter: Raw JSON-RPC failed (\(error)), trying WebSocket...")
                // Restart process and try WebSocket
                terminateSync()
                try launchProcess()
                guard let wsStdin = stdinPipe, let wsStdout = stdoutPipe else {
                    throw ServerError.processError("Pipes not initialized after restart")
                }
                try performHandshake(wsStdout)
                try sendWSFrame(wsStdin, json: initRequest)
                initResult = try readWSResponse(wsStdout, expectedId: initId, timeout: 10)
                transportMode = .webSocket
            }
        }

        NSLog("OhMeter: Initialize response: \(initResult)")

        do {
            let usageResult = try sendRequest(method: "account/usage/read", stdin: stdin, stdout: stdout, timeout: 35)
            NSLog("OhMeter: Usage response: \(usageResult)")
            return normalizeExpiredQuota(try parseQuotaData(usageResult))
        } catch {
            NSLog("OhMeter: account/usage/read failed: \(error.localizedDescription)")
        }

        do {
            let rateLimitResult = try sendRequest(method: "account/rateLimits/read", stdin: stdin, stdout: stdout, timeout: 15)
            NSLog("OhMeter: Rate limits response: \(rateLimitResult)")
            return normalizeExpiredQuota(try parseQuotaData(rateLimitResult))
        } catch {
            NSLog("OhMeter: account/rateLimits/read failed: \(error.localizedDescription)")
        }

        do {
            let localQuota = try readLocalQuotaFallback()
            NSLog("OhMeter: Using local Codex quota fallback")
            return localQuota
        } catch {
            NSLog("OhMeter: Local quota fallback failed: \(error.localizedDescription)")
        }

        throw ServerError.timeout
    }

    private func sendRequest(method: String, stdin: Pipe, stdout: Pipe, timeout: Int) throws -> [String: Any] {
        let requestId = nextId; nextId += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": NSNull()
        ]

        if transportMode == .webSocket {
            try sendWSFrame(stdin, json: request)
            return try readWSResponse(stdout, expectedId: requestId, timeout: timeout)
        }

        try sendRawJSON(stdin, json: request)
        return try readRawResponse(stdout, expectedId: requestId, timeout: timeout)
    }

    // MARK: - Process Management

    private func launchProcess() throws {
        guard FileManager.default.fileExists(atPath: codexBinary) else {
            throw ServerError.binaryNotFound
        }

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: codexBinary)
        proc.arguments = ["app-server", "--listen", "stdio://"]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // Keep stderr SEPARATE to avoid corrupting stdout frame/line parsing
        proc.standardError = errPipe
        proc.environment = processEnvironment()

        // Drain stderr in background for logging
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let msg = String(data: data, encoding: .utf8) {
                NSLog("OhMeter [codex stderr]: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try proc.run()
        } catch {
            throw ServerError.processError("Failed to launch: \(error.localizedDescription)")
        }

        setNonBlocking(outPipe.fileHandleForReading.fileDescriptor)

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
    }

    private func processEnvironment() -> [String: String] {
        activeCodexHomeAccess?.stopAccessing()
        activeCodexHomeAccess = nil

        var env = ProcessInfo.processInfo.environment
        do {
            if let access = try SettingsStore.shared.startCodexHomeAccess() {
                activeCodexHomeAccess = access
                env["CODEX_HOME"] = access.url.path
                NSLog("OhMeter: Launching Codex with CODEX_HOME=\(access.url.path)")
            } else {
                NSLog("OhMeter: Launching Codex without external CODEX_HOME access")
            }
        } catch {
            NSLog("OhMeter: Failed to resolve Codex home bookmark: \(error.localizedDescription)")
        }
        return env
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private func terminateSync() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        activeCodexHomeAccess?.stopAccessing()
        activeCodexHomeAccess = nil
    }

    // MARK: - Raw JSON-RPC Transport (newline-delimited)

    /// Send a JSON-RPC message as a single line of JSON on stdin.
    private func sendRawJSON(_ pipe: Pipe, json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let line = String(data: data, encoding: .utf8) else {
            throw ServerError.processError("Failed to serialize JSON")
        }
        NSLog("OhMeter [send]: \(line)")
        let payload = (line + "\n").data(using: .utf8)!
        pipe.fileHandleForWriting.write(payload)
    }

    /// Read newline-delimited JSON responses until we find one matching expectedId.
    private func readRawResponse(_ stdout: Pipe, expectedId: Int, timeout: Int) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var buffer = Data()
        let fd = stdout.fileHandleForReading.fileDescriptor
        var temp = [UInt8](repeating: 0, count: 4096)

        while true {
            if Date() > deadline { throw ServerError.timeout }

            let count = Darwin.read(fd, &temp, temp.count)
            if count > 0 {
                buffer.append(temp, count: count)
            } else if count == 0 {
                if !(process?.isRunning ?? false) {
                    throw ServerError.processDied("Process exited")
                }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                if !(process?.isRunning ?? false) {
                    throw ServerError.processDied("Process exited")
                }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            } else {
                throw ServerError.processError(String(cString: strerror(errno)))
            }

            // Try to extract complete lines
            while let newlineRange = buffer.range(of: Data([0x0A])) { // \n
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                guard !lineData.isEmpty else { continue }
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                NSLog("OhMeter [recv]: \(trimmed)")

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                // Check if this is our response (by id) or a notification (no id)
                if let id = json["id"] as? Int, id == expectedId {
                    if let error = json["error"] as? [String: Any] {
                        let msg = (error["message"] as? String) ?? "unknown error"
                        throw ServerError.quotaReadFailed(msg)
                    }
                    return (json["result"] as? [String: Any]) ?? [:]
                }
                // Not our response (notification or other), keep reading
            }
        }
    }

    // MARK: - WebSocket Protocol (over stdio)

    /// Perform WebSocket upgrade handshake on the stdio pipes.
    private func performHandshake(_ stdout: Pipe) throws {
        guard let stdin = stdinPipe else { throw ServerError.handshakeFailed }

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"

        stdin.fileHandleForWriting.write(request.data(using: .utf8)!)

        // Read HTTP response
        var response = Data()
        let deadline = Date().addingTimeInterval(5)
        while !response.containsSequence([0x0D, 0x0A, 0x0D, 0x0A]) { // \r\n\r\n
            if Date() > deadline { throw ServerError.handshakeFailed }
            let byte = try readByte(stdout)
            response.append(byte)
        }

        let responseStr = String(data: response, encoding: .utf8) ?? ""
        guard responseStr.contains("101") else {
            throw ServerError.handshakeFailed
        }
    }

    /// Send a JSON-RPC message as a masked WebSocket text frame.
    private func sendWSFrame(_ pipe: Pipe, json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let payload = [UInt8](data)
        let n = payload.count

        // Masking key (random 4 bytes, required by WebSocket spec for client→server)
        let maskKey = (0..<4).map { _ in UInt8.random(in: 1...254) }
        let masked = payload.enumerated().map { i, b in b ^ maskKey[i % 4] }

        var frame = Data()
        frame.append(0x81) // FIN + text opcode

        if n < 126 {
            frame.append(0x80 | UInt8(n)) // MASK bit set
        } else if n < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8(n >> 8))
            frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((n >> (i * 8)) & 0xFF))
            }
        }
        frame.append(contentsOf: maskKey)
        frame.append(contentsOf: masked)

        pipe.fileHandleForWriting.write(frame)
    }

    /// Read a WebSocket frame from stdout and return the JSON payload.
    /// Handles ping (opcode 9) by sending pong, and skips non-text frames.
    private func readWSFrame(_ stdout: Pipe) throws -> (opcode: UInt8, payload: Data) {
        let deadline = Date().addingTimeInterval(15)

        while true {
            if Date() > deadline { throw ServerError.timeout }

            let b1 = try readByte(stdout)
            let b2 = try readByte(stdout)

            let opcode = b1 & 0x0F
            let hasMask = (b2 & 0x80) != 0
            var length = Int(b2 & 0x7F)

            if length == 126 {
                length = Int(try readByte(stdout)) << 8 | Int(try readByte(stdout))
            } else if length == 127 {
                length = 0
                for _ in 0..<8 {
                    length = (length << 8) | Int(try readByte(stdout))
                }
            }

            var maskKey: [UInt8]? = nil
            if hasMask {
                var mk = [UInt8]()
                for _ in 0..<4 { mk.append(try readByte(stdout)) }
                maskKey = mk
            }

            var payload = Data()
            for i in 0..<length {
                var byte = try readByte(stdout)
                if let mk = maskKey {
                    byte ^= mk[i % 4]
                }
                payload.append(byte)
            }

            if opcode == 9 {
                // Ping → send Pong back
                try sendPong(payload)
                continue
            }

            return (opcode, payload)
        }
    }

    /// Send a WebSocket pong frame (unmasked, server doesn't require masking for pong).
    private func sendPong(_ data: Data) throws {
        guard let stdin = stdinPipe else { return }
        let payload = [UInt8](data)
        let n = payload.count
        var frame = Data()
        frame.append(0x8A) // FIN + pong opcode
        frame.append(UInt8(n))
        frame.append(contentsOf: payload)
        stdin.fileHandleForWriting.write(frame)
    }

    /// Read response frames until we get the one matching expectedId.
    private func readWSResponse(_ stdout: Pipe, expectedId: Int, timeout: Int) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        while true {
            if Date() > deadline { throw ServerError.timeout }

            let (opcode, payload) = try readWSFrame(stdout)

            if opcode == 8 {
                // Close frame
                let msg = String(data: payload, encoding: .utf8) ?? "connection closed"
                throw ServerError.processDied(msg)
            }

            guard opcode == 1 else {
                // Skip non-text frames (binary, continuation, etc.)
                continue
            }

            guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                continue
            }

            if let id = json["id"] as? Int, id == expectedId {
                if let error = json["error"] as? [String: Any] {
                    let msg = (error["message"] as? String) ?? "unknown error"
                    throw ServerError.quotaReadFailed(msg)
                }
                return (json["result"] as? [String: Any]) ?? [:]
            }
            // Not our response, keep reading
        }
    }

    /// Read a single byte from the pipe (blocking).
    private func readByte(_ pipe: Pipe) throws -> UInt8 {
        let deadline = Date().addingTimeInterval(15)
        let fd = pipe.fileHandleForReading.fileDescriptor
        var byte: UInt8 = 0

        while true {
            if Date() > deadline { throw ServerError.timeout }
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                return byte
            }
            if count == 0 {
                if !(process?.isRunning ?? false) {
                    throw ServerError.processDied("EOF on stdout")
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            throw ServerError.processError(String(cString: strerror(errno)))
        }
    }

    // MARK: - Response Parsing

    /// Parse a timestamp that may be seconds or milliseconds since epoch.
    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let ts = value as? Double {
            // If the value is very large (> year 3000 in seconds), treat as milliseconds
            return ts > 32_503_680_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }
        if let ts = value as? Int {
            let d = Double(ts)
            return d > 32_503_680_000
                ? Date(timeIntervalSince1970: d / 1000)
                : Date(timeIntervalSince1970: d)
        }
        if let tsStr = value as? String, let ts = Double(tsStr) {
            return ts > 32_503_680_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }
        if let isoString = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: isoString) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: isoString)
        }
        return nil
    }

    private func parseQuotaData(_ result: [String: Any]) throws -> QuotaData {
        let rl = Self.preferredRateLimitPayload(from: result)

        // Try primary/secondary dict, or array of limits.
        guard let primary = rl["primary"] as? [String: Any],
              let secondary = rl["secondary"] as? [String: Any] else {
            throw ServerError.quotaReadFailed("Rate limit payload missing primary and secondary windows")
        }

        let primaryPct = Self.extractPercent(primary)
        let secondaryPct = Self.extractPercent(secondary)

        // Handle both seconds and milliseconds timestamps
        let primaryReset = Self.extractResetDate(primary)
        let secondaryReset = Self.extractResetDate(secondary)

        let planType = (rl["planType"] ?? rl["plan_type"] ?? rl["plan"] ?? result["planType"] ?? result["plan_type"]) as? String

        NSLog("OhMeter: Parsed quota — primary: \(primaryPct)%, secondary: \(secondaryPct)%, plan: \(planType ?? "nil")")

        return QuotaData(
            primaryUsedPercent: primaryPct,
            secondaryUsedPercent: secondaryPct,
            primaryResetsAt: primaryReset,
            secondaryResetsAt: secondaryReset,
            planType: planType
        )
    }

    private func normalizeExpiredQuota(_ quota: QuotaData) -> QuotaData {
        let now = Date()
        let primaryExpired = quota.primaryResetsAt.map { $0 <= now } ?? false
        let secondaryExpired = quota.secondaryResetsAt.map { $0 <= now } ?? false

        return QuotaData(
            primaryUsedPercent: primaryExpired ? 0 : quota.primaryUsedPercent,
            secondaryUsedPercent: secondaryExpired ? 0 : quota.secondaryUsedPercent,
            primaryResetsAt: primaryExpired ? nil : quota.primaryResetsAt,
            secondaryResetsAt: secondaryExpired ? nil : quota.secondaryResetsAt,
            planType: quota.planType
        )
    }

    private func readLocalQuotaFallback() throws -> QuotaData {
        let codexHome = activeCodexHomeAccess?.url ?? SettingsStore.defaultCodexHomeURL()
        let candidateRoots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]

        let files = recentJSONLFiles(under: candidateRoots).prefix(160)
        for file in files {
            if let line = try latestLineContainingRateLimits(in: file),
               let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                return try parseQuotaData(json)
            }
        }

        throw ServerError.quotaReadFailed("No local Codex rate limit cache found")
    }

    private func recentJSONLFiles(under roots: [URL]) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return url
            }
        }

        return files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }

    private func latestLineContainingRateLimits(in file: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let chunkSize = min(UInt64(1_048_576), size)
        try handle.seek(toOffset: size - chunkSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .first { $0.contains("\"rate_limits\"") }
            .map(String.init)
    }

    private static func preferredRateLimitPayload(from result: [String: Any]) -> [String: Any] {
        if let rateLimits = result["rateLimits"] as? [String: Any] {
            return rateLimits
        }
        if let rateLimits = result["rate_limits"] as? [String: Any] {
            return rateLimits
        }
        if let byId = result["rateLimitsByLimitId"] as? [String: Any] {
            if let codex = byId["codex"] as? [String: Any] {
                return codex
            }
            if let firstUseful = byId.values.compactMap({ $0 as? [String: Any] }).first(where: hasWindowPair) {
                return firstUseful
            }
        }
        if let byId = result["rate_limits_by_limit_id"] as? [String: Any] {
            if let codex = byId["codex"] as? [String: Any] {
                return codex
            }
            if let firstUseful = byId.values.compactMap({ $0 as? [String: Any] }).first(where: hasWindowPair) {
                return firstUseful
            }
        }
        if let rateLimits = result["rateLimits"] as? [[String: Any]] {
            return pickRateLimit(from: rateLimits)
        }
        if let rateLimits = result["rate_limits"] as? [[String: Any]] {
            return pickRateLimit(from: rateLimits)
        }
        if let nested = firstNestedWindowPair(in: result) {
            return nested
        }
        return result
    }

    private static func pickRateLimit(from limits: [[String: Any]]) -> [String: Any] {
        if let codex = limits.first(where: { ($0["limitId"] as? String) == "codex" || ($0["limit_id"] as? String) == "codex" }) {
            return codex
        }
        return limits.first(where: hasWindowPair) ?? limits.first ?? [:]
    }

    private static func hasWindowPair(_ dict: [String: Any]) -> Bool {
        dict["primary"] is [String: Any] && dict["secondary"] is [String: Any]
    }

    private static func firstNestedWindowPair(in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if hasWindowPair(dict) {
                return dict
            }
            for child in dict.values {
                if let found = firstNestedWindowPair(in: child) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstNestedWindowPair(in: child) {
                    return found
                }
            }
        }
        return nil
    }

    private static func extractResetDate(_ dict: [String: Any]?) -> Date? {
        guard let dict = dict else { return nil }
        for key in ["resetsAt", "resets_at", "resetAt", "reset_at", "end", "endsAt", "ends_at"] {
            if let date = parseTimestamp(dict[key]) {
                return date
            }
        }
        return nil
    }

    /// Extract usedPercent from a limit dict, handling Int, Double, or String values.
    private static func extractPercent(_ dict: [String: Any]?) -> Double {
        guard let dict = dict else { return 0 }
        let keys = ["usedPercent", "used_percent", "usage_percent", "percent", "usedPercentage", "used_percentage"]
        for key in keys {
            if let d = numericValue(dict[key]) {
                return clampPercent(d)
            }
        }
        for key in ["remainingPercent", "remaining_percent", "remainingPercentage", "remaining_percentage"] {
            if let d = numericValue(dict[key]) {
                return clampPercent(100 - d)
            }
        }
        // Fallback: compute from used/limit
        if let used = numericValue(dict["used"] ?? dict["current"]),
           let limit = numericValue(dict["limit"] ?? dict["max"] ?? dict["total"]),
           limit > 0 {
            return clampPercent((used / limit) * 100)
        }
        return 0
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }
}

// MARK: - Data Extension

private extension Data {
    func containsSequence(_ seq: [UInt8]) -> Bool {
        guard count >= seq.count else { return false }
        for i in 0...(count - seq.count) {
            if self[i..<(i + seq.count)].elementsEqual(seq) {
                return true
            }
        }
        return false
    }
}
