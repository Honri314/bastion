import SwiftUI
import AppKit
import ProxmoxKit

/// 사이드바 선택 항목
enum NavSelection: Hashable {
    case overview
    case users
    case firewall
    case backupJobs
    case node(String)
    case guest(node: String, type: String, vmid: Int, name: String)
    case storage
    case tasks
    case api
}

@main
struct ProxmoxManagerApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("콘솔") {
                Toggle("VNC 로그 표시", isOn: Binding(
                    get: { app.showVNCLog },
                    set: { app.showVNCLog = $0 }))
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help("VM 콘솔 창 하단의 VNC 연결 로그 패널을 켜고 끕니다")
            }
        }

        WindowGroup("셸", id: "shell") {
            if let target = app.pendingShell {
                ShellWindow(target: target)
                    .environmentObject(app)
            } else {
                Text("터미널 대상이 없습니다.")
            }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)

        WindowGroup("VM 콘솔", id: "vnc") {
            if let vnc = app.pendingVNC {
                VNCWindow(config: vnc)
                    .environmentObject(app)   // EnvironmentObject 미주입 시 열자마다 크래시
            } else {
                Text("콘솔 대상이 없습니다.")
            }
        }
        .windowStyle(.automatic)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var client: PVEClient?
    @Published var loggedIn = false
    @Published var loginError: String?
    @Published var selection: NavSelection? = .overview

    @Published var resources: [ClusterResource] = []
    @Published var clusterName: String = "Cluster"
    @Published var lastError: String?
    @Published var autoRefresh: Bool = true

    /// 새 창으로 열 터미널/콘솔 대상
    @Published var pendingShell: TermService.Target?
    @Published var pendingVNC: VNCConfig?

    /// VNC 콘솔 하단 로그 패널 표시 여부 (앱 메뉴바 '콘솔' 메뉴에서 토글)
    @Published var showVNCLog: Bool {
        didSet { UserDefaults.standard.set(showVNCLog, forKey: "showVNCLog") }
    }

    init() {
        showVNCLog = UserDefaults.standard.object(forKey: "showVNCLog") as? Bool ?? true
    }

    private var timer: Timer?

    func login(host: String, port: Int, user: String, realm: String, password: String, otp: String) async {
        loginError = nil
        let c = PVEClient()
        do {
            try await c.login(host: host, port: port, user: user, realm: realm, password: password, otp: otp)
            client = c
            loggedIn = true
            try? await refresh()
            startTimer()
        } catch {
            loginError = (error as? PVEError)?.message ?? error.localizedDescription
        }
    }

    func logout() {
        timer?.invalidate()
        client = nil
        loggedIn = false
        resources = []
    }

    func openShell(_ target: TermService.Target) {
        pendingShell = target
    }

    func openVNC(_ config: VNCConfig) {
        pendingVNC = config
    }

    /// 클러스터 리소스 새로고침
    func refresh() async throws {
        guard let c = client else { return }
        do {
            let data = try await c.getJSON("/api2/json/cluster/resources")
            if let arr = data as? [[String: Any]] {
                // 항목 하나의 JSON 필드가 예상과 다르더라도 나머지는 유지 (전체 실패 방지)
                var decoded: [ClusterResource] = []
                var badTypes: Set<String> = []
                for item in arr {
                    if let j = try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed]),
                       let r = try? JSONDecoder().decode(ClusterResource.self, from: j) {
                        decoded.append(r)
                    } else {
                        badTypes.insert(item["type"] as? String ?? "?")
                    }
                }
                resources = decoded
                if !badTypes.isEmpty {
                    lastError = "일부 리소스 파싱 실패: \(badTypes.sorted().joined(separator: ", "))"
                }
            }
            if let st = try? await c.getJSON("/api2/json/cluster/status") as? [[String: Any]],
               let first = st.first(where: { $0["type"] as? String == "cluster" }) {
                clusterName = first["name"] as? String ?? "Standalone"
            }
            lastError = nil
        } catch {
            lastError = (error as? PVEError)?.message ?? "\(error)"
            throw error
        }
    }

    func refreshQuiet() { Task { try? await refresh() } }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.autoRefresh, self.loggedIn else { return }
            Task { try? await self.refresh() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.loggedIn {
            MainView()
        } else {
            LoginView()
        }
    }
}
