import SwiftUI
import WebKit
import ProxmoxKit



// MARK: - WKWebView 브릿지 컨트롤러 (터미널)
/// 임베디드 WKWebView는 직접 네트워크를 쓰지 않고 Swift(URLSession, TLS 수용)로만 PVE와 통신
@MainActor
final class TermBridgeController: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    let service: TermService

    init(client: PVEClient, target: TermService.Target) {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: cfg)
        service = TermService(client: client, target: target)
        super.init()
        cfg.userContentController.add(self, name: "bridge")
    }

    func load() {
        guard let html = ProxmoxKitResources.url("terminal.html") else { return }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch obj["t"] as? String {
        case "input":
            if let b64 = obj["d"] as? String, let d = Data(base64Encoded: b64) {
                service.send(String(decoding: d, as: UTF8.self))
            }
        case "resize":
            service.resize(cols: obj["cols"] as? Int ?? 80, rows: obj["rows"] as? Int ?? 25)
        default:
            break
        }
    }

    func serverData(_ data: Data) {
        let b64 = data.base64EncodedString()
        webView.evaluateJavaScript("window.termIn && window.termIn('\(b64)')")
    }
}


// MARK: - WKWebView 재사용 래퍼
struct TerminalRep: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - 셸 창
@MainActor
final class ShellWindowVM: ObservableObject {
    @Published var stateText: String = "연결 중..."
    var controller: TermBridgeController?

    func start(client: PVEClient, target: TermService.Target) {
        guard controller == nil else { return }
        let c = TermBridgeController(client: client, target: target)
        controller = c
        c.load()
        c.service.onData = { [weak self] data in
            Task { @MainActor in self?.controller?.serverData(data) }
        }
        c.service.onStateChange = { [weak self] st in
            Task { @MainActor in
                switch st {
                case .connecting: self?.stateText = "연결 중..."
                case .connected: self?.stateText = "연결됨"
                case .closed(let reason): self?.stateText = "종료: \(reason)"
                }
            }
        }
        c.service.start(cols: 120, rows: 32)
    }
}

struct ShellWindow: View {
    let target: TermService.Target
    @EnvironmentObject var app: AppState
    @StateObject private var vm = ShellWindowVM()

    var name: String {
        target.vmid.map { "VM \($0)" } ?? "노드 셸"
    }

    var body: some View {
        Group {
            if let c = vm.controller {
                TerminalRep(view: c.webView)
            } else {
                ProgressView("터미널 초기화 중...")
            }
        }
        .toolbar {
            Text(vm.stateText).font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("\(name) · \(target.node)")
        .onAppear {
            if let c = app.client { vm.start(client: c, target: target) }
        }
        .onDisappear { vm.controller?.service.close() }
    }
}

// MARK: - noVNC 콘솔 창
public struct VNCConfig: Hashable {
    public var host: String
    public var port: Int
    public var node: String
    public var vmid: Int
    public init(host: String, port: Int, node: String, vmid: Int) {
        self.host = host; self.port = port; self.node = node; self.vmid = vmid
    }
}

@MainActor
final class VNCBridgeController: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    let client: PVEClient
    let config: VNCConfig
    var ws: ManualWebSocket?
    var relayOn = false
    var awaitingOK = true
    var sendQueue: [Data] = []  // 릴레이 준비 전 JS→서버 데이터 백스톱
    var active = true
    var log: (String) -> Void = { _ in }
    var frameCount = 0
    var vncPassB64 = ""         // RFB VNC 암호 = vncticket (base64, JS에 주입용)
    var authFallback: Task<Void, Never>?  // 서버가 먼저 말하지 않을 때 인증 프레임 폴백

