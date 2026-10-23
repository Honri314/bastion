import Foundation
import Network
import CryptoKit

/// URLSessionWebSocketTask는 Sec-WebSocket-Protocol 등 커스텀 헤더를 유실할 수 있어
/// PVE vncwebsocket 핸드셰이크가 1006으로 거부된다.
/// → Network.framework 위에 RFC6455를 직접 구현해 헤더를 보장한다.
public final class ManualWebSocket: NSObject {
    public var onOpen: (() -> Void)?
    public var onData: ((Data) -> Void)?
    public var onFail: ((String) -> Void)?
    public var onLog: ((String) -> Void)?

    private var conn: NWConnection?
    private var buf: [UInt8] = []
    private var handshakeDone = false
    private var failed = false
    private var userClosed = false
    /// 비-FIN 프레임 조립용
    private var frameBuf: [UInt8] = []
    private var accumulating = false
    private var pendingHost = "", pendingPath = ""
    private var pendingHeaders: [String: String] = [:]
    private let queue = DispatchQueue(label: "manualwebsocket")

    public override init() {
        super.init()
    }

    // MARK: - 연결
    public func connect(host: String, port: Int, path: String, headers: [String: String]) {
        queue.async { [weak self] in
            self?.doConnect(host: host, port: port, path: path, headers: headers)
        }
    }

