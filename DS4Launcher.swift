// DS4 Launcher — native macOS app to configure, start and stop ds4-server.
// Build with ./build.sh (needs only the Xcode Command Line Tools).

import AppKit
import Darwin
import SwiftUI

// MARK: - Settings

struct LaunchSettings: Codable, Equatable {
    var ds4Dir = NSHomeDirectory() + "/repo/ds4"
    var modelsDir = NSHomeDirectory() + "/repo/ds4/gguf"
    var model = ""            // empty = ds4flash.gguf default link
    var vision = ""
    var ctx = 100_000
    var tokens = 16_384
    var host = "127.0.0.1"
    var port = 8000
    var power = 100
    var kvDisk = true
    var kvDiskDir = "/tmp/ds4-kv"
    var kvDiskSpaceMB = 8192
    var ssd = false
    var ssdCache = ""
    var ssdCold = false
    var ssdFullLayers = ""
    var mtp = false
    var batched = 1
    var warmWeights = false
    var quality = false
    var cors = false
    var extra = ""
    var syncOpenCode = true
    var stopOnQuit = true

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DS4Launcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    static func load() -> LaunchSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(LaunchSettings.self, from: data) else { return LaunchSettings() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    var defaultLink: String { ds4Dir + "/ds4flash.gguf" }
    var modelPath: String { model.isEmpty ? defaultLink : model }
}

// MARK: - Helpers

struct LaunchError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

func sysctlInt(_ name: String) -> Int64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    if size == 4 { var v: Int32 = 0; sysctlbyname(name, &v, &size, nil, 0); return Int64(v) }
    var v: Int64 = 0; size = 8; sysctlbyname(name, &v, &size, nil, 0); return v
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

struct SystemInfo {
    let ramGiB: Double
    let gpuLimitGiB: Double?
    let chip: String
    static func read() -> SystemInfo {
        let ram = Double(sysctlInt("hw.memsize") ?? 0) / 1_073_741_824
        let wired = sysctlInt("iogpu.wired_limit_mb") ?? 0
        return SystemInfo(ramGiB: ram, gpuLimitGiB: wired > 0 ? Double(wired) / 1024 : nil,
                          chip: sysctlString("machdep.cpu.brand_string"))
    }
    /// macOS default GPU working-set limit is ~75% of RAM when not raised.
    var effectiveGpuGiB: Double { gpuLimitGiB ?? ramGiB * 0.75 }
}

func gib(_ bytes: Int64) -> Double { Double(bytes) / 1_073_741_824 }
func fmtGiB(_ v: Double) -> String { String(format: "%.1f GB", v) }

/// Minimal shell-style splitter for the "extra arguments" field (handles quotes and backslashes).
func shellSplit(_ s: String) throws -> [String] {
    var out: [String] = [], cur = ""
    var inS = false, inD = false, esc = false, has = false
    for ch in s {
        if esc { cur.append(ch); esc = false; has = true; continue }
        if ch == "\\" && !inS { esc = true; continue }
        if ch == "'" && !inD { inS.toggle(); has = true; continue }
        if ch == "\"" && !inS { inD.toggle(); has = true; continue }
        if ch.isWhitespace && !inS && !inD {
            if has { out.append(cur); cur = ""; has = false }
            continue
        }
        cur.append(ch); has = true
    }
    if inS || inD { throw LaunchError("Extra arguments: unclosed quote") }
    if has { out.append(cur) }
    return out
}

func shellQuote(_ a: String) -> String {
    if a.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return a }
    return "'" + a.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

// MARK: - Models on disk

enum ModelKind: String { case model, vision, support, other }

struct ModelFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bytes: Int64
    let kind: ModelKind
    let family: String

    static func classify(_ name: String) -> ModelKind {
        let n = name.lowercased()
        if n.contains("vision-encoder") || n.hasPrefix("mmproj") || n.hasSuffix("-vision.gguf") { return .vision }
        if n.contains("dspark") { return .support }
        if n.hasPrefix("deepseek-v4") || n.hasPrefix("glm-5.") || n.hasPrefix("qwen3.8") { return .model }
        return .other
    }

