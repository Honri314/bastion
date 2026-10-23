import SwiftUI
import ProxmoxKit

// MARK: - 사용자 목록 (enable 토글)
struct PVEUser: Codable, Identifiable {
    public let userid: String
    public let enable: Int?
    public let realm_type: String?
    public let comment: String?
    public let expire: Int?
    public var id: String { userid }
}

struct UsersView: View {
    @EnvironmentObject var app: AppState
    @State private var users: [PVEUser] = []
    @State private var note: String?
    @State private var busyID: String?
    @State private var showCreate = false
    @State private var editing: PVEUser?
    @State private var tab = 0
    private let titles = ["사용자", "API 토큰", "그룹"]

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(titles: titles, tab: $tab)
            Divider()
            switch tab {
            case 0: usersTab
            case 1: TokensView()
            case 2: GroupsView()
            default: EmptyView()
            }
        }
    }

    private var usersTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("사용자/권한").font(.headline)
                Text("\(users.count)명").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showCreate = true
                } label: { Label("사용자 추가", systemImage: "person.badge.plus") }
                .controlSize(.small)
                Button("새로고침") { Task { await load() } }
            }
            .padding(10)
            Divider()
            if let note {
                Text(note).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            List(users) { u in
                HStack(spacing: 10) {
                    Image(systemName: (u.enable ?? 1) == 0 ? "person.slash" : "person")
                        .foregroundStyle((u.enable ?? 1) == 0 ? .red : .green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.userid).font(.body.monospaced())
                        Text("\(u.realm_type ?? "realm") · \(u.comment ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { (u.enable ?? 1) != 0 },
                        set: { on in Task { await setEnable(u, on: on) } }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(busyID == u.userid)
                    Button("편집") { editing = u }.controlSize(.small).buttonStyle(.link)
                    Button("삭제", role: .destructive) {
                        Task { await deleteUser(u) }
                    }.controlSize(.small).buttonStyle(.link)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            CreateUserSheet()
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { u in
            UserEditSheet(user: u)
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/access/users?full=1")
            guard let arr = raw as? [[String: Any]] else {
                note = "사용자 응답이 배열이 아님: \(String("\"\(raw)\"".prefix(120)))"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            users = try JSONDecoder().decode([PVEUser].self, from: json)
            note = nil
        } catch {
            note = "사용자 목록 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func setEnable(_ u: PVEUser, on: Bool) async {
        guard let c = app.client else { return }
        busyID = u.userid
        defer { busyID = nil }
        do {
            _ = try await c.putJSON("/api2/json/access/users/\(c.percentEncode(u.userid))",
                                    form: ["enable": on ? "1" : "0"])
            await load()
        } catch {
            note = "활성화 변경 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func deleteUser(_ u: PVEUser) async {
        guard let c = app.client else { return }
        busyID = u.userid
        defer { busyID = nil }
        do {
            _ = try await c.deleteJSON("/api2/json/access/users/\(c.percentEncode(u.userid))")
            note = "사용자 '\(u.userid)' 삭제 완료"
            await load()
        } catch {
            note = "삭제 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}

// MARK: - 클러스터 방화벽 (정책·규칙 CRUD + 보안 그룹 + IP셋)
struct FirewallView: View {
    @EnvironmentObject var app: AppState
    @State private var rules: [FirewallRule] = []
    @State private var inputPolicy = ""
    @State private var outputPolicy = ""
    @State private var enabled = false
    @State private var note: String?
    @State private var ruleSheet: FirewallRule?
    @State private var showAddRule = false
    @State private var tab = 0
    private let titles = ["규칙", "보안 그룹", "IP셋"]

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(titles: titles, tab: $tab)
            Divider()
            switch tab {
            case 0: rulesOptionsTab
            case 1: SecurityGroupsView()
            case 2: IpSetsView()
            default: EmptyView()
            }
        }
    }

    private var rulesOptionsTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("방화벽 (데이터센터)").font(.headline)
                Spacer()
                Button("새로고침") { Task { await load() } }
            }
            .padding(10)
            Divider()
            HStack(spacing: 14) {
                Toggle("전체 활성", isOn: Binding(
                    get: { enabled },
                    set: { on in Task { await setOptionEnable(on) } }))
                .toggleStyle(.switch).controlSize(.small)
                Text("INPUT 정책: \(inputPolicy.isEmpty ? "-" : inputPolicy)")
                Text("OUTPUT 정책: \(outputPolicy.isEmpty ? "-" : outputPolicy)")
                Spacer()
            }
            .font(.caption).padding(8)
            Divider()
            HStack {
                Text("규칙 \(rules.count)건")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let note {
                    Text(note).font(.footnote).foregroundStyle(.red).lineLimit(2)
                }
                Button {
                    showAddRule = true
                } label: { Label("규칙 추가", systemImage: "plus") }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            Divider()
            List(rules) { r in
                HStack(spacing: 8) {
                    Circle().fill(r.action == "ACCEPT" ? .green : (r.action == "DROP" ? .red : .orange))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ruleSummary(r)).font(.caption.monospaced())
                        Text(r.comment ?? (r.proto ?? "-") + "/" + (r.dport ?? ""))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if (r.enable ?? 1) == 0 {
                        Text("비활성").font(.caption2).foregroundStyle(.orange)
                    }
                    Button("편집") { ruleSheet = r }.controlSize(.small)
                }
            }
        }
        .task { await load() }
        .sheet(item: $ruleSheet, onDismiss: { Task { await load() } }) { r in
            FirewallRuleSheet(nodeRule: r)
        }
        .sheet(isPresented: $showAddRule, onDismiss: { Task { await load() } }) {
            FirewallRuleSheet(nodeRule: nil)
        }
    }

    private func ruleSummary(_ r: FirewallRule) -> String {
        let src = (r.source ?? "*").isEmpty ? "*" : r.source!
        let dst = (r.dest ?? "*").isEmpty ? "*" : r.dest!
        let pr = (r.proto ?? "-")
        let dp = (r.dport ?? "").isEmpty ? "" : ":\(r.dport!)"
        return "#\(r.pos ?? -1) \((r.direction ?? "in").uppercased()) \(r.action ?? "-") · \(src) → \(dst)\(pr == "-" ? "" : " \(pr)\(dp)")"
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            if let opts = try await c.getJSON("/api2/json/cluster/firewall/options") as? [String: Any] {
                inputPolicy = opts["policy_in"] as? String ?? ""
                outputPolicy = opts["policy_out"] as? String ?? ""
                enabled = (opts["enable"] as? Int ?? 0) == 1
            }
            if let arr = try await c.getJSON("/api2/json/cluster/firewall/rules") as? [[String: Any]],
               let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
                rules = (try? JSONDecoder().decode([FirewallRule].self, from: json)) ?? []
            }
            note = nil
        } catch {
            note = "방화벽 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func setOptionEnable(_ on: Bool) async {
        guard let c = app.client else { return }
        do {
            _ = try await c.putJSON("/api2/json/cluster/firewall/options",
                                    form: ["enable": on ? "1" : "0"])
            enabled = on
            note = nil
        } catch {
            note = "옵션 변경 실패: \((error as? PVEError)?.message ?? "\(error)")"
            await load()
        }
    }
}

