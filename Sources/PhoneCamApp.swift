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

    // Отправка произвольной текстовой команды в мод
    func send(_ text: String) {
        conn?.send(content: text.data(using: .utf8), completion: .idempotent)
    }

    func cmd(_ name: String, _ value: Double) {
        send("\(name),\(String(format: "%.3f", value))")
    }

    // Время суток (часы 0...24), с ограничением частоты
    func sendTime(_ hour: Double, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastTimeSend) > 0.1 {
            lastTimeSend = now
            cmd("time", hour)
        }
    }

    // FOV (градусы), с ограничением частоты
    func sendFov(_ fov: Double, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastFovSend) > 0.05 {
            lastFovSend = now
            cmd("fov", fov)
        }
    }

    // MARK: Движение по карте

    func setJoystick(_ x: Double, _ y: Double) {
        joyX = x
        joyY = y
        refreshMove()
    }

    func setVertical(_ z: Double) {
        vert = z
        refreshMove()
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
        cmd("sens", d.double(forKey: "sens"))
        cmd("smooth", d.double(forKey: "smooth"))
        cmd("yawtrim", d.double(forKey: "yawTrim"))
        cmd("speed", d.double(forKey: "moveSpeed"))
        cmd("yawsign", d.bool(forKey: "invYaw") ? 1 : -1)
        cmd("pitchsign", d.bool(forKey: "invPitch") ? -1 : 1)
        cmd("rollsign", d.bool(forKey: "invRoll") ? -1 : 1)
        if d.bool(forKey: "fovTouched") { cmd("fov", d.double(forKey: "fov")) }
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
        // Только настройки. Центр НЕ ставим автоматически: наведите телефон
        // как вам удобно и нажмите кнопку "Центр".
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
        // Жесты (щипок = FOV, двойной тап) обрабатывает SwiftUI, а не веб-страница
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
    let onChange: (Double, Double) -> Void   // x вправо, y вперёд (-1...1)

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
                    let scaled: CGFloat = mag < 0.08 ? 0 : mag * mag   // плавнее у центра
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

// MARK: - Главный экран (камера)

struct ContentView: View {
    @StateObject private var engine = PhoneCamEngine()
    @AppStorage("pcIP") private var pcIP = "192.168.1.50"
    @AppStorage("fillScreen") private var fillScreen = false
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("timeHour") private var timeHour = 12.0
    @AppStorage("fov") private var fov = 75.0
    @AppStorage("fovTouched") private var fovTouched = false

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

            // Слой жестов: щипок = FOV в игре, двойной тап = сброс FOV
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

    // MARK: Верхняя панель

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

    // MARK: Нижняя панель: центр | джойстик | высота

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

    // MARK: Действия

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

    // Зум щипком = угол обзора (FOV) в игре: масштаб k -> tan(fov/2) / k
    private func applyPinch(_ scale: CGFloat) {
        if pinchBase == nil { pinchBase = fov }
        let base = pinchBase ?? fov
        let half = base * Double.pi / 360.0
        let k = Double(max(scale, 0.05))
        let newFov = 2.0 * atan(tan(half) / k) * 180.0 / Double.pi
        fov = min(max(newFov, 20), 120)
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

    @AppStorage("pcIP") private var pcIP = "192.168.1.50"
    @AppStorage("sens") private var sens = 1.0
    @AppStorage("smooth") private var smooth = 12.0
    @AppStorage("fov") private var fov = 75.0
    @AppStorage("fovTouched") private var fovTouched = false
    @AppStorage("yawTrim") private var yawTrim = 0.0
    @AppStorage("moveSpeed") private var moveSpeed = 12.0
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
                        Text("Угол обзора (FOV)")
                        Spacer()
                        Text(String(format: "%.0f°", fov)).foregroundColor(.secondary)
                    }
                    Slider(value: $fov, in: 20...120, step: 1)
                        .onChange(of: fov) { v in
                            fovTouched = true
                            engine.sendFov(v)
                        }
                    Text("На главном экране зум делается щипком двумя пальцами (это FOV в игре). Двойной тап - сброс до 75°.")
                        .font(.footnote).foregroundColor(.secondary)
                    Button("Сбросить FOV (75°)") {
                        fov = 75
                        fovTouched = true
                        engine.sendFov(75, force: true)
                    }

                    HStack {
                        Text("Подстройка курса")
                        Spacer()
                        Text(String(format: "%.0f°", yawTrim)).foregroundColor(.secondary)
                    }
                    Slider(value: $yawTrim, in: -90...90, step: 1)
                        .onChange(of: yawTrim) { v in engine.cmd("yawtrim", v) }
                    Text("Если машина не по центру кадра при взгляде вперёд - сдвиньте курс.")
                        .font(.footnote).foregroundColor(.secondary)

                    HStack {
                        Text("Чувствительность поворота")
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

                    Button("Центрировать камеру") { engine.send("recenter") }
                }

                Section(header: Text("Движение по карте")) {
                    HStack {
                        Text("Скорость (м/с)")
                        Spacer()
                        Text(String(format: "%.0f", moveSpeed)).foregroundColor(.secondary)
                    }
                    Slider(value: $moveSpeed, in: 2...80, step: 1)
                        .onChange(of: moveSpeed) { v in engine.cmd("speed", v) }
                    Text("Джойстик двигает камеру по направлению взгляда, кнопки ▲▼ - вверх/вниз.")
                        .font(.footnote).foregroundColor(.secondary)
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
            "yawTrim": 0.0,
            "moveSpeed": 12.0,
            "timeHour": 12.0
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(.dark)
        }
    }
}