    static func family(_ name: String) -> String {
        let n = name.lowercased()
        if n.hasPrefix("deepseek") { return "deepseek" }
        if n.hasPrefix("glm") { return "glm" }
        if n.hasPrefix("qwen") { return "qwen" }
        return "other"
    }
}

func scanModels(_ s: LaunchSettings) -> [ModelFile] {
    var seen = Set<String>(), out: [ModelFile] = []
    let fm = FileManager.default
    for dir in [s.modelsDir, s.ds4Dir + "/gguf"] {
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                     includingPropertiesForKeys: [.fileSizeKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
        for case let url as URL in en where url.pathExtension.lowercased() == "gguf" {
            let real = url.resolvingSymlinksInPath().path
            guard !seen.contains(real) else { continue }
            seen.insert(real)
            let size = (try? fm.attributesOfItem(atPath: real)[.size] as? Int64) ?? 0
            let name = url.lastPathComponent
            out.append(ModelFile(path: url.path, name: name, bytes: size,
                                 kind: ModelFile.classify(name), family: ModelFile.family(name)))
        }
    }
    return out.sorted { $0.name < $1.name }
}

// MARK: - Command line

func buildArguments(_ s: LaunchSettings) throws -> [String] {
    let fm = FileManager.default
    let bin = s.ds4Dir + "/ds4-server"
    guard fm.isExecutableFile(atPath: bin) else { throw LaunchError("ds4-server not found in \(s.ds4Dir) — build it with make") }
    guard fm.fileExists(atPath: s.modelPath) else { throw LaunchError("Model file not found: \(s.modelPath)") }
    guard (512...1_048_576).contains(s.ctx) else { throw LaunchError("Context must be between 512 and 1,048,576") }
    guard s.tokens >= 1 else { throw LaunchError("Output tokens must be at least 1") }
    guard (1...65535).contains(s.port) else { throw LaunchError("Port must be 1–65535") }
    guard s.host.range(of: #"^[A-Za-z0-9.:\-]+$"#, options: .regularExpression) != nil else { throw LaunchError("Invalid host") }

    var a = [bin, "-m", s.modelPath]
    if !s.vision.isEmpty { a += ["--vision", s.vision] }
    a += ["--ctx", String(s.ctx), "--tokens", String(s.tokens), "--host", s.host, "--port", String(s.port)]
    if s.power != 100 { a += ["--power", String(max(1, min(100, s.power)))] }
    if s.kvDisk {
        a += ["--kv-disk-dir", s.kvDiskDir.isEmpty ? "/tmp/ds4-kv" : s.kvDiskDir,
              "--kv-disk-space-mb", String(max(64, s.kvDiskSpaceMB))]
    }
    if s.ssd {
        a.append("--ssd-streaming")
        let c = s.ssdCache.trimmingCharacters(in: .whitespaces).uppercased()
        if !c.isEmpty {
            guard c.range(of: #"^\d+(GB)?$"#, options: .regularExpression) != nil else {
                throw LaunchError("SSD cache must be an expert count (e.g. 512) or a size (e.g. 96GB)")
            }
            a += ["--ssd-streaming-cache-experts", c]
        }
        if s.ssdCold { a.append("--ssd-streaming-cold") }
        let fl = s.ssdFullLayers.trimmingCharacters(in: .whitespaces)
        if !fl.isEmpty {
            guard Int(fl) != nil else { throw LaunchError("Full layers must be a number") }
            a += ["--ssd-streaming-full-layers", fl]
        }
    }
    if s.mtp { a.append("--mtp") }
    if s.batched > 1 { a += ["--batched-session", String(s.batched)] }
    if s.warmWeights { a.append("--warm-weights") }
    if s.quality { a.append("--quality") }
    if s.cors { a.append("--cors") }
    a += try shellSplit(s.extra)
    return a
}

// MARK: - OpenCode sync

func syncOpenCode(ctx: Int, tokens: Int) -> String {
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/opencode/opencode.json")
    guard let data = try? Data(contentsOf: url),
          var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return "OpenCode: no opencode.json found"
    }
    guard var prov = root["provider"] as? [String: Any],
          var ds4 = prov["ds4"] as? [String: Any],
          var models = ds4["models"] as? [String: Any] else {
        return "OpenCode: no ds4 provider in config"
    }
    var changed = false
    for (k, v) in models {
        guard var m = v as? [String: Any] else { continue }
        var lim = m["limit"] as? [String: Any] ?? [:]
        let out = min((lim["output"] as? Int) ?? tokens, ctx)
        if (lim["context"] as? Int) != ctx || (lim["output"] as? Int) != out {
            lim["context"] = ctx; lim["output"] = out
            m["limit"] = lim; models[k] = m; changed = true
        }
    }
    guard changed else { return "OpenCode: context already \(ctx.formatted())" }
    ds4["models"] = models; prov["ds4"] = ds4; root["provider"] = prov
    let backup = url.appendingPathExtension("bak")
    if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
    guard let outData = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          (try? outData.write(to: url, options: .atomic)) != nil else {
        return "OpenCode: failed to write config"
    }
    return "OpenCode: context set to \(ctx.formatted()) (restart OpenCode)"
}

// MARK: - Server controller

struct ExternalServer: Identifiable, Hashable { let pid: Int32; let command: String; var id: Int32 { pid } }

enum ServerState: Equatable {
    case stopped, starting, ready, stopping, exited(Int32)
    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Loading model…"
        case .ready: return "Ready"
        case .stopping: return "Stopping…"
        case .exited(let c): return c == 0 ? "Exited" : "Exited with code \(c)"
        }
    }
    var color: Color {
        switch self {
        case .ready: return .green
        case .starting, .stopping: return .orange
        case .exited(let c): return c == 0 ? .secondary : .red
        case .stopped: return .secondary
        }
    }
    var isRunning: Bool { self == .starting || self == .ready || self == .stopping }
}

