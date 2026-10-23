import Foundation

public struct PVEError: Error, LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? { "PVE 오류 (\(status)): \(message)" }
}

/// Proxmox VE API 클라이언트 (PVEAuthCookie 티켓 기반)
public final class PVEClient: NSObject {
    public var host: String = ""
    public var port: Int = 8006
    public var user: String = ""
    public var ticket: String = ""
    public var csrfToken: String = ""
    public var otp: String = ""
    public var realm: String = "pam"
    /// 자동 재로그인용으로만 메모리에 보관
    public var password: String = ""

    var insecureTLS: Bool = true

    public private(set) lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    public var isLoggedIn: Bool { !ticket.isEmpty && !host.isEmpty }

    public func baseURL(path: String) -> URL {
        return URL(string: "https://\(host):\(port)\(path)")!
    }

    public func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    // MARK: - 로그인
    public func login(host: String, port: Int, user: String, realm: String, password: String, otp: String) async throws {
        self.host = host
        self.port = port
        self.user = user
        self.realm = realm
        self.otp = otp
        self.password = password
        try await authenticate()
    }

    func authenticate() async throws {
        var form = ["username": "\(user)@\(realm)", "password": password]
        if !otp.isEmpty { form["otp"] = otp }
        // allowReauth=false: 인증 실패 시 재시도 루프 없이 곧바로 에러 반환
        let raw: [String: Any] = try await request("POST", "/api2/json/access/ticket", form: form, allowReauth: false)
        guard let data = raw["data"] as? [String: Any],
              let t = data["ticket"] as? String,
              let c = data["CSRFPreventionToken"] as? String else {
            let m = (raw["errors"] as? String) ?? (raw["message"] as? String) ?? "로그인 실패"
            throw PVEError(status: 401, message: m)
        }
        ticket = t
        csrfToken = c
    }

    // MARK: - 공통 요청
    /// allowReauth: 401 티켓 만료 시 재로그인 1회 허용 여부.
    /// false면 401을 곧바로 에러로 던진다 — 잘못된 비밀번호로 authenticate↔perform
    /// 상호 재귀(무한 로딩)에 빠지는 것을 막는다.
    public func request(_ method: String, _ path: String, form: [String: String]? = nil, allowReauth: Bool = true) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL(path: path))
        req.httpMethod = method
        req.setValue("PVEAuthCookie=\(percentEncode(ticket))", forHTTPHeaderField: "Cookie")
        if method != "GET" && method != "HEAD" {
            req.setValue(csrfToken, forHTTPHeaderField: "CSRFPreventionToken")
        }
        if let form = form {
            // 키/값 각각만 인코딩 — '='와 '&'는 구분자로 유지해야 서버가 파싱할 수 있다
            let body = form.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.joined(separator: "&")
            req.httpBody = body.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(req, allowReauth: allowReauth)
    }

    private func perform(_ req: URLRequest, allowReauth: Bool = true) async throws -> [String: Any] {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw PVEError(status: -1, message: "네트워크 오류: \(error.localizedDescription)") }
        guard let http = resp as? HTTPURLResponse else {
            throw PVEError(status: -1, message: "응답 파싱 실패")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
        // 티켓 만료 → 자동 재로그인 1회 (400 이상 throw보다 먼저 판정해야 도달 가능)
        if http.statusCode == 401, allowReauth, !password.isEmpty {
            try await authenticate()
            return try await perform(req, allowReauth: false)
        }
        if http.statusCode >= 400 {
            let m = (obj["errors"] as? String) ?? (obj["message"] as? String)
                ?? (obj["data"] as? String) ?? "HTTP \(http.statusCode)"
            throw PVEError(status: http.statusCode, message: m)
        }
        return obj
    }

    public func getJSON(_ path: String) async throws -> Any? {
        try await request("GET", path)["data"]
    }

    public func realmList() async throws -> [String: Any] {
        try await request("GET", "/api2/json/access/domains")
    }

    public func postJSON(_ path: String, form: [String: String]) async throws -> Any? {
        try await request("POST", path, form: form)["data"]
    }

    public func deleteJSON(_ path: String) async throws -> Any? {
        try await request("DELETE", path)["data"]
    }

    public func putJSON(_ path: String, form: [String: String]) async throws -> Any? {
        try await request("PUT", path, form: form)["data"]
    }
}

extension CharacterSet {
    static func union(_ a: CharacterSet, _ b: CharacterSet) -> CharacterSet { a.union(b) }
}

extension PVEClient: URLSessionDelegate {
    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if insecureTLS, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
