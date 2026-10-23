import SwiftUI
import AppKit
import ProxmoxKit

// MARK: - 한글 입력(구름입력기 등) 조합 버그 회피 필드
/// macOS의 SwiftUI Form(.formStyle(.grouped) 포함) TextField에서 한글 IME 조합 중
/// 값이 SwiftUI에 의해 덮혀져 조합이 한 글자씩 밀리는 시스템 버그가 있다.
/// AppKit NSTextField를 직접 래핑하고 조합(마크) 중에는 바인딩 값을 뷰에 다시 쓰지 않아
/// 조합이 끝날 때까지 보존한다. AppKit 필드는 macOS 네이티브 입력 시스템을 쓰므로
/// 구름입력기 등 IME가 정상 동작한다.
struct IMEField: NSViewRepresentable {
    let placeholder: String
    var secure: Bool = false
    var commit: (() -> Void)? = nil
    var text: Binding<String>

    init(_ placeholder: String, secure: Bool = false, commit: (() -> Void)? = nil, text: Binding<String>) {
        self.placeholder = placeholder
        self.secure = secure
        self.commit = commit
        self.text = text
    }

    func makeNSView(context: Context) -> NSTextField {
        let f = secure ? NSSecureTextField() : NSTextField()
        f.placeholderString = placeholder
        f.bezelStyle = .roundedBezel
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = text
        context.coordinator.commit = commit
        field.isEnabled = context.environment.isEnabled
        // 조합(마크) 중에는 값을 덮어쓰지 않는다 — 여기서 덮어쓰면 조합이 깨진다 (버그의 핵심)
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing && field.stringValue != text.wrappedValue {
            field.stringValue = text.wrappedValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var commit: (() -> Void)?
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let f = notification.object as? NSTextField else { return }
            // 뷰→바인딩은 항상 전달 (조합 중간 값도 상태로는 들어간다 — 뷰 재렌더가 필드를 건드리지 않으므로 안전)
            text.wrappedValue = f.stringValue
        }

        // 엔터 = 연결 버튼과 동일 동작 (조합 중 아니면 수동)
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }   // 조합 중 엔터는 IME 종료에 쓰도록 통과
                commit?()
                return true
            }
            return false
        }
    }
}