    init(client: PVEClient, config: VNCConfig, log: @escaping (String) -> Void = { _ in }) {
        self.client = client
        self.config = config
        self.log = log
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "vncbridge")
    }

    func load() {
        guard let html = ProxmoxKitResources.url("novnc.html") else { return }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "vncbridge",
              let msg = message.body as? String,
              let data = msg.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch obj["t"] as? String {
        case "connect":
            log("JS 브릿지 connect 요청 수신")
            Task { await connect() }
        case "send":
            if let b64 = obj["d"] as? String { jsToServer(b64) }
        case "log":
            log("JS | \(obj["m"] as? String ?? "")")
        case "close":
            close()
        default:
            break
        }
    }

    private func connect() async {
        do {
            // 게스트 OS / 디스플레이 감지: Windows도 기본은 VNC이지만,
            // display=spice 설정이면 vncproxy가 실패한다 — 미리 안내
            if let cfg = try? await client.getJSON("/api2/json/nodes/\(config.node)/qemu/\(config.vmid)/config") as? [String: Any] {
                let ostype = (cfg["ostype"] as? String) ?? "-"
                let display = (cfg["display"] as? String) ?? ""
                log("게스트 OS ostype=\(ostype) display=\(display.isEmpty ? "(미설정 → VNC)" : display)")
                if display.contains("spice") {
                    log("주의: SPICE 디스플레이 VM — 이 앱은 VNC 그래픽 콘솔만 지원합니다")
                    sendError("VM이 SPICE 표시로 설정되어 있어 VNC 콘솔을 열 수 없습니다. PVE 웹에서 display를 기본값으로 바꾸거나 SPICE 클라이언트를 쓰세요")
                    return
                }
            }
            guard let data = try await client.postJSON("/api2/json/nodes/\(config.node)/qemu/\(config.vmid)/vncproxy", form: ["websocket": "1"]) as? [String: Any],
                  let portVal = data["port"], let vncticket = data["ticket"] as? String,
                  let user = data["user"] as? String else {
                sendError("vncproxy 요청 실패")
                return
            }
            let port = Int("\(portVal)") ?? 0
            log("vncproxy OK port=\(port) ticket=\(vncticket.prefix(8))…")
            vncPassB64 = Data(vncticket.utf8).base64EncodedString()
            let enc = client.percentEncode(vncticket)
            let path = "/api2/json/nodes/\(config.node)/qemu/\(config.vmid)/vncwebsocket?port=\(port)&vncticket=\(enc)"

            let sock = ManualWebSocket()
            self.ws = sock
            sock.onLog = { [weak self] s in
                self?.log("[ws] \(s)")
            }
            sock.onOpen = { [weak self] in
                guard let self, self.active else { return }
                /* ★ 인증 프레임을 즉시 보내지 않는다 — VNC 웹소켓은 원시 릴레이(QEMU)라서
                   첫 12바이트가 버전 문자열이어야 한다. user:ticket\n인증 프레임이 먼저
                   흘러가면 QEMU가 그것을 버전으로 읽어 접속을 끊는다 (확인된 원인).
                   서버가 1.2초 내 먼저 보내지 않을 때(terminal형 서버)에만 폴백 전송. */
                self.log("WS 핸드셰이크 완료 (서버 첫 데이터 대기)")
                let authFrame = Data("\(user):\(vncticket)\n".utf8)
                self.authFallback?.cancel()
                self.authFallback = Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard !Task.isCancelled, self.active, self.awaitingOK, !self.relayOn else { return }
                    self.log("1.2초 무응답 → 인증 프레임 폴백 전송 (terminal형 서버)")
                    self.ws?.send(authFrame)
                }
            }
            sock.onData = { [weak self] d in
                self?.handleServerData(d)
            }
            sock.onFail = { [weak self] msg in
                guard let self, self.active else { return }
                self.log("[native] WS 실패: \(msg)")
                self.sendError(msg)
            }
            log("WS 수동 핸드셰이크 시도 (subprotocol=binary 강제)")
            awaitingOK = true
            sock.connect(host: client.host, port: client.port, path: path,
                         headers: ["Cookie": "PVEAuthCookie=\(client.percentEncode(client.ticket))"])
        } catch {
            sendError(error.localizedDescription)
        }
    }

    private func handleServerData(_ d: Data) {
        guard active else { return }
        authFallback?.cancel()
        authFallback = nil
        if awaitingOK {
            awaitingOK = false
            let text = String(decoding: d, as: UTF8.self)
            let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            // 두 가지 서버 유형을 모두 지원:
            //  A) auth 프레임 뒤 "OK": 릴레이 시작, OK 프레임은 흘리지 않음
            //  B) auth 없이 바로 RFB 배너: 릴레이 시작 + 배너를 RFB 스트림으로 전달
            if upper.contains("OK") {
                relayOn = true
                log("OK 수신 → RFB 릴레이 시작 (vncReady 호출)")
                // 티켓(VNC 암호) 주입 + onopen 발사를 한 스크립트로 (순서 보장)
                webView.evaluateJavaScript("window.vncPassword=atob('\(vncPassB64)');window.vncReady && window.vncReady()")
                let queued = sendQueue
                sendQueue = []
                for q in queued { ws?.send(q) }
                return   // "OK" 프레임 자체는 RFB 스트림으로 흘리면 안 된다
            }
            if text.hasPrefix("RFB ") {
                relayOn = true
                log("RFB 배너 직활 (raw 릴레이 서버) → 릴레이 시작, 티켓=VNC 암호")
                // 티켓 주입 + onopen + 첫 RFB 데이터 전달을 한 스크립트로 (순서 보장)
                let b64 = d.base64EncodedString()
                webView.evaluateJavaScript("window.vncStart && window.vncStart('\(b64)','\(vncPassB64)')")
                let queued = sendQueue
                sendQueue = []
                for q in queued { ws?.send(q) }
                return
            } else {
                sendError("인증 실패: \(String(text.prefix(120)))")
                return
            }
        }
        frameCount += 1
        if frameCount <= 4 {
            let ascii = d.prefix(20).map { b -> Character in (b >= 32 && b < 127) ? Character(UnicodeScalar(b)) : "." }.map(String.init).joined()
            log("recv #\(frameCount) len=\(d.count) '\(ascii)'")
        }
        let b64 = d.base64EncodedString()
        webView.evaluateJavaScript("window.vncMessage && window.vncMessage('\(b64)')")
    }

    func jsToServer(_ b64: String) {
        guard let data = Data(base64Encoded: b64) else { return }
        if relayOn {
            ws?.send(data)
        } else if sendQueue.count < 64 {
            sendQueue.append(data)  // 아직 릴레이 준비 전 — 대기열에 적둔다
        }
    }

    func close() {
        active = false
        relayOn = false
        authFallback?.cancel()
        authFallback = nil
        ws?.close()
    }

    private func sendError(_ text: String) {
        let safe = text.replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.vncFail && window.vncFail('\(safe)')")
    }
}

