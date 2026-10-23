import Foundation

/// termproxy + vncwebsocket 프로토콜 구현
///
/// Proxmox termproxy 프로토콜 (binary 웹소켓, subprotocol "binary"):
///  1. POST /nodes/{node}/termproxy            (노드 셸)
///     POST /nodes/{node}/lxc/{vmid}/termproxy  (LXC 콘솔)
///     POST /nodes/{node}/qemu/{vmid}/termproxy (VM 시리얼 콘솔)
///     → { user, ticket, port }
///  2. WS /api2/json/nodes/{node}/vncwebsocket?port=..&vncticket=..
///     첫 프레임: "<user>:<ticket>\n"  (응답 "OK")
///  3. 리사이즈: "1:<cols>:<rows>:"
///     입력:     "0:<len>:<데이터>"
///     킵얼라이브(30초): "2"
public final class TermService: NSObject {
    public struct Target {
        public var node: String
        public var vmid: Int?      // nil이면 노드 셸
        public var isVM: Bool      // lxc / qemu
        public init(node: String, vmid: Int? = nil, isVM: Bool = false) {
            self.node = node; self.vmid = vmid; self.isVM = isVM
        }
    }

    public enum State { case connecting, connected, closed(String) }

    private let client: PVEClient
    private let target: Target
    private var ws: URLSessionWebSocketTask?
    private var keepalive: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    public var onData: ((Data) -> Void)?
    public var onStateChange: ((State) -> Void)?

    public init(client: PVEClient, target: Target) {
        self.client = client
        self.target = target
    }

    public func start(cols: Int, rows: Int) {
        let p = target.vmid == nil
            ? "/api2/json/nodes/\(target.node)/termproxy"
            : (target.isVM ? "/api2/json/nodes/\(target.node)/qemu/\(target.vmid!)/termproxy"
                           : "/api2/json/nodes/\(target.node)/lxc/\(target.vmid!)/termproxy")

        reader = Task { [weak self] in
            guard let self else { return }
            do {
                self.onStateChange?(.connecting)
                guard let data = try await self.client.postJSON(p, form: [:]) as? [String: Any],
                      let portVal = data["port"],
                      let ticket = data["ticket"] as? String,
                      let user = data["user"] as? String else {
                    throw PVEError(status: 0, message: "termproxy 응답 파싱 실패")
                }
                let port = Int("\(portVal)") ?? 0
                let enc = self.client.percentEncode(ticket)
                var req = URLRequest(url: URL(string: "https://\(self.client.host):\(self.client.port)/api2/json/nodes/\(self.target.node)/vncwebsocket?port=\(port)&vncticket=\(enc)")!)
                req.setValue("PVEAuthCookie=\(self.client.percentEncode(self.client.ticket))", forHTTPHeaderField: "Cookie")
                req.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")

                let ws = self.client.session.webSocketTask(with: req)
                self.ws = ws
                ws.resume()

                // 인증 프레임 전송 → "OK" 확인
                try await self.sendAsync(ws, .data(Data("\(user):\(ticket)\n".utf8)))
                let ack = try await ws.receive()
                guard case let .data(d) = ack, String(decoding: d, as: UTF8.self) == "OK" else {
                    throw PVEError(status: 0, message: "터미널 인증 실패")
                }
                try await self.sendAsync(ws, .data(Data("1:\(cols):\(rows):".utf8)))
                self.onStateChange?(.connected)
                self.keepalive = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        try? await self?.sendAsync(self?.ws ?? ws, .data(Data("2".utf8)))
                    }
                }
                self.readLoop(ws)
            } catch {
                self.onStateChange?(.closed("연결 실패: \(error.localizedDescription)"))
            }
        }
    }

    private func sendAsync(_ ws: URLSessionWebSocketTask, _ msg: URLSessionWebSocketTask.Message) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ws.send(msg) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func readLoop(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .data(let d): self.onData?(d)
                case .string(let s): self.onData?(Data(s.utf8))
                @unknown default: break
                }
                if self.ws === ws { self.readLoop(ws) }
            case .failure(let e):
                if self.ws === ws {
                    self.onStateChange?(.closed("종료: \(e.localizedDescription)"))
                }
            }
        }
    }

    public func send(_ text: String) {
        let data = Data(text.utf8)
        let frame = "0:\(data.count):".data(using: .utf8)! + data
        ws?.send(.data(frame)) { _ in }
    }

    public func resize(cols: Int, rows: Int) {
        ws?.send(.data(Data("1:\(cols):\(rows):".utf8))) { _ in }
    }

    public func close() {
        keepalive?.cancel()
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        reader?.cancel()
        onStateChange?(.closed("사용자 종료"))
    }
}
