// PhoneCamApp.swift  (iOS 15+)
// Портретный "камерный" интерфейс: видео с ПК + ориентация телефона -> BeamNG,
// джойстик для перемещения по карте, зум щипком = FOV в игре (без цифрового зума).

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
    private var lastFovSend = Date.distantPast

    // Джойстик / высота
    private var joyX = 0.0, joyY = 0.0, vert = 0.0
    private var moveTimer: Timer?

    // Произвольная команда мод-у
    func send(_ text: String) {
        conn?.send(content: text.data(using: .utf8), completion: .idempotent)
    }

    func cmd(_ name: String, _ value: Double) {
        send("\(name),\(String(format: "%.3f", value))")
    }

    func sendTime(_ hour: Double, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastTimeSend) > 0.1 {
            lastTimeSend = now
            cmd("time", hour)
        }
    }

    func sendFov(_ fov: Double, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastFovSend) > 0.05 {
            lastFovSend = now
            cmd("fov", fov)
        }
    }

    // MARK: Движение по карте

    func setJoystick(_ x: Double, _ y: Double) {
        joyX = x; joyY = y; refreshMove()
    }

    func setVertical(_ z: Double) {
        vert = z; refreshMove()
    }

    private func refreshMove() {
        let active = joyX != 0 || joyY != 0 || vert != 0
        if active {
            if moveTimer == nil {
                let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.sendMove() }
                RunLoop.main.add(t, forMode: .common)
                moveTimer = t
                sendMove()
            }
        } else {
            moveTimer?.invalidate()
            moveTimer = nil
            send("move,0,0,0")
            send("move,0,0,0")
        }
    }

    private func sendMove() {
        send(String(format: "move,%.2f,%.2f,%.2f", joyX, joyY, vert))
    }

    // MARK: Настройки -> мод

    func pushSettings() {
        let d = UserDefaults.standard

        // Общие
        cmd("sens",     d.double(forKey: "sens"))
        cmd("smooth",   d.double(forKey: "smooth"))
        cmd("deadzone", d.double(forKey: "deadzone"))
        cmd("maxpitch", d.double(forKey: "maxPitch"))
        cmd("autocenter", d.double(forKey: "autoCenterSec"))

        // Оси
        cmd("yawsign",   d.bool(forKey: "invYaw")   ? 1 : -1)
        cmd("pitchsign", d.bool(forKey: "invPitch") ? -1 : 1)
        cmd("rollsign",  d.bool(forKey: "invRoll")  ? -1 : 1)
        cmd("swapaxes",  d.bool(forKey: "swapAxes") ? 1 : 0)
        send("eulerorder,\(d.string(forKey: "eulerOrder") ?? "zxy")")

        // Курс и движение
        cmd("yawtrim", d.double(forKey: "yawTrim"))
        cmd("speed",   d.double(forKey: "moveSpeed"))
        cmd("vspeed",  d.double(forKey: "vertSpeed"))
        cmd("invertjoyy", d.bool(forKey: "invertJoyY") ? 1 : 0)

        // FOV
        if d.bool(forKey: "fovTouched") { cmd("fov", d.double(forKey: "fov")) }

        // Время
        cmd("time", d.double(forKey: "timeHour"))
        cmd("timeflow", d.bool(forKey: "timeFlow") ? 1 : 0)
    }

    func resetModDefaults() {
        send("resetdefaults")
    }

    // MARK: Старт / стоп

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

            let fx = -m.m31, fy = -m.m32, fz = -m.m33
            let rz = m.m13
            let uz = m.m23

            let toDeg = 180.0 / Double.pi
            let fzc = max(-1.0, min(1.0, fz))
            let pitch = asin(fzc) * toDeg
            let yaw = -atan2(fy, fx) * toDeg

            let cp = (1.0 - fzc * fzc).squareRoot()
            let roll: Double
            if cp > 0.05 {
                roll = atan2(-rz, uz / cp) * toDeg
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
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        moveTimer?.invalidate()
        moveTimer = nil
        joyX = 0; joyY = 0; vert = 0
        send("move,0,0,0")
        conn?.cancel()
        conn = nil
        DispatchQueue.main.async { self.running = false }
    }
}