struct VNCWindow: View {
    let config: VNCConfig
    @EnvironmentObject var app: AppState
    @State private var controller: VNCBridgeController?
    @State private var logs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if let c = controller {
                TerminalRep(view: c.webView)
            } else {
                ProgressView("콘솔 초기화 중...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if app.showVNCLog {
                logPanel
            }
        }
        .onAppear {
            if controller == nil, let client = app.client {
                let c = VNCBridgeController(client: client, config: config) { line in
                    // WKScriptMessageHandler 콜백 → 메인스레드
                    DispatchQueue.main.async {
                        logs.append("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
                        if logs.count > 200 { logs.removeFirst(100) }
                    }
                }
                controller = c
                c.load()
            }
        }
        .onDisappear { controller?.close() }
        .navigationTitle("콘솔 · VM \(config.vmid) · \(config.node)")
    }

    /// 하단 로그 패널 (메뉴바 '콘솔 → VNC 로그 표시' 토글로 켬/끔)
    private var logPanel: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("VNC 연결 로그 (최근 12줄 — 실패 원인이 ‘연결 해제됨’에 덮여도 아래에 남습니다)")
                    .font(.caption2).foregroundStyle(.tertiary)
                ForEach(logs.suffix(12), id: \.self) { row in
                    Text(row).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string)
            } label: { Text("로그 복사").font(.caption2) }
            .buttonStyle(.link)
            .disabled(logs.isEmpty)
            .help("전체 로그를 클립보드에 복사 (이후 붙여넣기로 전달)")
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 150, alignment: .top)
    }
}
