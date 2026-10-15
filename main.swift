import Cocoa
import SwiftUI
import AVFoundation
import Combine
import ServiceManagement
import Carbon.HIToolbox
import CoreAudio

// MARK: - Model

enum Phase { case idle, recording, transcribing, done, error, downloading }

final class Model: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var level: CGFloat = 0
    @Published var visible = false
    @Published var message = ""
    @Published var history: [CGFloat] = Array(repeating: 0, count: 22)
}

// MARK: - Выбор микрофона и захват звука

struct InputDevice: Hashable { let uid: String; let name: String }

func listInputDevices() -> [InputDevice] {
    AVCaptureDevice.devices(for: .audio).map { InputDevice(uid: $0.uniqueID, name: $0.localizedName) }
}

/// Захват через AVCaptureSession: выбранный микрофон подключается напрямую, без побочных эффектов на вывод звука.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "voxa.audio")
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var ok = 0, failed = 0
    private(set) var lastFormat = "—"
    private(set) var lastError = ""
    private(set) var deviceName = "—"
    private var obs: [NSObjectProtocol] = []

    var stats: String { "устройство=\(deviceName) буферов ok=\(ok) сбоев=\(failed) формат=\(lastFormat) ошибка=\(lastError.isEmpty ? "нет" : lastError)" }

    func start(uid: String) throws {
        stop()
        ok = 0; failed = 0; lastFormat = "—"; lastError = ""
        guard let dev = (uid.isEmpty ? nil : AVCaptureDevice(uniqueID: uid)) ?? AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Микрофон не найден"])
        }
        deviceName = dev.localizedName
        let input = try AVCaptureDeviceInput(device: dev)
        let out = AVCaptureAudioDataOutput()
        // любой микрофон (моно/стерео/многоканальный, любая частота) отдаём системой сразу как 16 кГц моно float32
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                             AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        out.setSampleBufferDelegate(self, queue: queue)
        obs = [NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] n in
            self?.lastError = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "ошибка сессии"
        }]
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(out) else {
            session.commitConfiguration()
            throw NSError(domain: "audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось подключить микрофон"])
        }
        session.addInput(input); session.addOutput(out)
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        obs.forEach { NotificationCenter.default.removeObserver($0) }; obs = []
        let s = session
        queue.sync {
            if s.isRunning { s.stopRunning() }
            s.inputs.forEach { s.removeInput($0) }
            s.outputs.forEach { s.removeOutput($0) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let fmt = AVAudioFormat(streamDescription: asbd) else { failed += 1; lastError = "неизвестный формат звука"; return }
        lastFormat = "\(Int(fmt.sampleRate)) Гц, \(fmt.channelCount) кан."
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        pcm.frameLength = AVAudioFrameCount(n)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList)
        guard st == noErr else { failed += 1; lastError = "копирование звука: \(st)"; return }
        ok += 1
        onBuffer?(pcm)
    }
}

/// Приводит звук к 16 кГц моно float для Whisper и считает уровень 0…1.
final class Resampler {
    let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var conv: AVAudioConverter?
    private var inFmt: AVAudioFormat?

    func convert(_ buf: AVAudioPCMBuffer) -> (AVAudioPCMBuffer, Float)? {
        if inFmt != buf.format { inFmt = buf.format; conv = AVAudioConverter(from: buf.format, to: outFmt) }
        guard let conv = conv else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var given = false
        conv.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        var level: Float = 0
        if let ch = out.floatChannelData?[0], out.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(out.frameLength) { sum += ch[i] * ch[i] }
            let db = 20 * log10(max(sqrt(sum / Float(out.frameLength)), 1e-6))
            level = max(0, min(1, (db + 50) / 38))
        }
        return (out, level)
    }
}

func micAccessError() -> NSError? {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return nil
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        return NSError(domain: "mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Разреши микрофон и повтори"])
    default:
        return NSError(domain: "mic", code: 2, userInfo: [NSLocalizedDescriptionKey: "Нет доступа к микрофону"])
    }
}

/// Живой уровень микрофона в окне настроек.
final class MicMeter: ObservableObject {
    static let shared = MicMeter()
    @Published var level: Double = 0
    private let cap = AudioCapture()
    private let rs = Resampler()

    func start() {
        stop()
        guard Perm.mic.granted else { return }
        cap.onBuffer = { [weak self] buf in
            guard let self = self, let (_, lv) = self.rs.convert(buf) else { return }
            DispatchQueue.main.async { self.level = max(Double(lv), self.level * 0.8) }
        }
        try? cap.start(uid: Prefs.shared.micUID)
    }

    func stop() { cap.stop(); cap.onBuffer = nil; level = 0 }
}

// MARK: - Recorder (16 kHz mono WAV for whisper)

final class Recorder {
    private let cap = AudioCapture()
    private let rs = Resampler()
    private var file: AVAudioFile?
    private(set) var frames = 0
    var onLevel: ((Float) -> Void)?

    var stats: String { cap.stats }