final class ServerController: ObservableObject {
    static let shared = ServerController()

    @Published var state: ServerState = .stopped
    @Published var log = ""
    @Published var planned: String?
    @Published var apiContext: Int?
    @Published var others: [ExternalServer] = []
    @Published var startedAt: Date?
    @Published var notice: String?
    @Published var runningCommand: String?

    private var process: Process?
    private var logOffset: UInt64 = 0
    private var runningHost = "127.0.0.1"
    private var runningPort = 8000
    private var timer: Timer?
    private var logTimer: Timer?
    /// On-screen log cap: when exceeded, keep the newest `logKeepBytes`.
    private let logMaxBytes = 256_000
    private let logKeepBytes = 192_000
    /// On-disk log cap: rotate to ds4-server.log.1 when the file passes this size.
    private let logFileMaxBytes: UInt64 = 20_000_000
    /// Never load more than this much backlog into the view at once.
    private let logReadMaxBytes: UInt64 = 256_000

    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DS4Launcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ds4-server.log")
    }()

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if self?.process != nil { self?.readLog() }
        }
        tick()
    }

    /// Append any new bytes from the server log file to the on-screen log.
    private func readLog() {
        guard let h = try? FileHandle(forReadingFrom: Self.logURL) else { return }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        if size < logOffset { logOffset = 0 }      // file was rotated
        guard size > logOffset else { return }
        if size - logOffset > logReadMaxBytes { logOffset = size - logReadMaxBytes }
        h.seek(toFileOffset: logOffset)
        let data = h.readDataToEndOfFile()
        logOffset += UInt64(data.count)
        append(String(decoding: data, as: UTF8.self))
        if logOffset > logFileMaxBytes { rotateLogFile() }
    }

    /// Keep the disk log bounded. The server opened the file with O_APPEND, so after
    /// truncation its next write lands at the (new) end instead of leaving a hole.
    private func rotateLogFile() {
        let path = Self.logURL.path
        let old = path + ".1"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.copyItem(atPath: path, toPath: old)
        truncate(path, 0)
        logOffset = 0
    }

    var pid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    func start(_ s: LaunchSettings) {
        notice = nil
        guard !state.isRunning else { return }
        do {
            let args = try buildArguments(s)
            if let clash = others.first(where: { portOf($0.command) == s.port }) {
                throw LaunchError("Another ds4-server (pid \(clash.pid)) already uses port \(s.port). Stop it first.")
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
            p.currentDirectoryURL = URL(fileURLWithPath: s.ds4Dir)
            p.standardInput = FileHandle.nullDevice

            // The server writes straight to a log file (not a pipe), so it keeps running
            // safely even if this app quits while "stop on quit" is off.
            let cmd = args.map(shellQuote).joined(separator: " ")
            let header = "$ \(cmd)\n\n"
            FileManager.default.createFile(atPath: Self.logURL.path, contents: Data(header.utf8))
            try? FileManager.default.removeItem(atPath: Self.logURL.path + ".1")
            let fd = open(Self.logURL.path, O_WRONLY | O_APPEND)
            guard fd >= 0 else { throw LaunchError("Cannot open log file \(Self.logURL.path)") }
            let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            p.standardOutput = out
            p.standardError = out
            log = ""
            logOffset = 0
            planned = nil; apiContext = nil
            p.terminationHandler = { [weak self] pr in
                DispatchQueue.main.async { self?.didExit(pr.terminationStatus) }
            }
            try p.run()
            try? out.close()   // the child keeps its own copy of the descriptor
            readLog()
            process = p
            runningHost = s.host
            runningPort = s.port
            runningCommand = cmd
            startedAt = Date()
            state = .starting
            if s.syncOpenCode { notice = syncOpenCode(ctx: s.ctx, tokens: s.tokens) }
        } catch {
            notice = error.localizedDescription
        }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        state = .stopping
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Called on app quit: stop synchronously so we don't leave an orphaned server.
    func shutdownForQuit() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    func stopExternal(_ e: ExternalServer) {
        kill(e.pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if kill(e.pid, 0) == 0 { kill(e.pid, SIGKILL) }
        }
    }

    private func append(_ text: String) {
        log += text
        if log.utf8.count > logMaxBytes {
            var tail = String(decoding: log.utf8.suffix(logKeepBytes), as: UTF8.self)
            if let nl = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: nl)...]) }
            log = "… older lines trimmed (full log: \(Self.logURL.path))\n" + tail
        }
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("memory:") && line.contains("planned"),
               let r = line.range(of: "memory:") {
                planned = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func didExit(_ code: Int32) {
        readLog()
        process = nil
        startedAt = nil
        runningCommand = nil
        apiContext = nil
        state = (state == .stopping) ? .stopped : .exited(code)
    }

    private func tick() {
        if let _ = pid, state == .starting || state == .ready {
            probe(host: runningHost, port: runningPort)
        }
        let mine = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = findServers().filter { $0.pid != mine }
            DispatchQueue.main.async { if self?.others != found { self?.others = found } }
        }
    }

    private func probe(host: String, port: Int) {
        let h = (host == "0.0.0.0" || host.isEmpty) ? "127.0.0.1" : host
        guard let url = URL(string: "http://\(h):\(port)/v1/models") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            var ctx: Int?
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok, let data,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let first = (j["data"] as? [[String: Any]])?.first {
                ctx = first["context_length"] as? Int
            }
            DispatchQueue.main.async {
                guard let self, self.process?.isRunning == true else { return }
                if ok && self.state == .starting { self.state = .ready }
                if ok { self.apiContext = ctx }
            }
        }.resume()
    }

    func portOf(_ cmd: String) -> Int {
        let parts = cmd.split(separator: " ").map(String.init)
        if let i = parts.firstIndex(of: "--port"), i + 1 < parts.count, let p = Int(parts[i + 1]) { return p }
        return 8000
    }
}

