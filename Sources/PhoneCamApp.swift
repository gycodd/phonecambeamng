// PhoneCamApp.swift  (iOS 15+)
// Портретный "камерный" интерфейс: видео с ПК + отправка ориентации в BeamNG + настройки карты.
//
// Телефон держим как обычную камеру: задняя камера = направление взгляда,
// верх экрана = верх кадра.

import SwiftUI
import CoreMotion
import Network
import WebKit

// MARK: - Утилиты

func formatHour(_ h: Double) -> String {
    let total = Int((h * 60).rounded()) % (24 * 60)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

// MARK: - Движок: датчики + UDP

final class PhoneCamEngine: ObservableObject {
    @Published var running = false

    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private var conn: NWConnection?
    private var lastTimeSend = Date.distantPast

    // Отправка произвольной текстовой команды в мод
    func send(_ text: String) {
        conn?.send(content: text.data(using: .utf8), completion: .idempotent)
    }

    func cmd(_ name: String, _ value: Double) {
        send("\(name),\(String(format: "%.3f", value))")
    }

    // Время суток (в часах 0...24), с ограничением частоты отправки
    func sendTime(_ hour: Double, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastTimeSend) > 0.1 {
            lastTimeSend = now
            cmd("time", hour)
        }
    }

    func pushSettings() {
        let d = UserDefaults.standard
        cmd("sens", d.double(forKey: "sens"))
        cmd("smooth", d.double(forKey: "smooth"))
        cmd("yawsign", d.bool(forKey: "invYaw") ? 1 : -1)
        cmd("pitchsign", d.bool(forKey: "invPitch") ? -1 : 1)
        cmd("rollsign", d.bool(forKey: "invRoll") ? -1 : 1)
        if d.bool(forKey: "fovTouched") { cmd("fov", d.double(forKey: "fov")) }
    }

    func start(host: String, port: UInt16 = 4444) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port), motion.isDeviceMotionAvailable else { return }

        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        c.start(queue: .global(qos: .userInteractive))
        conn = c

        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical)
            ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical

        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: frame, to: motionQueue) { dm, _ in
            guard let m = dm?.attitude.rotationMatrix else { return }

            // CMRotationMatrix: мир -> устройство, значит мировые векторы = строки матрицы.
            // Портрет, как камера: взгляд = -Z устройства, вверх = +Y, вправо = +X.
            let fx = -m.m31, fy = -m.m32, fz = -m.m33     // направление взгляда
            let rz = m.m13                                 // Z-компонента "вправо"
            let uz = m.m23                                 // Z-компонента "вверх"

            let toDeg = 180.0 / Double.pi
            let fzc = max(-1.0, min(1.0, fz))
            let pitch = asin(fzc) * toDeg                  // + = вверх
            let yaw = -atan2(fy, fx) * toDeg               // + = вправо (по часовой)

            let cp = (1.0 - fzc * fzc).squareRoot()
            let roll: Double
            if cp > 0.05 {
                roll = atan2(-rz, uz / cp) * toDeg         // + = по часовой (вид сзади)
            } else {
                roll = asin(max(-1.0, min(1.0, -rz))) * toDeg
            }

            let s = String(format: "%.2f,%.2f,%.2f", pitch, roll, yaw)
            c.send(content: s.data(using: .utf8), completion: .idempotent)
        }

        DispatchQueue.main.async { self.running = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.conn === c else { return }
            self.pushSettings()
            self.send("recenter")
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        conn?.cancel()
        conn = nil
        DispatchQueue.main.async { self.running = false }
    }
}

// MARK: - Видео (WebRTC-страница MediaMTX)

struct StreamView: UIViewRepresentable {
    let url: URL
    let fill: Bool

    final class Coordinator { var loaded: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let css = "html,body{margin:0!important;padding:0!important;background:#000!important;overflow:hidden!important}" +
                  "video{position:fixed!important;left:0;top:0;width:100vw!important;height:100vh!important;" +
                  "max-width:none!important;max-height:none!important;object-fit:contain;background:#000}" +
                  "video::-webkit-media-controls{display:none!important}"
        let js = "(function(){var s=document.createElement('style');s.textContent='\(css)';document.head.appendChild(s);})();"
        cfg.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.loaded != url.absoluteString {
            context.coordinator.loaded = url.absoluteString
            web.load(URLRequest(url: url))
        }
        let fit = fill ? "cover" : "contain"
        web.evaluateJavaScript("document.querySelectorAll('video').forEach(function(v){v.style.objectFit='\(fit)'})",
                               completionHandler: nil)
    }
}

// MARK: - Сетка

struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: g.size.height))
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
    }
}

// MARK: - Главный экран (камера)

struct ContentView: View {
    @StateObject private var engine = PhoneCamEngine()
    @AppStorage("pcIP") private var pcIP = "192.168.1.50"
    @AppStorage("fillScreen") private var fillScreen = false
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("timeHour") private var timeHour = 12.0

    @State private var showSettings = false
    @State private var flash = false