    func start(to url: URL, forceDefault: Bool = false) throws {
        if let e = micAccessError() { throw e }
        frames = 0
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        cap.onBuffer = { [weak self] buf in
            guard let self = self, let (out, lv) = self.rs.convert(buf) else { return }
            self.frames += Int(out.frameLength)
            try? self.file?.write(from: out)
            self.onLevel?(lv)
        }
        try cap.start(uid: forceDefault ? "" : Prefs.shared.micUID)
    }

    func stop() {
        cap.stop()
        cap.onBuffer = nil
        file = nil
    }
}

// MARK: - Whisper

enum Whisper {
    static var bin: String? {
        let bundled = Bundle.main.resourcePath.map { $0 + "/whisper/bin/whisper-cli" }
        return ([bundled].compactMap { $0 } + ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var current: Process?
    /// Переезд моделей из старой папки «Диктовка» (чтобы не скачивать 1,6 ГБ заново)
    static func migrateOldDir() {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        guard !fm.fileExists(atPath: dir.path) else { return }
        for old in ["Шёпот", "Диктовка"] {
            let u = base.appendingPathComponent(old)
            if fm.fileExists(atPath: u.path) { try? fm.moveItem(at: u, to: dir); return }
        }
    }
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Voxa")
    static let turbo = dir.appendingPathComponent("ggml-large-v3-turbo.bin")
    static let turboURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static var model: String? {
        for name in ["ggml-large-v3-turbo.bin", "ggml-small.bin"] {
            let u = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u.path }
        }
        return nil
    }

    /// Whisper на тишине в конце часто «дорисовывает» титры — вырезаем.
    static func clean(_ t: String) -> String {
        let junk = ["Редактор субтитров.*", "Корректор.*", "Субтитры (сделал|создал|подготовил|делал).*",
                    "Продолжение следует\\.*", "Спасибо за (просмотр|внимание)[.!]*", "Подписывайтесь на канал[.!]*",
                    "Thanks for watching[.!]*", "Subtitles by.*", "Amara\\.org.*", "Dimatorzok.*"]
        var r = t
        for j in junk { r = r.replacingOccurrences(of: j, with: "", options: [.regularExpression, .caseInsensitive]) }
        return r
    }

    static func transcribe(_ wav: URL, lang: String, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bin = bin else {
                return completion(.failure(NSError(domain: "whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "whisper-cli не найден"])))
            }
            let p = Process()
            current = p
            p.executableURL = URL(fileURLWithPath: bin)
            guard let model = model else {
                return completion(.failure(NSError(domain: "whisper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Модель ещё не скачана"])))
            }
            p.arguments = ["-m", model, "-f", wav.path, "-l", lang, "-nt", "-np", "-t", "8", "-sns", "-mc", "0"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                var timedOut = false
                DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if p.isRunning { timedOut = true; p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if timedOut { return completion(.failure(NSError(domain: "whisper", code: 3, userInfo: [NSLocalizedDescriptionKey: "Слишком долго, попробуй ещё раз"]))) }
                var text = String(data: data, encoding: .utf8) ?? ""
                text = text.replacingOccurrences(of: "\\[[A-Z_ ]+\\]|\\([^)]*\\)", with: "", options: .regularExpression)
                text = clean(text)
                text = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch { completion(.failure(error)) }
        }
    }
}

extension Notification.Name { static let prefsChanged = Notification.Name("prefsChanged") }
let panelW: CGFloat = 720, panelH: CGFloat = 340

// MARK: - Permissions

enum Perm: Int, CaseIterable {
    case mic, access, input
    var title: String { ["Микрофон", "Универсальный доступ", "Мониторинг ввода"][rawValue] }
    var why: String { ["чтобы слышать твой голос", "чтобы вставлять текст", "чтобы ловить правый ⌥"][rawValue] }
    var granted: Bool {
        switch self {
        case .mic: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .access: return AXIsProcessTrusted()
        case .input: return CGPreflightListenEventAccess()
        }
    }
    func request() {
        func pane(_ n: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(n)")!)
            }
        }
        switch self {
        case .mic:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
            else { pane("Privacy_Microphone") }
        case .access:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            pane("Privacy_Accessibility")
        case .input:
            _ = CGRequestListenEventAccess()
            pane("Privacy_ListenEvent")
        }
    }
    static var allGranted: Bool { allCases.allSatisfy { $0.granted } }
}

// MARK: - Prefs

final class Prefs: ObservableObject {
    static let shared = Prefs()
    @Published var style: Int { didSet { UserDefaults.standard.set(style, forKey: "style"); NotificationCenter.default.post(name: .prefsChanged, object: nil) } }
    @Published var opacity: Double { didSet { UserDefaults.standard.set(opacity, forKey: "opacity"); NotificationCenter.default.post(name: .prefsChanged, object: nil) } }
    @Published var position: Int { didSet { UserDefaults.standard.set(position, forKey: "position"); NotificationCenter.default.post(name: .prefsChanged, object: nil) } }
    @Published var autoSend: Bool { didSet { UserDefaults.standard.set(autoSend, forKey: "autoSend") } }
    @Published var micUID: String { didSet { UserDefaults.standard.set(micUID, forKey: "micUID") } }
    @Published var scale: Double { didSet { UserDefaults.standard.set(scale, forKey: "scale"); NotificationCenter.default.post(name: .prefsChanged, object: nil) } }
    init() {
        micUID = UserDefaults.standard.string(forKey: "micUID") ?? ""
        autoSend = UserDefaults.standard.bool(forKey: "autoSend")
        position = UserDefaults.standard.object(forKey: "position") as? Int ?? 7
        let sc = UserDefaults.standard.double(forKey: "scale")
        scale = sc == 0 ? 1 : sc
        style = UserDefaults.standard.integer(forKey: "style")
        let o = UserDefaults.standard.double(forKey: "opacity")
        opacity = o == 0 ? 1 : o
    }
}

// MARK: - Overlay UI

func phasePalette(_ p: Phase) -> [Color] {
    switch p {
    case .transcribing, .downloading: return [Color(red: 0.2, green: 0.8, blue: 1), Color(red: 0.4, green: 0.4, blue: 1), Color(red: 0.8, green: 0.4, blue: 1)]
    case .done: return [Color(red: 0.3, green: 1, blue: 0.6), Color(red: 0.2, green: 0.9, blue: 0.9), Color(red: 0.6, green: 1, blue: 0.4)]
    case .error: return [.red, .orange, .pink]
    default: return [Color(red: 1, green: 0.35, blue: 0.55), Color(red: 1, green: 0.65, blue: 0.2), Color(red: 0.6, green: 0.35, blue: 1)]
    }
}

func phaseGlow(_ p: Phase) -> Color {
    switch p {
    case .transcribing, .downloading: return .cyan
    case .done: return .green
    case .error: return .red
    default: return Color(red: 1, green: 0.4, blue: 0.6)
    }
}

func phaseTitle(_ m: Model) -> String {
    switch m.phase {
    case .recording: return "Слушаю…"
    case .transcribing: return "Расшифровываю…"
    case .done: return "Готово ✨"
    case .error: return m.message
    case .downloading: return m.message
    case .idle: return ""
    }
}

func effLevel(_ m: Model, _ t: Double) -> Double {
    switch m.phase {
    case .recording: return Double(m.level)
    case .transcribing, .downloading: return 0.5 + 0.2 * sin(t * 4)
    case .done: return 0.2
    default: return 0.1
    }
}

// Стиль 0: живой шар
struct OrbView: View {
    @ObservedObject var m: Model
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let palette = phasePalette(m.phase)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.20
                let lvl = effLevel(m, t)
                let speed: Double = m.phase == .transcribing ? 3.2 : 1.4
                for (i, col) in palette.enumerated() {
                    var path = Path()
                    let steps = 72
                    let k = Double(i + 2)
                    for s in 0...steps {
                        let a: Double = Double(s) / Double(steps) * 2.0 * Double.pi
                        let phase: Double = t * speed * (1.0 + Double(i) * 0.4) + Double(i) * 2.0
                        let wob: Double = sin(a * k + phase)
                        let breathe: Double = 1.0 + 0.10 * sin(t * 2.0 + Double(i))
                        let amp: Double = 0.10 + 0.45 * lvl
                        let r = CGFloat(Double(base) * (breathe + wob * amp))
                        let p = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
                        s == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    path.closeSubpath()
                    ctx.drawLayer { l in
                        l.addFilter(.blur(radius: 2))
                        l.blendMode = .plusLighter
                        l.fill(path, with: .color(col.opacity(0.75)))
                    }
                }
                let core = Path(ellipseIn: CGRect(x: c.x - base * 0.45, y: c.y - base * 0.45, width: base * 0.9, height: base * 0.9))
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 6))
                    l.fill(core, with: .color(.white.opacity(0.55)))
                }
            }
        }
    }
}