// MARK: - 백업 잡 (스케줄)
struct BackupJob: Codable, Identifiable {
    public let id: String
    public let schedule: String?
    public let storage: String?
    public let enabled: Int?
    public let comment: String?
    public let all: Int?
    public let mode: String?
}

struct BackupJobsView: View {
    @EnvironmentObject var app: AppState
    @State private var jobs: [BackupJob] = []
    @State private var note: String?
    @State private var busyID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("백업 잡 (스케줄)").font(.headline)
                Spacer()
                Button("새로고침") { Task { await load() } }
            }
            .padding(10)
            Divider()
            if let note {
                Text(note).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            List(jobs) { j in
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle((j.enabled ?? 0) == 1 ? .green : .gray)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(j.id) → \(j.storage ?? "?") · 스케줄 \(j.schedule ?? "-")")
                            .font(.body.monospaced())
                        Text("모드 \(j.mode ?? "-") · 전체: \((j.all ?? 0) == 1 ? "모든 게스트" : "선택") · \(j.comment ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { (j.enabled ?? 0) == 1 },
                        set: { on in Task { await setEnabled(j, on: on) } }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(busyID == j.id)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/cluster/backup")
            guard let arr = raw as? [[String: Any]] else {
                note = "백업 잡 응답이 배열이 아님: \(String("\"\(raw)\"".prefix(120)))"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            jobs = try JSONDecoder().decode([BackupJob].self, from: json)
            note = nil
        } catch {
            note = "백업 잡 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func setEnabled(_ j: BackupJob, on: Bool) async {
        guard let c = app.client else { return }
        busyID = j.id
        defer { busyID = nil }
        do {
            _ = try await c.putJSON("/api2/json/cluster/backup/\(c.percentEncode(j.id))",
                                    form: ["enabled": on ? "1" : "0"])
            await load()
        } catch {
            note = "백업 잡 변경 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}


// MARK: - 사용자 생성
struct CreateUserSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var userid = ""       // "user@pam" 형태
    @State private var password = ""
    @State private var comment = ""
    @State private var createDisabled = false
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 14) {
            Text("사용자 추가").font(.headline)
            Form {
                IMEField("사용자 ID (예: dev@pam)", text: $userid)
                IMEField("비밀번호 (pam/pve는 필요)", secure: true, text: $password)
                IMEField("설명 (선택)", text: $comment)
                Toggle("비활성 상태로 생성", isOn: $createDisabled)
            }
            .formStyle(.grouped)
            .frame(width: 420, height: 190)
            HStack {
                Button("취소") { dismiss() }
                Button {
                    Task { await create() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("추가") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(userid.isEmpty || busy)
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(notice.contains("완료") ? .green : .red)
                    .frame(width: 400).lineLimit(3)
            }
        }
        .padding(20)
    }

    private func create() async {
        guard let c = app.client else { return }
        busy = true
        defer { busy = false }
        var form = ["userid": userid, "enable": createDisabled ? "0" : "1"]
        if !password.isEmpty { form["password"] = password }
        if !comment.isEmpty { form["comment"] = comment }
        do {
            _ = try await c.postJSON("/api2/json/access/users", form: form)
            notice = "추가 완료"
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}
