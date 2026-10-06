// PhoneCamApp.swift
// iOS 15+. Один файл: показывает WebRTC-поток с ПК и шлёт ориентацию по UDP.
//
// Info.plist:
//   NSLocalNetworkUsageDescription = "Подключение к ПК для камеры BeamNG"
//   NSAppTransportSecurity -> NSAllowsLocalNetworking = YES   (http:// в локальной сети)
// Ориентация приложения: Landscape Right (кнопка Home справа) - телефон в VR-держателе.

import SwiftUI
import CoreMotion
import Network
import WebKit

// MARK: - Отправка ориентации

final class MotionSender: ObservableObject {
    @Published var running = false

    private let motion = CMMotionManager()
    private var conn: NWConnection?
    private let queue = OperationQueue()

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
        motion.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] dm, _ in
            guard let self, let m = dm?.attitude.rotationMatrix else { return }

            // Телефон в ландшафте (home справа, смотрим "в экран").
            // CMRotationMatrix переводит мировые векторы в систему устройства,
            // поэтому мировые направления = строки матрицы (транспонирование).
            let fx = -m.m31, fy = -m.m32, fz = -m.m33   // вперёд (взгляд)
            let rz = m.m23                               // вертикальная компонента "вправо"

            let toDeg = 180.0 / Double.pi
            let pitch = asin(max(-1, min(1, fz))) * toDeg      // + = вверх
            let roll  = -asin(max(-1, min(1, rz))) * toDeg     // + = по часовой
            let yaw   = -atan2(fy, fx) * toDeg                 // + = вправо

            let s = String(format: "%.2f,%.2f,%.2f", pitch, roll, yaw)
            self.conn?.send(content: s.data(using: .utf8), completion: .idempotent)
        }
        DispatchQueue.main.async { self.running = true }
    }

    func recenter() {
        conn?.send(content: "recenter".data(using: .utf8), completion: .idempotent)
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        conn?.cancel()
        conn = nil
        DispatchQueue.main.async { self.running = false }
    }
}

// MARK: - WebRTC-просмотр (страница MediaMTX)

struct StreamView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url != url { web.load(URLRequest(url: url)) }
    }
}

// MARK: - UI

struct ContentView: View {
    @AppStorage("pcIP") private var pcIP = "192.168.1.50"
    @StateObject private var sender = MotionSender()
    @State private var showStream = false
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if showStream, let url = URL(string: "http://\(pcIP):8889/beam") {
                StreamView(url: url).ignoresSafeArea()
            }

            if showControls {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("IP ПК", text: $pcIP)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .frame(width: 180)
                    HStack {
                        Button(sender.running ? "Стоп" : "Старт") {
                            if sender.running {
                                sender.stop(); showStream = false
                            } else {
                                sender.start(host: pcIP); showStream = true
                            }
                        }
                        Button("Центр") { sender.recenter() }
                        Button("Скрыть") { showControls = false }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .onTapGesture(count: 3) { showControls.toggle() } // тройной тап — вернуть панель
        .statusBar(hidden: true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

@main
struct PhoneCamApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