// Стиль 1: волны в духе Siri
struct SiriView: View {
    @ObservedObject var m: Model
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let pal = phasePalette(m.phase)
                let lvl = effLevel(m, t)
                let w = Double(size.width), h = Double(size.height), midY = h / 2
                for i in 0..<5 {
                    var path = Path()
                    let col = pal[i % pal.count]
                    let freq = 1.0 + Double(i) * 0.55
                    let dir: Double = i % 2 == 0 ? 1 : -1
                    let sp = (m.phase == .transcribing ? 3.6 : 1.7) * (1 + Double(i) * 0.25) * dir
                    let ph = Double(i) * 1.3
                    let amp = h * 0.40 * (0.10 + 0.90 * lvl) * (1 - Double(i) * 0.13)
                    var x = 0.0
                    while x <= w {
                        let nx = x / w
                        let env = pow(sin(Double.pi * nx), 2)
                        let y = midY + amp * env * sin(nx * freq * 2 * Double.pi + t * sp + ph)
                        let pt = CGPoint(x: x, y: y)
                        x == 0 ? path.move(to: pt) : path.addLine(to: pt)
                        x += 3
                    }
                    ctx.drawLayer { l in
                        l.addFilter(.blur(radius: 6))
                        l.blendMode = .plusLighter
                        l.stroke(path, with: .color(col.opacity(0.85)), lineWidth: 6)
                    }
                    ctx.drawLayer { l in
                        l.blendMode = .plusLighter
                        l.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
            }
        }
    }
}