    private var isDay: Bool { timeHour >= 6 && timeHour < 19 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.running, let url = URL(string: "http://\(pcIP):8889/beam?controls=false") {
                StreamView(url: url, fill: fillScreen).ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 54))
                    Text("Нажмите ▶ для подключения к ПК").font(.system(size: 15))
                    Text(pcIP).font(.system(size: 13, design: .monospaced)).opacity(0.6)
                }
                .foregroundColor(.white.opacity(0.7))
            }

            if showGrid { GridOverlay().ignoresSafeArea().allowsHitTesting(false) }

            Color.white.opacity(flash ? 0.35 : 0).ignoresSafeArea().allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .foregroundColor(.white)
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsView(engine: engine) }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(engine.running ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(engine.running ? "LIVE" : "OFFLINE")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.15)).clipShape(Capsule())

            Spacer()

            Button(action: { showSettings = true }) {
                HStack(spacing: 6) {
                    Image(systemName: isDay ? "sun.max.fill" : "moon.fill")
                    Text(formatHour(timeHour)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.15)).clipShape(Capsule())
            }

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.15)).clipShape(Circle())
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack {
            circleButton(showGrid ? "grid" : "square", tint: showGrid ? .yellow : .white) { showGrid.toggle() }
            Spacer()
            VStack(spacing: 4) {
                Button(action: shutter) {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                        Circle().fill(Color.white).frame(width: 60, height: 60)
                    }
                }
                Text("ЦЕНТР").font(.system(size: 10, weight: .bold)).opacity(0.7)
            }
            Spacer()
            circleButton(engine.running ? "stop.fill" : "play.fill",
                         tint: engine.running ? .red : .white) { toggleRun() }
        }
        .padding(.horizontal, 36).padding(.bottom, 14)
    }

    private func circleButton(_ icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
        }
    }

    private func toggleRun() {
        if engine.running { engine.stop() } else { engine.start(host: pcIP) }
    }

    private func shutter() {
        engine.send("recenter")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.12)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) { flash = false }
        }
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @ObservedObject var engine: PhoneCamEngine
    @Environment(\.presentationMode) private var presentation

    @AppStorage("pcIP") private var pcIP = "192.168.1.50"
    @AppStorage("sens") private var sens = 1.0
    @AppStorage("smooth") private var smooth = 12.0
    @AppStorage("fov") private var fov = 75.0
    @AppStorage("fovTouched") private var fovTouched = false
    @AppStorage("invYaw") private var invYaw = false
    @AppStorage("invPitch") private var invPitch = false
    @AppStorage("invRoll") private var invRoll = false
    @AppStorage("fillScreen") private var fillScreen = false
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("timeHour") private var timeHour = 12.0
    @AppStorage("timeFlow") private var timeFlow = false

    private let presets: [(String, Double)] = [("Рассвет", 6), ("День", 12), ("Закат", 19), ("Ночь", 0)]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Подключение")) {
                    TextField("IP компьютера", text: $pcIP)
                        .keyboardType(.numbersAndPunctuation)
                        .disableAutocorrection(true)
                    Text("Новый IP применяется после повторного нажатия ▶")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section(header: Text("Карта: время суток")) {
                    HStack {
                        Text("Время")
                        Spacer()
                        Text(formatHour(timeHour)).font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $timeHour, in: 0...24, step: 0.25,
                           onEditingChanged: { editing in
                               if !editing { engine.sendTime(timeHour, force: true) }
                           })
                        .onChange(of: timeHour) { v in engine.sendTime(v) }

                    HStack {
                        ForEach(presets, id: \.0) { p in
                            Button(p.0) {
                                timeHour = p.1
                                engine.sendTime(p.1, force: true)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Toggle("Ход времени", isOn: $timeFlow)
                        .onChange(of: timeFlow) { on in engine.cmd("timeflow", on ? 1 : 0) }
                }

                Section(header: Text("Камера")) {
                    HStack {
                        Text("Чувствительность")
                        Spacer()
                        Text(String(format: "%.2f", sens)).foregroundColor(.secondary)
                    }
                    Slider(value: $sens, in: 0.3...3.0, step: 0.05)
                        .onChange(of: sens) { v in engine.cmd("sens", v) }

                    HStack {
                        Text("Плавность (больше = резче)")
                        Spacer()
                        Text(String(format: "%.0f", smooth)).foregroundColor(.secondary)
                    }
                    Slider(value: $smooth, in: 2...40, step: 1)
                        .onChange(of: smooth) { v in engine.cmd("smooth", v) }

                    HStack {
                        Text("Угол обзора (FOV)")
                        Spacer()
                        Text(String(format: "%.0f°", fov)).foregroundColor(.secondary)
                    }
                    Slider(value: $fov, in: 30...120, step: 1)
                        .onChange(of: fov) { v in
                            fovTouched = true
                            engine.cmd("fov", v)
                        }

                    Button("Центрировать камеру") { engine.send("recenter") }
                }

                Section(header: Text("Инверсия осей (если крутится не туда)")) {
                    Toggle("Поворот влево/вправо", isOn: $invYaw)
                        .onChange(of: invYaw) { v in engine.cmd("yawsign", v ? 1 : -1) }
                    Toggle("Наклон вверх/вниз", isOn: $invPitch)
                        .onChange(of: invPitch) { v in engine.cmd("pitchsign", v ? -1 : 1) }
                    Toggle("Крен (наклон головы)", isOn: $invRoll)
                        .onChange(of: invRoll) { v in engine.cmd("rollsign", v ? -1 : 1) }
                }

                Section(header: Text("Экран")) {
                    Toggle("Заполнять экран (обрезать по бокам)", isOn: $fillScreen)
                    Toggle("Сетка", isOn: $showGrid)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { presentation.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// MARK: - App

@main
struct PhoneCamApp: App {
    init() {
        UserDefaults.standard.register(defaults: [
            "pcIP": "192.168.1.50",
            "sens": 1.0,
            "smooth": 12.0,
            "fov": 75.0,
            "timeHour": 12.0
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(.dark)
        }
    }
}