// MARK: - Видео

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
        web.isUserInteractionEnabled = false
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

// MARK: - Джойстик

struct JoystickView: View {
    let onChange: (Double, Double) -> Void

    @State private var knob = CGSize.zero
    private let size: CGFloat = 118
    private let radius: CGFloat = 50

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.15))
            Circle().stroke(Color.white.opacity(0.6), lineWidth: 2)
            Circle().fill(Color.white).frame(width: 50, height: 50).offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    var dx = v.location.x - size / 2
                    var dy = v.location.y - size / 2
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d > radius {
                        dx = dx / d * radius
                        dy = dy / d * radius
                    }
                    knob = CGSize(width: dx, height: dy)

                    let mag: CGFloat = min(d / radius, 1)
                    let scaled: CGFloat = mag < 0.08 ? 0 : mag * mag
                    let len = max(d, 1)
                    onChange(Double(dx / len * scaled), Double(-dy / len * scaled))
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.12)) { knob = .zero }
                    onChange(0, 0)
                }
        )
    }
}

// MARK: - Кнопка "удерживать"

struct HoldButton: View {
    let icon: String
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .bold))
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(pressed ? 0.4 : 0.15))
            .clipShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onChange(true) }
                    }
                    .onEnded { _ in
                        pressed = false
                        onChange(false)
                    }
            )
    }
}

// MARK: - Главный экран

struct ContentView: View {
    @StateObject private var engine = PhoneCamEngine()
    @AppStorage("pcIP") private var pcIP = "192.168.1.50"
    @AppStorage("fillScreen") private var fillScreen = false
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("timeHour") private var timeHour = 12.0
    @AppStorage("fov") private var fov = 75.0
    @AppStorage("fovTouched") private var fovTouched = false
    @AppStorage("fovMin") private var fovMin = 20.0
    @AppStorage("fovMax") private var fovMax = 120.0