// Стиль 2: зеркальный эквалайзер в стеклянной плашке
struct EqView: View {
    @ObservedObject var m: Model
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let pal = phasePalette(m.phase)
            let n = m.history.count
            HStack(spacing: 3) {
                ForEach(0..<(n * 2), id: \.self) { j in
                    let i = j < n ? (n - 1 - j) : (j - n)   // зеркально от центра
                    let v: Double = {
                        switch m.phase {
                        case .recording: return Double(m.history[n - 1 - i])
                        case .transcribing: return 0.3 + 0.3 * sin(t * 6 - Double(i) * 0.5)
                        default: return 0.06
                        }
                    }()
                    let frac = Double(j) / Double(n * 2 - 1)
                    Capsule()
                        .fill(pal[min(pal.count - 1, Int(frac * Double(pal.count)))])
                        .frame(width: 3, height: 4 + CGFloat(max(0, min(1, v))) * 40)
                }
            }
            .frame(height: 48)
        }
    }
}

// Шар в духе Siri: внутри переливающиеся цветные пятна
struct SiriOrb: View {
    @ObservedObject var m: Model
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let pal = phasePalette(m.phase)
                let lvl = CGFloat(effLevel(m, t))
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) * 0.30 * (1 + 0.14 * lvl)
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                let spin: Double = m.phase == .transcribing ? 2.4 : 0.9
                ctx.fill(circle, with: .radialGradient(Gradient(colors: [Color(white: 0.16), Color(white: 0.02)]), center: c, startRadius: 0, endRadius: r))
                ctx.drawLayer { l in
                    l.clip(to: circle)
                    l.addFilter(.blur(radius: r * 0.28))
                    l.blendMode = .plusLighter
                    for i in 0..<5 {
                        let k = Double(i)
                        let a = t * spin * (0.8 + k * 0.23) + k * 1.9
                        let d = Double(r) * (0.35 + 0.25 * Double(lvl))
                        let bx = c.x + CGFloat(cos(a) * d)
                        let by = c.y + CGFloat(sin(a * 1.3 + k) * d)
                        let br = r * (0.50 + 0.18 * CGFloat(sin(t * 2 + k)))
                        let blob = Path(ellipseIn: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2))
                        l.fill(blob, with: .color(pal[i % pal.count].opacity(0.9)))
                    }
                }
                // блик и ободок
                let hl = Path(ellipseIn: CGRect(x: c.x - r * 0.62, y: c.y - r * 0.85, width: r * 0.9, height: r * 0.45))
                ctx.drawLayer { l in
                    l.clip(to: circle)
                    l.addFilter(.blur(radius: 3))
                    l.fill(hl, with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .white.opacity(0)]), startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y - r * 0.3)))
                }
                ctx.stroke(circle, with: .linearGradient(Gradient(colors: [.white.opacity(0.7), .white.opacity(0.08), .white.opacity(0.35)]), startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)), lineWidth: 1.2)
            }
        }
        .shadow(color: phaseGlow(m.phase).opacity(0.7), radius: 12)
    }
}

struct Visual: View {
    @ObservedObject var m: Model
    var style: Int
    var body: some View {
        let glow = phaseGlow(m.phase)
        switch style {
        case 1:
            VStack(spacing: 0) {
                SiriView(m: m).frame(width: 380, height: 120)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                Text(phaseTitle(m)).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 3)
            }
        case 3:
            VStack(spacing: 2) {
                SiriOrb(m: m).frame(width: 150, height: 150)
                Text(phaseTitle(m)).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 3)
            }
        case 2:
            VStack(spacing: 6) {
                EqView(m: m)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.88), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                Text(phaseTitle(m)).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.85))
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            )
            .shadow(color: glow.opacity(0.35), radius: 12)
        default:
            HStack(spacing: 10) {
                OrbView(m: m).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(phaseTitle(m)).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    BarsView(m: m)
                }
                .frame(width: 132, alignment: .leading).clipped()
            }
            .padding(.leading, 10).padding(.trailing, 20).padding(.vertical, 8)
            .background(
                Capsule().fill(Color.black.opacity(0.82))
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [glow.opacity(0.9), .white.opacity(0.1), glow.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
            )
            .shadow(color: glow.opacity(0.5), radius: 14)
        }
    }
}

struct BarsView: View {
    @ObservedObject var m: Model
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<m.history.count, id: \.self) { i in
                    let h: CGFloat = {
                        switch m.phase {
                        case .recording: return m.history[i]
                        case .transcribing: return 0.25 + 0.25 * CGFloat(sin(t * 6 - Double(i) * 0.5))
                        default: return 0.08
                        }
                    }()
                    let pal = phasePalette(m.phase)
                    Capsule()
                        .fill(LinearGradient(colors: [pal[0], pal[min(2, pal.count - 1)]], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: 3 + max(0, h) * 24)
                }
            }
            .frame(height: 28)
        }
    }
}