    private func doConnect(host: String, port: Int, path: String, headers: [String: String]) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            fail("잘못된 포트: \(port)")
            return
        }
        // PVE는 자기서명 인증서 → 검증 스킵 (URLSession 대리자와 동일 동작)
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions, { _, _, complete in complete(true) },
            self.queue)
        let params = NWParameters(tls: tlsOptions)
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p)
        let conn = NWConnection(to: ep, using: params)
        self.conn = conn
        pendingHost = host; pendingPath = path; pendingHeaders = headers
        conn.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        conn.start(queue: queue)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendHandshake(host: pendingHost, path: pendingPath, headers: pendingHeaders)
        case .failed(let e):
            fail("TLS/네트워크 실패: \(e)")
        case .cancelled:
            if !userClosed { fail("연결이 끊겼습니다") }
        default:
            break
        }
    }

    private func sendHandshake(host: String, path: String, headers: [String: String]) {
        let keyBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        var hs = ""
        // path는 이미 percent-encoded 쿼리 포함
        hs += "GET \(path) HTTP/1.1\r\n"
        hs += "Host: \(host)\r\n"
        hs += "Upgrade: websocket\r\n"
        hs += "Connection: Upgrade\r\n"
        hs += "Sec-WebSocket-Key: \(key)\r\n"
        hs += "Sec-WebSocket-Version: 13\r\n"
        hs += "Sec-WebSocket-Protocol: binary\r\n"
        for (k, v) in headers { hs += "\(k): \(v)\r\n" }
        hs += "\r\n"
        conn?.send(content: Data(hs.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("핸드셰이크 전송 실패: \(error)") }
            else { self?.receiveOnce() }
        })
    }

    // MARK: - 수신 루프
    private func receiveOnce() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buf.append(contentsOf: data)
                self.processBuffer()
            }
            if let error {
                self.fail("WS 수신 오류: \(error)")
                return
            }
            if isComplete && data == nil {
                self.fail("서버가 연결을 닫았습니다 (TCP EOF, close 프레임 없음)\n→ 서버가 auth/첫 프레임을 기다리다 끊었을 가능성")
                return
            }
            self.receiveOnce()
        }
    }

    private func processBuffer() {
        // 1) HTTP 핸드셰이크 헤더
        if !handshakeDone {
            let sep: [UInt8] = Array("\r\n\r\n".utf8)
            guard let range = findBytes(buf, sep) else { return }
            let headerData = Data(buf[0..<range.lowerBound])
            buf.removeSubrange(0..<range.upperBound)
            let header = String(decoding: headerData, as: UTF8.self)
            let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? header
            guard firstLine.contains("101") else {
                let body = header.count > 300 ? String(header.prefix(300)) : header
                fail("핸드셰이크 거부됨: \(body)")
                conn?.cancel()
                return
            }
            // 서버가 선택한 서브프로토콜 확인 (관대함 — 없어도 진행)
            let selectedProto = header.split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("sec-websocket-protocol:") })
                .map(String.init) ?? "(응답에 서브프로토콜 없음)"
            logline("핸드셰이크 101 OK · 서버: \(selectedProto)")
            handshakeDone = true
            deliver { self.onOpen?() }
        }
        // 2) 프레임 파싱
        while true {
            if buf.count < 2 { return }
            let b0 = buf[0], b1 = buf[1]
            let fin = (b0 & 0x80) != 0
            let op = b0 & 0x0F
            let maskedBit = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var offset = 2
            if len == 126 {
                if buf.count < 4 { return }
                len = (Int(buf[2]) << 8) | Int(buf[3])
                offset = 4
            } else if len == 127 {
                if buf.count < 10 { return }
                var l: UInt64 = 0
                for i in 0..<8 { l = (l << 8) | UInt64(buf[2 + i]) }
                if l > 50_000_000 { fail("비정상적으로 큰 프레임: \(l)"); return }
                len = Int(l)
                offset = 10
            }
            let maskLen = maskedBit ? 4 : 0
            if buf.count < offset + maskLen + len { return }
            var mask: [UInt8] = []
            if maskedBit { mask = Array(buf[offset..<(offset + 4)]) }
            let payloadStart = offset + maskLen
            var payload = Array(buf[payloadStart..<(payloadStart + len)])
            buf.removeFirst(payloadStart + len)
            if maskedBit {
                for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
            }
            logFrame(fin: fin, op: op, payloadLen: len, first: Array(payload.prefix(8)))
            switch op {
            case 0x1, 0x2:               // text / binary
                if fin {
                    deliverData(payload)
                } else {
                    frameBuf = payload
                    accumulating = true
                }
            case 0x0:                    // continuation
                if accumulating {
                    frameBuf += payload
                    if fin {
                        accumulating = false
                        deliverData(frameBuf)
                        frameBuf = []
                    }
                }
            case 0x9:                    // ping → pong
                sendFrame(op: 0xA, payload)
            case 0xA:                    // pong
                break
            case 0x8:                    // close
                var code = 0
                if payload.count >= 2 {
                    code = (Int(payload[0]) << 8) | Int(payload[1])
                }
                if !userClosed { fail("서버가 WS를 닫았습니다 (close 프레임 code:\(code))") }
                conn?.cancel()
                return
            default:
                break
            }
        }
    }

    private func deliverData(_ payload: [UInt8]) {
        let data = Data(payload)
        deliver { self.onData?(data) }
    }

    private func findBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                return i..<(i + needle.count)
            }
        }
        return nil
    }

    // MARK: - 전송
    public func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.handshakeDone else { return }
            self.sendFrame(op: 0x2, [UInt8](data))
        }
    }

    private func sendFrame(op: UInt8, _ payload: [UInt8]) {
        var frame: [UInt8] = [0x80 | op]   // FIN=1, client → mask 필수
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(0x80 | len))
        } else if len < 65536 {
            frame.append(UInt8(0x80 | 126))
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(UInt8(0x80 | 127))
            let l = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((l >> UInt64(shift)) & 0xFF))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame += mask
        var masked = payload
        for i in 0..<masked.count { masked[i] ^= mask[i % 4] }
        frame += masked
        conn?.send(content: Data(frame), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("프레임 전송 실패: \(error)") }
        })
    }

    public func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.userClosed = true
            if self.handshakeDone {
                self.sendFrame(op: 0x8, [UInt8]([0x03, 0xE8]))
            }
            self.conn?.cancel()
        }
    }

    private func fail(_ msg: String) {
        guard !failed, !userClosed else { return }
        failed = true
        deliver { self.onFail?(msg) }
    }

    private func deliver(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    /// 진단 로그 → 메인 큐
    private func logline(_ s: String) {
        deliver { self.onLog?(s) }
    }

    private func logFrame(fin: Bool, op: UInt8, payloadLen: Int, first: [UInt8]) {
        let opName: String
        switch op {
        case 0x0: opName = "cont"; case 0x1: opName = "text"; case 0x2: opName = "bin"
        case 0x8: opName = "close"; case 0x9: opName = "ping"; case 0xA: opName = "pong"
        default: opName = "\(op)"
        }
        let ascii = first.map { b -> Character in (b >= 32 && b < 127) ? Character(UnicodeScalar(b)) : "." }.map(String.init).joined()
        logline("recv frame fin=\(fin) op=\(opName) len=\(payloadLen) '\(ascii)'")
    }
}