    @State private var showSettings = false
    @State private var flash = false
    @State private var pinchBase: Double? = nil
    @State private var fovHud = false
    @State private var hudToken = 0

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

            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale in applyPinch(scale) }
                        .onEnded { _ in pinchBase = nil }
                )
                .onTapGesture(count: 2) { resetFov() }

            Color.white.opacity(flash ? 0.35 : 0).ignoresSafeArea().allowsHitTesting(false)

            if fovHud {
                Text("FOV \(Int(fov))°")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
            }

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
            Button(action: toggleRun) {
                Image(systemName: engine.running ? "stop.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(engine.running ? .red : .white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.15)).clipShape(Circle())
            }

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
        HStack(alignment: .bottom) {
            VStack(spacing: 4) {
                Button(action: recenter) { crosshair }
                Text("ЦЕНТР").font(.system(size: 10, weight: .bold)).opacity(0.7)
            }
            .frame(width: 70)

            Spacer()

            JoystickView { x, y in engine.setJoystick(x, y) }

            Spacer()

            VStack(spacing: 10) {
                HoldButton(icon: "chevron.up") { engine.setVertical($0 ? 1 : 0) }
                HoldButton(icon: "chevron.down") { engine.setVertical($0 ? -1 : 0) }
            }
            .frame(width: 70)
        }
        .padding(.horizontal, 22).padding(.bottom, 14)
    }

    private var crosshair: some View {
        ZStack {
            Circle().stroke(Color.white, lineWidth: 2).frame(width: 24, height: 24)
            Rectangle().fill(Color.white).frame(width: 2, height: 36)
            Rectangle().fill(Color.white).frame(width: 36, height: 2)
        }
        .frame(width: 52, height: 52)
        .background(Color.white.opacity(0.15))
        .clipShape(Circle())
    }

    private func toggleRun() {
        if engine.running { engine.stop() } else { engine.start(host: pcIP) }
    }

    private func recenter() {
        engine.send("recenter")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.12)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) { flash = false }
        }
    }

    private func applyPinch(_ scale: CGFloat) {
        if pinchBase == nil { pinchBase = fov }
        let base = pinchBase ?? fov
        let half = base * Double.pi / 360.0
        let k = Double(max(scale, 0.05))
        let newFov = 2.0 * atan(tan(half) / k) * 180.0 / Double.pi
        fov = min(max(newFov, fovMin), fovMax)
        fovTouched = true
        engine.sendFov(fov)
        showHud()
    }

    private func resetFov() {
        fov = 75
        fovTouched = true
        engine.sendFov(75, force: true)
        showHud()
    }

    private func showHud() {
        fovHud = true
        hudToken += 1
        let t = hudToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if t == hudToken { fovHud = false }
        }
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @ObservedObject var engine: PhoneCamEngine
    @Environment(\.presentationMode) private var presentation

    // Подключение / экран
    @AppStorage("pcIP") private var pcIP = "192.168.1.50"
    @AppStorage("fillScreen") private var fillScreen = false
    @AppStorage("showGrid") private var showGrid = true

    // Время
    @AppStorage("timeHour") private var timeHour = 12.0
    @AppStorage("timeFlow") private var timeFlow = false

    // FOV
    @AppStorage("fov") private var fov = 75.0
    @AppStorage("fovTouched") private var fovTouched = false
    @AppStorage("fovMin") private var fovMin = 20.0
    @AppStorage("fovMax") private var fovMax = 120.0

    // Камера: ориентация
    @AppStorage("sens")        private var sens = 1.0
    @AppStorage("smooth")      private var smooth = 12.0
    @AppStorage("deadzone")    private var deadzone = 0.0
    @AppStorage("maxPitch")    private var maxPitch = 89.0
    @AppStorage("autoCenterSec") private var autoCenterSec = 0.0
    @AppStorage("eulerOrder")  private var eulerOrder = "zxy"
    @AppStorage("swapAxes")    private var swapAxes = true

    // Инверсии
    @AppStorage("invYaw")   private var invYaw = false
    @AppStorage("invPitch") private var invPitch = false
    @AppStorage("invRoll")  private var invRoll = false

    // Движение
    @AppStorage("yawTrim")    private var yawTrim = 0.0
    @AppStorage("moveSpeed")  private var moveSpeed = 12.0
    @AppStorage("vertSpeed")  private var vertSpeed = 12.0
    @AppStorage("invertJoyY") private var invertJoyY = false

    private let presets: [(String, Double)] = [("Рассвет", 6), ("День", 12), ("Закат", 19), ("Ночь", 0)]
    private let eulerOrders = ["zxy", "zyx", "xyz", "xzy", "yxz", "yzx"]

    var body: some View {
        NavigationView {
            Form {
                // --- Подключение ---
                Section(header: Text("Подключение")) {
                    TextField("IP компьютера", text: $pcIP)
                        .keyboardType(.numbersAndPunctuation)
                        .disableAutocorrection(true)
                    Text("Новый IP применяется после повторного нажатия ▶")
                        .font(.footnote).foregroundColor(.secondary)
                }

                // --- Время суток ---
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

                // --- FOV ---
                Section(header: Text("Угол обзора (FOV)")) {
                    HStack {
                        Text("Текущий")
                        Spacer()
                        Text(String(format: "%.0f°", fov)).foregroundColor(.secondary)
                    }
                    Slider(value: $fov, in: fovMin...fovMax, step: 1)
                        .onChange(of: fov) { v in
                            fovTouched = true
                            engine.sendFov(v)
                        }
                    HStack {
                        Button("50°") { setFov(50) }
                        Button("75°") { setFov(75) }
                        Button("90°") { setFov(90) }
                        Button("110°") { setFov(110) }
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .frame(maxWidth: .infinity)

                    HStack {
                        Text("Мин")
                        Slider(value: $fovMin, in: 10...90, step: 1)
                        Text("\(Int(fovMin))°").frame(width: 44, alignment: .trailing).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Макс")
                        Slider(value: $fovMax, in: 40...160, step: 1)
                        Text("\(Int(fovMax))°").frame(width: 44, alignment: .trailing).foregroundColor(.secondary)
                    }
                    Text("Щипок двумя пальцами на главном экране меняет FOV в игре. Двойной тап — сброс до 75°.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                // --- Камера: точность ---
                Section(header: Text("Камера: точность")) {
                    HStack {
                        Text("Чувствительность")
                        Spacer()
                        Text(String(format: "%.2f", sens)).foregroundColor(.secondary)
                    }
                    Slider(value: $sens, in: 0.2...4.0, step: 0.05)
                        .onChange(of: sens) { v in engine.cmd("sens", v) }

                    HStack {
                        Text("Плавность (больше = резче)")
                        Spacer()
                        Text(String(format: "%.0f", smooth)).foregroundColor(.secondary)
                    }
                    Slider(value: $smooth, in: 1...60, step: 1)
                        .onChange(of: smooth) { v in engine.cmd("smooth", v) }

                    HStack {
                        Text("Мёртвая зона")
                        Spacer()
                        Text(String(format: "%.1f°", deadzone)).foregroundColor(.secondary)
                    }
                    Slider(value: $deadzone, in: 0...10, step: 0.1)
                        .onChange(of: deadzone) { v in engine.cmd("deadzone", v) }
                    Text("Отсекает микро-дрожание. 0 = выключено.")
                        .font(.footnote).foregroundColor(.secondary)

                    HStack {
                        Text("Макс. наклон вверх/вниз")
                        Spacer()
                        Text(String(format: "%.0f°", maxPitch)).foregroundColor(.secondary)
                    }
                    Slider(value: $maxPitch, in: 20...89, step: 1)
                        .onChange(of: maxPitch) { v in engine.cmd("maxpitch", v) }
                }

                // --- Камера: авто-центр ---
                Section(header: Text("Камера: авто-центр")) {
                    HStack {
                        Text("Возврат через")
                        Spacer()
                        Text(autoCenterSec <= 0 ? "выкл" : String(format: "%.1f сек", autoCenterSec))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $autoCenterSec, in: 0...10, step: 0.5)
                        .onChange(of: autoCenterSec) { v in engine.cmd("autocenter", v) }
                    Text("Если телефон неподвижен N секунд — камера плавно возвращается в центр.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                // --- Камера: оси ---
                Section(header: Text("Камера: оси и порядок")) {
                    Picker("Порядок осей", selection: $eulerOrder) {
                        ForEach(eulerOrders, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: eulerOrder) { v in engine.send("eulerorder,\(v)") }

                    Toggle("Поменять местами Pitch/Roll", isOn: $swapAxes)
                        .onChange(of: swapAxes) { v in engine.cmd("swapaxes", v ? 1 : 0) }

                    Text("Если наклон телефона вперёд уходит в крен — включите «Поменять местами». Порядок осей подбирается, если всё равно крутится странно.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                // --- Инверсии ---
                Section(header: Text("Инверсия осей")) {
                    Toggle("Поворот влево/вправо", isOn: $invYaw)
                        .onChange(of: invYaw) { v in engine.cmd("yawsign", v ? 1 : -1) }
                    Toggle("Наклон вверх/вниз", isOn: $invPitch)
                        .onChange(of: invPitch) { v in engine.cmd("pitchsign", v ? -1 : 1) }
                    Toggle("Крен (наклон головы)", isOn: $invRoll)
                        .onChange(of: invRoll) { v in engine.cmd("rollsign", v ? -1 : 1) }
                }

                // --- Подстройка курса ---
                Section(header: Text("Подстройка курса")) {
                    HStack {
                        Text("Yaw trim")
                        Spacer()
                        Text(String(format: "%.0f°", yawTrim)).foregroundColor(.secondary)
                    }
                    Slider(value: $yawTrim, in: -90...90, step: 1)
                        .onChange(of: yawTrim) { v in engine.cmd("yawtrim", v) }
                }

                // --- Движение ---
                Section(header: Text("Движение по карте")) {
                    HStack {
                        Text("Скорость (м/с)")
                        Spacer()
                        Text(String(format: "%.0f", moveSpeed)).foregroundColor(.secondary)
                    }
                    Slider(value: $moveSpeed, in: 2...80, step: 1)
                        .onChange(of: moveSpeed) { v in engine.cmd("speed", v) }

                    HStack {
                        Text("Скорость вверх/вниз")
                        Spacer()
                        Text(String(format: "%.0f", vertSpeed)).foregroundColor(.secondary)
                    }
                    Slider(value: $vertSpeed, in: 2...80, step: 1)
                        .onChange(of: vertSpeed) { v in engine.cmd("vspeed", v) }

                    Toggle("Инверсия джойстика по Y", isOn: $invertJoyY)
                        .onChange(of: invertJoyY) { v in engine.cmd("invertjoyy", v ? 1 : 0) }
                }

                // --- Сброс ---
                Section {
                    Button(role: .destructive) {
                        resetAll()
                    } label: {
                        Text("Сбросить все настройки камеры")
                    }
                    Text("Сбрасывает как локальные настройки, так и параметры мода на ПК.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                // --- Экран ---
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

    private func setFov(_ v: Double) {
        fov = v
        fovTouched = true
        engine.sendFov(v, force: true)
    }

    private func resetAll() {
        let d = UserDefaults.standard

        // Камера
        d.set(1.0,  forKey: "sens")
        d.set(12.0, forKey: "smooth")
        d.set(0.0,  forKey: "deadzone")
        d.set(89.0, forKey: "maxPitch")
        d.set(0.0,  forKey: "autoCenterSec")
        d.set("zxy",forKey: "eulerOrder")
        d.set(true, forKey: "swapAxes")
        d.set(false,forKey: "invYaw")
        d.set(false,forKey: "invPitch")
        d.set(false,forKey: "invRoll")
        d.set(0.0,  forKey: "yawTrim")

        // Движение
        d.set(12.0, forKey: "moveSpeed")
        d.set(12.0, forKey: "vertSpeed")
        d.set(false,forKey: "invertJoyY")

        // FOV
        d.set(75.0, forKey: "fov")
        d.set(false,forKey: "fovTouched")

        // Локальные @AppStorage обновятся автоматически (они читают UserDefaults)

        // Сброс на стороне мода
        engine.resetModDefaults()
        // И продублируем все настройки, чтобы мод точно применил
        engine.pushSettings()
    }
}

// MARK: - App

@main
struct PhoneCamApp: App {
    init() {
        UserDefaults.standard.register(defaults: [
            "pcIP": "192.168.1.50",

            // Камера
            "sens": 1.0,
            "smooth": 12.0,
            "deadzone": 0.0,
            "maxPitch": 89.0,
            "autoCenterSec": 0.0,
            "eulerOrder": "zxy",
            "swapAxes": true,

            // Инверсии
            "invYaw": false,
            "invPitch": false,
            "invRoll": false,

            // FOV
            "fov": 75.0,
            "fovMin": 20.0,
            "fovMax": 120.0,

            // Движение
            "yawTrim": 0.0,
            "moveSpeed": 12.0,
            "vertSpeed": 12.0,
            "invertJoyY": false,

            // Время
            "timeHour": 12.0,
            "timeFlow": false
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(.dark)
        }
    }
}