struct OverlayView: View {
    @ObservedObject var m: Model
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        let col = prefs.position % 3, row = prefs.position / 3
        let hs: [HorizontalAlignment] = [.leading, .center, .trailing]
        let vs: [VerticalAlignment] = [.top, .center, .bottom]
        let anchor = UnitPoint(x: [0, 0.5, 1][col], y: [0, 0.5, 1][row])
        Visual(m: m, style: prefs.style)
            .opacity(m.visible ? prefs.opacity : 0)
            .scaleEffect(m.visible ? CGFloat(prefs.scale) : 0.5 * CGFloat(prefs.scale), anchor: anchor)
            .offset(y: m.visible ? 0 : (row == 0 ? -20 : 20))
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: m.visible)
            .animation(.easeInOut(duration: 0.3), value: m.phase)
            .padding(44)
            .frame(width: panelW, height: panelH, alignment: Alignment(horizontal: hs[col], vertical: vs[row]))
    }
}

// MARK: - Settings

final class Demo: ObservableObject {
    let model = Model()
    private var timer: Timer?
    init() {
        model.phase = .recording
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let m = self?.model else { return }
            let t = Date().timeIntervalSince(start)
            let v = abs(sin(t * 2.3) * 0.55 + sin(t * 5.7) * 0.3 + sin(t * 11) * 0.1)
            m.level = CGFloat(min(1, v))
            m.history.removeFirst(); m.history.append(m.level)
        }
    }
    deinit { timer?.invalidate() }
}

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    @StateObject var demo = Demo()
    @AppStorage("lang") var lang = "auto"
    @ObservedObject var meter = MicMeter.shared
    @State var devices: [InputDevice] = listInputDevices()
    @State var permState: [Bool] = Perm.allCases.map { $0.granted }
    @State var launchAtLogin = SMAppService.mainApp.status == .enabled

    var positionGrid: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12))
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { c in
                            let i = r * 3 + c
                            RoundedRectangle(cornerRadius: 4)
                                .fill(prefs.position == i ? Color.accentColor : Color.white.opacity(0.14))
                                .frame(width: 34, height: 20)
                                .onTapGesture { prefs.position = i }
                        }
                    }
                }
            }
        }
        .frame(width: 142, height: 98)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.4), lineWidth: 1))
    }

    let names = ["Шар в капсуле", "Волны Siri", "Эквалайзер", "Шар Siri"]

    func card(_ i: Int) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12))
                Visual(m: demo.model, style: i)
                    .frame(width: 460, height: 220)
                    .scaleEffect(0.34 * CGFloat(prefs.scale))
                    .frame(width: 160, height: 84)
                    .clipped()
                    .opacity(prefs.opacity)
            }
            .frame(width: 160, height: 96)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(prefs.style == i ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: prefs.style == i ? 3 : 1))
            Text(names[i]).font(.system(size: 13, weight: prefs.style == i ? .semibold : .regular))
        }
        .contentShape(Rectangle())
        .onTapGesture { prefs.style = i }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Вид анимации").font(.headline)
            HStack(spacing: 14) { ForEach(0..<4, id: \.self) { card($0) } }
            HStack(spacing: 12) {
                Text("Прозрачность").frame(width: 110, alignment: .leading)
                Slider(value: $prefs.opacity, in: 0.15...1)
                Text("\(Int(prefs.opacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text("Размер").frame(width: 110, alignment: .leading)
                Slider(value: $prefs.scale, in: 0.5...1.4)
                Text("\(Int(prefs.scale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack(alignment: .top, spacing: 12) {
                Text("Положение").frame(width: 110, alignment: .leading)
                positionGrid
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Микрофон").frame(width: 110, alignment: .leading)
                    Picker("", selection: $prefs.micUID) {
                        Text("Системный по умолчанию").tag("")
                        ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().frame(maxWidth: 360)
                    .onChange(of: prefs.micUID) { _ in meter.start() }
                }
                HStack(spacing: 12) {
                    Text("Уровень").frame(width: 110, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(LinearGradient(colors: [.green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, g.size.width * CGFloat(meter.level)))
                        }
                    }
                    .frame(width: 360, height: 8)
                    Text(Perm.mic.granted ? "говори — полоска двигается" : "нет доступа к микрофону").font(.footnote).foregroundColor(.secondary)
                }
            }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                let d = listInputDevices(); if d != devices { devices = d }
            }
            .onAppear { devices = listInputDevices() }
            HStack(spacing: 12) {
                Text("Язык").frame(width: 110, alignment: .leading)
                Picker("", selection: $lang) {
                    Text("Авто").tag("auto"); Text("Русский").tag("ru"); Text("English").tag("en")
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Разрешения").font(.headline)
                ForEach(Perm.allCases, id: \.rawValue) { p in
                    HStack(spacing: 10) {
                        Image(systemName: permState[p.rawValue] ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(permState[p.rawValue] ? .green : .orange)
                        Text("\(p.rawValue + 1). \(p.title)").frame(width: 190, alignment: .leading)
                        Text(p.why).foregroundColor(.secondary)
                        Spacer()
                        if !permState[p.rawValue] { Button("Выдать") { p.request() } }
                    }
                }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                permState = Perm.allCases.map { $0.granted }
            }
            Toggle("Отправлять сразу: нажимать Enter после вставки текста", isOn: $prefs.autoSend)
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchAtLogin },
                set: { v in
                    do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
            Text("Зажми правый ⌥ и говори, или нажми ⌃⌥Пробел (старт/стоп)").font(.footnote).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(width: 710)
    }
}

// MARK: - Model downloader

final class Downloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onDone: ((Error?) -> Void)?
    private var session: URLSession!
    override init() { super.init(); session = URLSession(configuration: .default, delegate: self, delegateQueue: .main) }
    func start() { session.downloadTask(with: Whisper.turboURL).resume() }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData b: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        if t > 0 { onProgress?(Double(w) / Double(t)) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        do {
            try FileManager.default.createDirectory(at: Whisper.dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: Whisper.turbo)
            try FileManager.default.moveItem(at: loc, to: Whisper.turbo)
            onDone?(nil)
        } catch { onDone?(error) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { if let e = e { onDone?(e) } }
}

// MARK: - App

extension ProcessInfo { var machineHardwareName: String { var u = utsname(); uname(&u); return withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } } } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = Model()
    let recorder = Recorder()
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var recording = false
    var startTime = Date()
    var wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("voxa.wav")
    var lang: String { UserDefaults.standard.string(forKey: "lang") ?? "auto" }
    var targetApp: NSRunningApplication?

    func applicationWillTerminate(_ n: Notification) { Whisper.current?.terminate() }

    func applicationDidFinishLaunching(_ n: Notification) {
        setupPanel()
        setupMenu()

        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in self?.showPreview() }
        Whisper.migrateOldDir()
        let env0 = ProcessInfo.processInfo.environment
        if env0["VOXA_MICTEST"] != nil {
            print("devices:", listInputDevices().map { $0.name }, "auth:", AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
            if let u = env0["VOXA_MIC"] { Prefs.shared.micUID = listInputDevices().first { $0.name.contains(u) }?.uid ?? "" }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mictest.wav")
            var maxLv: Float = 0
            recorder.onLevel = { maxLv = max(maxLv, $0) }
            do { try recorder.start(to: url) } catch { print("start error:", error.localizedDescription) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("frames:", self.recorder.frames, "maxLevel:", maxLv); self.recorder.stop(); exit(0) }
            return
        }
        if let path = env0["VOXA_PREVIEW_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Prefs.shared.style = 1; Prefs.shared.opacity = 0.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { exit(1) }
                print("phase=\(self.model.phase) visible=\(self.model.visible) panelVisible=\(self.panel.isVisible) previewing=\(self.previewing)")
                let r = ImageRenderer(content: ZStack { Color(white: 0.3); OverlayView(m: self.model) }.frame(width: panelW, height: panelH))
                if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                print("after: phase=\(String(describing: self?.model.phase)) panelVisible=\(String(describing: self?.panel.isVisible))"); exit(0)
            }
            return
        }
        if let path = env0["VOXA_SETTINGS_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let r = ImageRenderer(content: SettingsView().background(Color(white: 0.16)).environment(\.colorScheme, .dark))
                r.scale = 2
                if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
                exit(0)
            }
            return
        }
        if let d = env0["VOXA_DEMO"] { runDemo(d); return }
        if Whisper.model == nil { downloadModel() }

        // Hold Right Option to talk
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e); return e }
        installGlobalMonitor()
        installCarbonHotkey()
        // ждём выдачи прав: глобальный монитор нужно ставить заново, когда «Мониторинг ввода» включили
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Perm.input.granted && !self.monitorWithAccess { self.installGlobalMonitor() }
        }
        if !Perm.allGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.statusItem.button?.performClick(nil) }
        }

        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self = self, self.model.phase == .recording else { return }
            // страховка: опция отпущена, а событие потерялось, или запись слишком длинная
            if self.recording && ((!self.viaMenu && !NSEvent.modifierFlags.contains(.option)) || Date().timeIntervalSince(self.startTime) > 180) { self.stopRecording(); return }
            self.model.history.removeFirst()
            self.model.history.append(self.model.level)
        }
        recorder.onLevel = { [weak self] v in
            DispatchQueue.main.async {
                guard let m = self?.model else { return }
                let cur = m.level
                m.level = CGFloat(v) > cur ? CGFloat(v) : cur * 0.82 + CGFloat(v) * 0.18
            }
        }
    }

    var viaMenu = false
    var globalMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    var hotKeyStatus: OSStatus = -1
    var logLines: [String] = []
    func log(_ t: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        logLines.append("\(f.string(from: Date())) \(t)")
        if logLines.count > 80 { logLines.removeFirst() }
    }

    func defaultInputName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "НЕТ микрофона по умолчанию"
    }

    @objc func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        var out = ["Voxa \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))",
                   "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.machineHardwareName)",
                   "Микрофон по умолчанию: \(defaultInputName())",
                   "Разрешения: микрофон=\(Perm.mic.granted) доступ=\(Perm.access.granted) мониторинг=\(Perm.input.granted)",
                   "Хоткей ⌃⌥Пробел: статус регистрации=\(hotKeyStatus) (0 = ок); глобальный монитор ⌥ с правами=\(monitorWithAccess)",
                   "whisper-cli: \(Whisper.bin ?? "НЕ НАЙДЕН")",
                   "Модель: \(Whisper.model ?? "НЕ СКАЧАНА")",
                   "Фаза: \(model.phase), recording=\(recording), скачивание=\(downloader != nil)", "--- события ---"]
        out += logLines
        let text = out.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        flash("Диагностика скопирована")
    }

    /// Запасная горячая клавиша ⌃⌥Пробел (нажал — запись, нажал ещё раз — стоп). Не требует «Мониторинг ввода».
    func installCarbonHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
            let me = Unmanaged<AppDelegate>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { me.log("хоткей ⌃⌥Пробел нажат"); me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: 0x53485054, id: 1)
        hotKeyStatus = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        log("регистрация хоткея ⌃⌥Пробел: \(hotKeyStatus)")
    }
    var monitorWithAccess = false
    var permItems: [NSMenuItem] = []
    var permHeader: NSMenuItem?

    func installGlobalMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e) }
        monitorWithAccess = Perm.input.granted
    }
    var previewing = false
    var previewTimer: Timer?
    var previewWork: DispatchWorkItem?

    /// Живой предпросмотр индикатора при смене настроек (стиль, размер, прозрачность, положение)
    func showPreview() {
        guard !recording, previewing || [.idle, .done, .error].contains(model.phase) else { return }
        previewing = true
        model.phase = .recording
        showPanel()
        if previewTimer == nil {
            let t0 = Date()
            previewTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                let t = Date().timeIntervalSince(t0)
                self?.model.level = CGFloat(min(1, abs(sin(t * 2.3) * 0.55 + sin(t * 5.7) * 0.3) + 0.2))
            }
        }
        previewWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.previewing else { return }
            self.stopPreview()
            self.model.phase = .done
            self.hidePanel(after: 0)
        }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
    }

    func stopPreview() {
        previewing = false
        previewTimer?.invalidate(); previewTimer = nil
        previewWork?.cancel()
    }
    var downloader: Downloader?
    func downloadModel() {
        let d = Downloader()
        downloader = d
        model.phase = .downloading
        model.message = "Скачиваю модель 0%"
        showPanel()
        d.onProgress = { [weak self] p in self?.model.message = "Скачиваю модель \(Int(p * 100))%" }
        d.onDone = { [weak self] err in
            guard let self = self else { return }
            self.downloader = nil
            if err == nil { self.model.phase = .done; self.model.message = ""; self.hidePanel(after: 1.2) }
            else { self.flash("Не удалось скачать модель") }
        }
        d.start()
    }

    /// Режим для проверки внешнего вида: VOXA_DEMO=recording|transcribing|done, VOXA_STYLE, VOXA_POS
    func runDemo(_ phase: String) {
        let env = ProcessInfo.processInfo.environment
        if let v = env["VOXA_STYLE"], let i = Int(v) { Prefs.shared.style = i }
        if let v = env["VOXA_POS"], let i = Int(v) { Prefs.shared.position = i }
        if let v = env["VOXA_SCALE"], let d = Double(v) { Prefs.shared.scale = d }
        model.phase = phase == "transcribing" ? .transcribing : (phase == "done" ? .done : .recording)
        showPanel()
        let t0 = Date()
        if let path = env["VOXA_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self = self else { exit(1) }
                let bg = Double(env["VOXA_BG"] ?? "0.45") ?? 0.45
                let r = ImageRenderer(content: ZStack { Color(white: bg); OverlayView(m: self.model) }.frame(width: panelW, height: panelH))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let m = self?.model else { return }
            let t = Date().timeIntervalSince(t0)
            m.level = CGFloat(min(1, abs(sin(t * 2.3) * 0.6 + sin(t * 5.7) * 0.3) + 0.25))
            m.history.removeFirst(); m.history.append(m.level)
        }
    }

    func flags(_ e: NSEvent) {
        log("flagsChanged key=\(e.keyCode) option=\(e.modifierFlags.contains(.option)) recording=\(recording)")
        if recording && !viaMenu && !e.modifierFlags.contains(.option) { stopRecording(); return }
        guard e.keyCode == 61 else { return } // right option
        if e.modifierFlags.contains(.option) { if !recording { viaMenu = false; startRecording() } }
        else if recording { stopRecording() }
    }

    func setupPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(m: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func showPanel() {
        if let s = NSScreen.main {
            let f = s.visibleFrame
            let pos = Prefs.shared.position, col = pos % 3, row = pos / 3
            let inset: CGFloat = 38   // 44 внутренний отступ - 6 от края экрана
            let x = [f.minX - inset, f.midX - panelW / 2, f.maxX - panelW + inset][col]
            let y = [f.maxY - panelH + inset, f.midY - panelH / 2, f.minY - inset][row]
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        DispatchQueue.main.async { self.model.visible = true }
    }

    func hidePanel(after: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard self.model.phase != .recording, self.model.phase != .transcribing else { return }
            self.model.visible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !self.model.visible { self.panel.orderOut(nil); self.model.phase = .idle }
            }
        }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Voxa")
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let hint = NSMenuItem(title: "Зажми правый ⌥ или нажми ⌃⌥Пробел", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem(title: recording ? "Остановить запись" : "Начать запись", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(.separator())
        let head = NSMenuItem(title: "Нужны разрешения (по порядку):", action: nil, keyEquivalent: "")
        head.isEnabled = false
        permHeader = head
        menu.addItem(head)
        permItems = Perm.allCases.map { p in
            let it = NSMenuItem(title: "", action: #selector(grantPerm(_:)), keyEquivalent: "")
            it.tag = p.rawValue
            menu.addItem(it)
            return it
        }
        refreshPermItems()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Скопировать диагностику", action: #selector(copyDiagnostics), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Выданные разрешения скрываем; показываем только недостающие (все они всегда видны в настройках).
    func refreshPermItems() {
        for it in permItems {
            guard let p = Perm(rawValue: it.tag) else { continue }
            it.isHidden = p.granted
            it.title = "\(p.rawValue + 1). \(p.title): выдать… (\(p.why))"
        }
        permHeader?.isHidden = Perm.allGranted
    }

    func menuWillOpen(_ menu: NSMenu) { refreshPermItems() }

    @objc func grantPerm(_ s: NSMenuItem) { Perm(rawValue: s.tag)?.request() }

    var settingsWindow: NSWindow?
    func windowWillClose(_ n: Notification) { MicMeter.shared.stop() }
    func windowDidResignKey(_ n: Notification) { MicMeter.shared.stop() }   // микрофон включён только пока окно настроек активно
    func windowDidBecomeKey(_ n: Notification) { MicMeter.shared.start() }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 370), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Voxa — настройки"
            w.isReleasedWhenClosed = false
            w.delegate = self
            let host = NSHostingView(rootView: SettingsView())
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func toggle() { if recording { stopRecording() } else { viaMenu = true; startRecording() } }

    func startRecording() {
        log("startRecording phase=\(model.phase) model=\(Whisper.model != nil)")
        if Whisper.model == nil {
            if downloader == nil { downloadModel() } else { showPanel() }   // модель ещё качается — показываем прогресс
            return
        }
        if previewing { stopPreview(); model.phase = .idle }
        guard model.phase == .idle || model.phase == .done || model.phase == .error else { log("старт отклонён: фаза \(model.phase)"); return }
        targetApp = NSWorkspace.shared.frontmostApplication
        MicMeter.shared.stop()
        try? FileManager.default.removeItem(at: wavURL)
        do { try recorder.start(to: wavURL); log("запись пошла") } catch { log("ОШИБКА записи: \(error)"); flash("Нет доступа к микрофону"); return }
        recording = true; startTime = Date()
        model.level = 0
        model.history = Array(repeating: 0, count: 22)
        model.phase = .recording
        showPanel()
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
        NSSound(named: "Tink")?.play()
        rebuildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.recording, self.recorder.frames == 0 else { return }
            self.log("нет данных с микрофона за 1,5 с: \(self.recorder.stats)")
            if !Prefs.shared.micUID.isEmpty {
                // выбранный микрофон молчит — пробуем системный по умолчанию
                self.recorder.stop()
                do { try self.recorder.start(to: self.wavURL, forceDefault: true); self.log("откат на системный микрофон") } catch { self.log("откат не удался: \(error)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self, self.recording, self.recorder.frames == 0 else { return }
                    self.log("и системный молчит: \(self.recorder.stats)")
                    self.recording = false; self.recorder.stop()
                    self.flash("Микрофон не передаёт звук")
                }
            } else {
                self.recording = false; self.recorder.stop()
                self.flash("Микрофон не передаёт звук. Выбери другой в настройках")
            }
        }
    }

    func stopRecording() {
        log("запись: \(recorder.stats), кадров \(recorder.frames)")
        log("stopRecording, длительность \(String(format: "%.1f", Date().timeIntervalSince(startTime))) с")
        recording = false
        recorder.stop()
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil)
        rebuildMenu()
        if Date().timeIntervalSince(startTime) < 0.4 { model.phase = .idle; model.visible = false; panel.orderOut(nil); return }
        model.phase = .transcribing
        Whisper.transcribe(wavURL, lang: lang) { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch r {
                case .success(let text):
                    self.log("whisper: \(text.count) символов")
                    if text.isEmpty { self.flash("Ничего не услышал"); return }
                    self.model.phase = .done
                    NSSound(named: "Pop")?.play()
                    self.insert(text)
                    self.hidePanel(after: 1.1)
                case .failure(let e): self.log("whisper ошибка: \(e.localizedDescription)"); self.flash(e.localizedDescription)
                }
            }
        }
    }

    func flash(_ msg: String) {
        model.message = msg; model.phase = .error; showPanel(); hidePanel(after: 1.8)
    }

    func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let x = item.data(forType: t) { d[t] = x } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        targetApp?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            if Prefs.shared.autoSend {
                // «отправить сразу»: Enter через короткую паузу, когда приложение приняло вставку
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let d = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
                    let u = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
                    d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let saved = saved, !saved.isEmpty else { return }
                pb.clearContents()
                for d in saved {
                    let item = NSPasteboardItem()
                    for (t, x) in d { item.setData(x, forType: t) }
                    pb.writeObjects([item])
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