/// URLs other machines can use: the Bonjour .local name plus each LAN IPv4 address.
let localHostName: String = runCapture("/usr/sbin/scutil", ["--get", "LocalHostName"])
    .trimmingCharacters(in: .whitespacesAndNewlines)

func lanURLs(port: Int) -> [String] {
    var out: [String] = []
    if !localHostName.isEmpty { out.append("http://\(localHostName).local:\(port)/v1") }
    var ifap: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifap) == 0, let first = ifap {
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254.") { out.append("http://\(ip):\(port)/v1") }
                }
            }
            p = ifa.ifa_next
        }
        freeifaddrs(first)
    }
    return out
}

func runCapture(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

func findServers() -> [ExternalServer] {
    runCapture("/usr/bin/pgrep", ["-f", "ds4-server"]).split(whereSeparator: \.isNewline).compactMap { line in
        guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { return nil }
        let cmd = runCapture("/bin/ps", ["-o", "command=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let exe = cmd.split(separator: " ").first, exe.hasSuffix("ds4-server") else { return nil }
        return ExternalServer(pid: pid, command: cmd)
    }
}

// MARK: - Views

struct LogView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.backgroundColor = .textBackgroundColor
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, tv.string != text else { return }
        let atBottom = sv.verticalScroller.map { $0.floatValue > 0.98 } ?? true || tv.string.isEmpty
        tv.string = text
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var s = LaunchSettings.load()
    @Published var models: [ModelFile] = []
    @Published var sys = SystemInfo.read()
    @Published var copied = false
}

struct ContentView: View {
    // Command Line Tools ship without the SwiftUI macro plugin, so no @State: keep state in an ObservableObject.
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var server = ServerController.shared

    private var s: LaunchSettings { get { model.s } nonmutating set { model.s = newValue } }
    private var models: [ModelFile] { get { model.models } nonmutating set { model.models = newValue } }
    private var sys: SystemInfo { get { model.sys } nonmutating set { model.sys = newValue } }
    private var copied: Bool { get { model.copied } nonmutating set { model.copied = newValue } }

    private let ctxPresets: [(String, Int)] = [("8K", 8192), ("32K", 32768), ("64K", 65536), ("100K", 100_000),
                                               ("256K", 262_144), ("384K", 393_216), ("1M", 1_000_000)]

    var selectedModel: ModelFile? {
        let target = URL(fileURLWithPath: s.modelPath).resolvingSymlinksInPath().path
        return models.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == target }
    }

    var defaultTargetName: String {
        let t = URL(fileURLWithPath: s.defaultLink).resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: t.path) ? t.lastPathComponent : "missing"
    }

    /// Rough memory estimate. Context cost is measured for DeepSeek V4 Flash on Metal
    /// (≈0.36 GB + 15.3 KB/token incl. buffers); other families are shown as model size only.
    var estimate: (total: Double, exact: Bool)? {
        guard let m = selectedModel else { return nil }
        let model = gib(m.bytes)
        if m.family == "deepseek" {
            let perSession = 0.36 + Double(s.ctx) * 1.529e-5
            return (model + perSession * Double(max(1, s.batched)), true)
        }
        return (model, false)
    }

    var commandPreview: Result<String, Error> {
        Result { try buildArguments(s).map(shellQuote).joined(separator: " ") }
    }

    var body: some View {
        HSplitView {
            settingsForm.frame(minWidth: 430, idealWidth: 470, maxWidth: 560, maxHeight: .infinity)
            rightPane.frame(minWidth: 520, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear { refreshModels() }
        .onChange(of: s) { _, new in new.save() }
    }

    // MARK: form

    var settingsForm: some View {
        Form {
          Group {
            Section("Model") {
                Picker("Model", selection: $model.s.model) {
                    Text("Default link — \(defaultTargetName)").tag("")
                    let main = models.filter { $0.kind == .model }
                    if !main.isEmpty {
                        Divider()
                        ForEach(main) { m in Text("\(m.name)  ·  \(fmtGiB(gib(m.bytes)))").tag(m.path) }
                    }
                    let other = models.filter { $0.kind == .other }
                    if !other.isEmpty {
                        Divider()
                        ForEach(other) { m in Text("\(m.name)  ·  \(fmtGiB(gib(m.bytes)))  (may be unsupported)").tag(m.path) }
                    }
                }
                let visions = models.filter { $0.kind == .vision }
                if !visions.isEmpty {
                    Picker("Vision encoder", selection: $model.s.vision) {
                        Text("None").tag("")
                        ForEach(visions) { m in Text(m.name).tag(m.path) }
                    }
                }
                HStack {
                    Text(s.modelsDir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose folder…") { chooseFolder(\.modelsDir) }.controlSize(.small)
                    Button("Refresh") { refreshModels() }.controlSize(.small)
                }
            }

            Section("Context") {
                HStack {
                    TextField("Context tokens", value: $model.s.ctx, format: .number).frame(maxWidth: 140)
                    Menu("Presets") {
                        ForEach(ctxPresets, id: \.1) { p in Button(p.0) { s.ctx = p.1 } }
                    }.fixedSize()
                }
                TextField("Default output tokens", value: $model.s.tokens, format: .number)
                Stepper("Parallel sessions: \(s.batched)", value: $model.s.batched, in: 1...16)
            }

            Section("Memory mode") {
                Toggle("SSD streaming (for models larger than memory)", isOn: $model.s.ssd)
                if s.ssd {
                    TextField("Expert cache (e.g. 512 or 96GB, empty = auto)", text: $model.s.ssdCache)
                    TextField("GLM: fully resident first N layers (empty = auto)", text: $model.s.ssdFullLayers)
                    Toggle("Cold start (skip expert preload)", isOn: $model.s.ssdCold)
                }
                Toggle("Warm weights at startup", isOn: $model.s.warmWeights)
            }

            Section("Disk KV cache") {
                Toggle("Save prompt caches to disk", isOn: $model.s.kvDisk)
                if s.kvDisk {
                    HStack {
                        TextField("Directory", text: $model.s.kvDiskDir)
                        Button("…") { chooseFolder(\.kvDiskDir) }.controlSize(.small)
                    }
                    TextField("Budget (MB)", value: $model.s.kvDiskSpaceMB, format: .number)
                }
            }

            Section("Speed & quality") {
                Toggle("MTP speculative decoding (--mtp)", isOn: $model.s.mtp)
                Toggle("Prefer exact kernels (--quality)", isOn: $model.s.quality)
                VStack(alignment: .leading) {
                    Text("GPU power target: \(s.power)%")
                    Slider(value: Binding(get: { Double(s.power) }, set: { s.power = Int($0) }), in: 10...100, step: 5)
                }
            }

            Section("Network") {
                Toggle(isOn: Binding(get: { s.host == "0.0.0.0" },
                                     set: { s.host = $0 ? "0.0.0.0" : "127.0.0.1" })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow access from other machines on the network")
                        Text(s.host == "0.0.0.0"
                             ? "No authentication — anyone on your network can use it."
                             : "Only this Mac can connect.")
                            .font(.caption).foregroundStyle(s.host == "0.0.0.0" ? .orange : .secondary)
                    }
                }
                if s.host == "0.0.0.0" {
                    ForEach(lanURLs(port: s.port), id: \.self) { u in
                        HStack {
                            Text(u).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(u, forType: .string)
                            }.controlSize(.small)
                        }
                    }
                }
                TextField("Port", value: $model.s.port, format: .number.grouping(.never))
                Toggle("CORS headers for browser clients", isOn: $model.s.cors)
            }

            Section("Advanced") {
                TextField("Extra arguments", text: $model.s.extra, prompt: Text("e.g. --prefill-chunk 2048"))
                HStack {
                    Text(s.ds4Dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("ds4 folder…") { chooseFolder(\.ds4Dir) }.controlSize(.small)
                }
                Toggle("Sync OpenCode context limit on start", isOn: $model.s.syncOpenCode)
                Toggle("Stop server when this app quits", isOn: $model.s.stopOnQuit)
                Button("Reset to defaults") { s = LaunchSettings() }.controlSize(.small)
            }
          }
          // Lock the controls while running, but not the Form itself: disabling the
          // Form also disables its scroll view, which made the settings unscrollable.
          .disabled(locked)
        }
        .formStyle(.grouped)
    }

    private var locked: Bool { server.state.isRunning }

    // MARK: right pane

    var rightPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader
            memoryBox
            commandBox
            if !server.others.isEmpty { othersBox }
            Text("Server log").font(.headline)
            LogView(text: server.log)
                .frame(minHeight: 160, maxHeight: .infinity)
                .layoutPriority(1)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
        .padding(16)
    }

    var statusHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(server.state.color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.state.label).font(.title2.weight(.semibold))
                Group {
                    if let pid = server.pid {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("pid \(pid) · up \(uptime) · "
                                 + (s.host == "0.0.0.0" ? "network: \(lanURLs(port: s.port).first ?? "all interfaces")"
                                                        : "http://127.0.0.1:\(String(s.port))/v1")
                                 + (server.apiContext.map { " · ctx \($0.formatted())" } ?? ""))
                        }
                    } else {
                        Text("\(sys.chip) · \(fmtGiB(sys.ramGiB)) RAM · GPU limit \(fmtGiB(sys.effectiveGpuGiB))")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if server.state.isRunning {
                Button(role: .destructive) { server.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(.large).disabled(server.state == .stopping)
            } else {
                Button { server.start(s) } label: { Label("Start server", systemImage: "play.fill") }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    var uptime: String {
        guard let t = server.startedAt else { return "-" }
        let sec = Int(Date().timeIntervalSince(t))
        return sec < 3600 ? String(format: "%d:%02d", sec / 60, sec % 60)
                          : String(format: "%d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60)
    }

    var memoryBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let planned = server.planned {
                    Text("Planned by server: \(planned)").font(.callout).textSelection(.enabled)
                } else if let e = estimate {
                    let limit = sys.effectiveGpuGiB
                    let fits = e.total <= limit - 4
                    HStack {
                        Text(e.exact ? "Estimated memory: \(fmtGiB(e.total))"
                                     : "Model weights: \(fmtGiB(e.total)) + context (shown after start)")
                        Spacer()
                        Text("GPU limit \(fmtGiB(limit))").foregroundStyle(.secondary)
                    }.font(.callout)
                    ProgressView(value: min(e.total, limit), total: limit)
                        .tint(fits ? .accentColor : (s.ssd ? .orange : .red))
                    if !fits && !s.ssd {
                        Label("Probably won't fit in GPU memory — enable SSD streaming or lower the context.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                    } else if s.ssd && fits {
                        Label("Fits in memory — SSD streaming will only make it slower.",
                              systemImage: "info.circle").foregroundStyle(.secondary).font(.caption)
                    } else if s.ssd {
                        Label("Streaming experts from the SSD — expect slower generation.",
                              systemImage: "internaldrive").foregroundStyle(.secondary).font(.caption)
                    }
                } else {
                    Text("Select a model to see the memory estimate.").foregroundStyle(.secondary)
                }
                if let n = server.notice {
                    Text(n).font(.caption).foregroundStyle(n.hasPrefix("OpenCode") ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Memory") }
    }

    var commandBox: some View {
        GroupBox {
            HStack(alignment: .top) {
                switch commandPreview {
                case .success(let cmd):
                    Text(server.runningCommand ?? cmd).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("cd \(shellQuote(s.ds4Dir)) && " + (server.runningCommand ?? cmd), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }.controlSize(.small)
                case .failure(let err):
                    Label(err.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: { Text("Command") }
    }

    var othersBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(server.others) { o in
                    HStack {
                        Text("pid \(o.pid)").font(.caption.monospacedDigit())
                        Text(o.command).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Stop") { server.stopExternal(o) }.controlSize(.small)
                    }
                }
            }
        } label: { Label("Other ds4-server processes (started outside this app)", systemImage: "exclamationmark.circle") }
    }

    // MARK: actions

    func refreshModels() {
        let snapshot = s
        DispatchQueue.global(qos: .userInitiated).async {
            let found = scanModels(snapshot)
            DispatchQueue.main.async { models = found; sys = SystemInfo.read() }
        }
    }

    func chooseFolder(_ key: WritableKeyPath<LaunchSettings, String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: s[keyPath: key])
        if panel.runModal() == .OK, let url = panel.url {
            s[keyPath: key] = url.path
            if key == \LaunchSettings.modelsDir || key == \LaunchSettings.ds4Dir { refreshModels() }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        if LaunchSettings.load().stopOnQuit { ServerController.shared.shutdownForQuit() }
    }
}

@main
struct DS4LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("DS4 Launcher", id: "main") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