// 여러 줄 편집 (게스트 노트 등) — AppKit NSTextView 래핑, 한글 조합 안전
// mono: 고정폭 글꼴, fill: 부모 공간을 채우는 스크롤 뷰 (false면 고정 높이용)
struct IMETextArea: NSViewRepresentable {
    var text: Binding<String>
    var mono: Bool = false
    var fill: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(text: text) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .bezelBorder
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.font = mono
            ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        context.coordinator.text = text
        tv.isEditable = context.environment.isEnabled

tv.isSelectable = context.environment.isEnabled
        // 조합 중에는 값 덮어쓰기 금지
        if !tv.hasMarkedText() && tv.string != text.wrappedValue {
            tv.string = text.wrappedValue
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

// MARK: - 로그인
struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var savedProfiles: [PVEProfile] = []
    @State private var selectedProfileID = ""   // "" = 새 서버 입력
    @State private var host = UserDefaults.standard.string(forKey: "pve.host") ?? ""
    @State private var port = UserDefaults.standard.integer(forKey: "pve.port") == 0 ? 8006 : UserDefaults.standard.integer(forKey: "pve.port")
    @State private var user = UserDefaults.standard.string(forKey: "pve.user") ?? "root"
    @State private var realms: [String] = ["pam", "pve", "ldap", "openid"]
    @State private var realm = UserDefaults.standard.string(forKey: "pve.realm") ?? "pam"
    @State private var password = ""
    @State private var otp = ""
    @State private var savePassword = true
    @State private var loading = false

    var currentID: String { "\(host):\(port):\(user)@\(realm)" }

    /// 저장 프로필 선택 → 필드 자동 채움 (저장된 비밀번호 포함)
    func selectProfile(_ id: String) {
        guard !id.isEmpty, let p = ProfileStore.find(id: id) else { return }
        host = p.host; port = p.port; user = p.user; realm = p.realm
        savePassword = p.savePassword
        password = p.savePassword ? (KeychainStore.password(account: id) ?? "") : ""
    }

    /// 포트를 문자열로 편집하기 위한 바인딩
    var portBinding: Binding<String> {
        Binding(
            get: { String(port) },
            set: { port = Int($0) ?? 8006 }
        )
    }

    /// 로그인 실행 (버튼 클릭 또는 각 편집 필드에서 엔터)
    func doLogin() {
        guard !loading, !host.isEmpty, !password.isEmpty else { return }
        loading = true
        UserDefaults.standard.set(host, forKey: "pve.host")
        UserDefaults.standard.set(user, forKey: "pve.user")
        UserDefaults.standard.set(realm, forKey: "pve.realm")
        UserDefaults.standard.set(port, forKey: "pve.port")
        let pw = password
        Task {
            await app.login(host: host, port: port, user: user, realm: realm, password: pw, otp: otp)
            if app.loginError == nil {
                // 로그인 성공 시 프로필 저장 (비밀번호는 키체인에 개별 보관)
                let label = ProfileStore.find(id: currentID)?.label ?? host
                let p = PVEProfile(label: label, host: host, port: port, user: user, realm: realm, savePassword: savePassword)
                if savePassword { KeychainStore.setPassword(pw, account: p.id) }
                else { KeychainStore.deletePassword(account: p.id) }
                savedProfiles = ProfileStore.upsert(p)
                selectedProfileID = p.id
            }
            password = ""; otp = ""
            loading = false
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 38)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Bastion").font(.title.bold())
                    Text("Proxmox VE 클러스터 관리").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 30)

            Form {
                Picker("서버 프로필", selection: $selectedProfileID) {
                    Text("새 서버 입력").tag("")
                    ForEach(savedProfiles) { p in Text(p.label).tag(p.id) }
                }
                .onChange(of: selectedProfileID) { selectProfile($0) }

                IMEField("서버 주소 (IP/호스트)", commit: doLogin, text: $host)
                IMEField("포트", commit: doLogin, text: portBinding)
                IMEField("사용자 ID", commit: doLogin, text: $user)
                Picker("영역(Realm)", selection: $realm) {
                    ForEach(realms, id: \.self) { Text($0).tag($0) }
                }
                IMEField("비밀번호", secure: true, commit: doLogin, text: $password)
                IMEField("2FA OTP (선택)", commit: doLogin, text: $otp)
                Toggle("비밀번호 저장 (macOS 키체인)", isOn: $savePassword)
                if !savedProfiles.isEmpty && !host.isEmpty {
                    Button(role: .destructive) {
                        let id = currentID
                        savedProfiles = ProfileStore.remove(id: id)
                        KeychainStore.deletePassword(account: id)
                        if selectedProfileID == id { selectedProfileID = "" }
                    } label: {
                        Label("이 서버 프로필 삭제", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)

            Button {
                doLogin()
            } label: {
                if loading { ProgressView().controlSize(.small) } else { Text("연결") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(host.isEmpty || password.isEmpty || loading)

            if let err = app.loginError {
                Text(err).foregroundStyle(.red).font(.footnote).frame(width: 420)
            }
            Spacer()
        }
        .task {
            let probe = PVEClient()
            // 인증 없이 realm 목록 조회 가능
            if let r = try? await probe.realmList()["data"] as? [[String: Any]] {
                let names = r.compactMap { $0["realm"] as? String }
                if !names.isEmpty { realms = names }
            }
            savedProfiles = ProfileStore.load()
            let lastHost = UserDefaults.standard.string(forKey: "pve.host") ?? ""
            let lastUser = UserDefaults.standard.string(forKey: "pve.user") ?? ""
            let saved = ProfileStore.load()
            // 마지막 연결 프로필은 **키체인 접급 없이** 필드만 채운다
            // (실행마다 반복되는 키체인 권한 요청 방지 — 비밀번호 자동 첨입은 사용자가 프로필을 고를 때만)
            if let p = saved.first(where: { $0.host == lastHost && $0.user == lastUser }) {
                host = p.host
                port = p.port
                user = p.user
                realm = p.realm
                savePassword = p.savePassword
            }
        }
    }
}

// MARK: - 메인
struct MainView: View {
    @EnvironmentObject var app: AppState
    @State private var searchText = ""
    @State private var showCreateVM = false
    @State private var showCreateLXC = false

    var nodes: [ClusterResource] { app.resources.filter { $0.type == "node" } }
    var guests: [ClusterResource] {
        app.resources.filter { $0.isGuest && matches($0) }
    }

    func matches(_ r: ClusterResource) -> Bool {
        searchText.isEmpty || r.name.localizedCaseInsensitiveContains(searchText) ||
        String(r.vmid ?? 0).contains(searchText)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $app.selection) {
                Section("데이터센터(클러스터)") {
                    Label("개요", systemImage: "chart.pie").tag(NavSelection.overview)
                    Label("사용자/권한", systemImage: "person.2").tag(NavSelection.users)
                    Label("방화벽", systemImage: "shield.lefthalf.filled").tag(NavSelection.firewall)
                    Label("백업 잡", systemImage: "externaldrive.badge.timemachine").tag(NavSelection.backupJobs)
                    Label("태스크", systemImage: "clock.arrow.circlepath").tag(NavSelection.tasks)
                    Label("스토리지", systemImage: "externaldrive").tag(NavSelection.storage)
                    Label("API 탐색기", systemImage: "terminal.fill").tag(NavSelection.api)
                }
                Section("노드") {
                    ForEach(nodes) { n in
                        Label(n.name, systemImage: "desktopcomputer")
                            .tag(NavSelection.node(n.name))
                    }
                }
                Section("게스트") {
                    ForEach(guests) { g in
                        HStack {
                            Image(systemName: g.isVMKind ? "display" : "shippingbox")
                                .foregroundStyle(g.status == "running" ? Color.green : Color.gray)
                            Text("\(g.vmid ?? 0)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(g.name)
                        }
                        .tag(NavSelection.guest(node: g.node ?? "", type: g.type, vmid: g.vmid ?? 0, name: g.name))
                    }
                }
            }
            .searchable(text: $searchText, prompt: "게스트 검색")
            .navigationTitle(app.clusterName)
        } detail: {
            switch app.selection {
            case .overview: OverviewView()
            case .users: UsersView()
            case .firewall: FirewallView()
            case .backupJobs: BackupJobsView()
            case .node(let n): NodeDetail(node: n)
            case .guest(let node, let type, let vmid, let name): GuestDetail(node: node, type: type, vmid: vmid, name: name)
            case .storage: StorageListView()
            case .tasks: TasksView()
            case .api: ApiExplorerView()
            case nil: Text("항목을 선택하세요").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            Menu {
                Button { showCreateVM = true } label: { Label("VM 생성", systemImage: "display") }
                Button { showCreateLXC = true } label: { Label("컨테이너(CT) 생성", systemImage: "shippingbox") }
            } label: {
                Label("새 게스트", systemImage: "plus.circle")
            }
            .help("새 VM/컨테이너 생성 마법사")
            Button {
                app.refreshQuiet()
            } label: { Label("새로고침", systemImage: "arrow.clockwise") }
            Button {
                app.logout()
            } label: { Label("로그아웃", systemImage: "rectangle.portrait.and.arrow.right") }
        }
        .sheet(isPresented: $showCreateVM) { GuestCreateView(isVM: true) }
        .sheet(isPresented: $showCreateLXC) { GuestCreateView(isVM: false) }
        .overlay(alignment: .top) {
            if let e = app.lastError {
                Text(e).font(.footnote).padding(6).background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - 개요
struct OverviewView: View {
    @EnvironmentObject var app: AppState

    func tagList(_ s: String?) -> [String] {
        (s ?? "").split(separator: ";").map(String.init)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    nodesCards
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 10) {
                    ForEach(app.resources.filter { $0.isGuest }) { g in
                        HStack {
                            Image(systemName: g.isVMKind ? "display" : "shippingbox")
                                .foregroundStyle(g.status == "running" ? .green : .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(g.vmid ?? 0) · \(g.name)").font(.headline).lineLimit(1)
                                Text("\(g.node ?? "") · \(g.status) · 업타임 \(UptimeString(g.uptime ?? 0))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                // 태그 유무와 무관하게 높이 일정 유지 (빈 줄 예약)
                                HStack(spacing: 4) {
                                    ForEach(tagList(g.tags), id: \.self) { t in
                                        Text(t).font(.caption2).padding(2).background(.blue.opacity(0.1), in: Capsule())
                                    }
                                }
                                .frame(height: 16)
                            }
                            Spacer()
                            if (g.cpu ?? 0) > 0 {
                                MiniBar(value: (g.cpu ?? 0), color: .orange)
                            }
                        }
                        .padding(8)
                        .frame(minHeight: 84, alignment: .topLeading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("개요")
        .task { app.refreshQuiet() }
    }

    @ViewBuilder private var nodesCards: some View {
        ForEach(app.resources.filter { $0.type == "node" }) { (n: ClusterResource) in
            let cpuText = "상태: \(n.status) · CPU \(Int((n.cpu ?? 0) * 100))% / \(n.maxcpu ?? 0)코어"
            let memText = "메모리 \(ByteCount(n.mem ?? 0)) / \(ByteCount(n.maxmem ?? 0))"
            let upText = "업타임 \(UptimeString(n.uptime ?? 0))"
            VStack(alignment: .leading, spacing: 6) {
                Label(n.name, systemImage: "desktopcomputer").font(.headline)
                Text(cpuText).font(.caption)
                Text(memText).font(.caption)
                Text(upText).font(.caption)
                MiniBar(value: n.cpu ?? 0, color: .orange)
            }
            .padding(12)
            .frame(minWidth: 230, maxWidth: 230, minHeight: 118, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
    }
}
