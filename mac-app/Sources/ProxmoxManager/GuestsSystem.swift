import SwiftUI
import ProxmoxKit

// MARK: - Cloud-Init (QEMU 게스트 전용)
struct GuestCloudInitView: View {
    let node: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @State private var cfg: [String: Any] = [:]
    @State private var ciuser = ""
    @State private var cipassword = ""
    @State private var sshkeys = ""
    @State private var searchdomain = ""
    @State private var nameserver = ""
    @State private var ipconfig0 = ""
    @State private var ipconfig1 = ""
    @State private var ciupgrade = false
    @State private var notice: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cloud-Init").font(.headline)
                Spacer()
                Button {
                    Task { await regenerate() }
                } label: {
                    Label("이미지 재생성", systemImage: "arrow.clockwise.circle")
                }.controlSize(.small)
                Button {
                    Task { await save() }
                } label: { Label("저장", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(loading)
            }
            Form {
                IMEField("사용자 (ciuser)", text: $ciuser)
                IMEField("암호 (cipassword — 이미 설정 시 빈칸 유지)", secure: true, text: $cipassword)
                IMEField("SSH 공개 키 (sshkeys — 줄바꿈으로 여러 개)", text: $sshkeys)
                    .textFieldStyle(.roundedBorder).lineLimit(3)
                HStack {
                IMEField("DNS 검색 도메인 (searchdomain)", text: $searchdomain)
                IMEField("DNS 서버 (nameserver)", text: $nameserver)
                }
                HStack {
                IMEField("ipconfig0 (예: ip=dhcp 또는 ip=10.0.0.5/24,gw=10.0.0.1)", text: $ipconfig0)
                }
                IMEField("ipconfig1 (''이면 삭제)", text: $ipconfig1)
                Toggle("패키지 자동 업그레이드 (ciupgrade)", isOn: $ciupgrade)
                Section("현재 cloudinit 드라이브") {
                    ForEach(["ide0", "scsi0", "virtio0", "sata0"].sorted(), id: \.self) { key in
                        if let v = cfg[key] as? String, v.contains("cloudinit") {
                            Text("\(key): \(v)").font(.caption.monospaced())
                        }
                    }
                    Text("Cloud-Init 드라이브가 없으면 하드웨어 탭에서 cloudinit 디스크를 먼저 추가하세요.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 620)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding(14)
        .task { await load() }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        if let d = try? await c.getJSON("/api2/json/nodes/\(node)/qemu/\(vmid)/config") as? [String: Any] {
            cfg = d
            ciuser = d["ciuser"] as? String ?? ""
            sshkeys = d["sshkeys"] as? String ?? ""
            searchdomain = d["searchdomain"] as? String ?? ""
            nameserver = d["nameserver"] as? String ?? ""
            ipconfig0 = d["ipconfig0"] as? String ?? ""
            ipconfig1 = d["ipconfig1"] as? String ?? ""
            ciupgrade = (d["ciupgrade"] as? Int) == 1
            loading = false
        }
    }

    private func save() async {
        guard let c = app.client else { return }
        var f: [String: String] = ["ciuser": ciuser,
                                   "sshkeys": sshkeys,
                                   "searchdomain": searchdomain,
                                   "nameserver": nameserver,
                                   "ipconfig0": ipconfig0,
                                   "ipconfig1": ipconfig1,
                                   "ciupgrade": ciupgrade ? "1" : "0"]
        if !cipassword.isEmpty { f["cipassword"] = cipassword }
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/qemu/\(vmid)/config", form: f)
            notice = "Cloud-Init 설정 저장 완료"
            cipassword = ""
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }

    private func regenerate() async {
        guard let c = app.client else { return }
        do {
            // 8.x: PUT /cloudinit 으로 드라이브 재생성
            _ = try await c.putJSON("/api2/json/nodes/\(node)/qemu/\(vmid)/cloudinit", form: [:])
            notice = "Cloud-Init 이미지 재생성 요청 완료"
        } catch {
            notice = "재생성 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}

// MARK: - 게스트 옵션 (config CRUD)
struct GuestOpts: Identifiable {
    let key: String
    var value: String
    var editable: Bool = true
    var id: String { key }
}

struct GuestOptionsView: View {
    let node: String
    let type: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @State private var opts: [GuestOpts] = []
    @State private var template = false
    @State private var notice: String?
    @State private var loading = true
    @State private var editTarget: GuestOpts?
    @State private var noteText = ""
    @State private var tagsText = ""

    private func makeOpts(_ raw: [String: Any]) -> [GuestOpts] {
        let interesting = ["onboot", "boot", "bootdisk", "protection", "template", "agent", "ostype", "name", "tablet", "kbd", "keyboard", "vga", "serial", "startall", "startup", "shares", "cores", "memory", "swap", "cpulimit", "cpuunits", "lock", "vmgenid"]
        var out: [GuestOpts] = []
        for k in interesting {
            if let v = raw[k] {
                out.append(GuestOpts(key: k, value: "\(v)"))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("옵션").font(.headline)
                if template { Text("템플릿").font(.caption).padding(2).background(.purple.opacity(0.15), in: Capsule()) }
                Spacer()
                if let lock = opts.first(where: { $0.key == "lock" }), !lock.value.isEmpty {
                    Text("잠금: \(lock.value)").font(.caption).foregroundStyle(.red)
                }
            }
            .padding(10)
            // 노트·태그 빠른 편집 (VM/CT 공통: PUT config description/tags)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("노트 (description)").font(.caption2).foregroundStyle(.secondary)
                IMETextArea(text: $noteText)
                        .frame(height: 50)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("태그 (쉼표 구분)").font(.caption2).foregroundStyle(.secondary)
                IMEField("예: prod, web", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    Task { await saveNoteTags() }
                } label: { Label("저장", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            List(opts) { opt in
                HStack {
                    Text(opt.key).font(.system(.body, design: .monospaced)).bold().frame(minWidth: 100, alignment: .leading)
                    Text(opt.value.isEmpty ? "—" : opt.value).font(.body.monospaced()).foregroundStyle(opt.value.isEmpty ? .tertiary : .primary)
                    Spacer()
                    if opt.editable {
                        Button("편집") { editTarget = opt }.controlSize(.small).buttonStyle(.link)
                    }
                }
            }
        }
        .task { await loadConfig() }
        .sheet(item: $editTarget, onDismiss: { Task { await loadConfig() } }) { t in
            GuestOptEditSheet(node: node, type: type, vmid: vmid, key: t.key, current: t.value)
        }
        .pveNotice($notice)
    }

    private func saveNoteTags() async {
        guard let c = app.client else { return }
        var f: [String: String] = ["description": noteText, "tags": tagsText]
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/config", form: f)
            notice = "노트/태그 저장 완료"
            await loadConfig()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }

    private func loadConfig() async {
        guard let c = app.client else { return }
        if let d = try? await c.getJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/config") as? [String: Any] {
            opts = makeOpts(d)
            template = (d["template"] as? Int) == 1
            if noteText.isEmpty { noteText = d["description"] as? String ?? "" }
            if tagsText.isEmpty { tagsText = d["tags"] as? String ?? "" }
            loading = false
        }
    }
}

struct GuestOptEditSheet: View {
    let node: String, type: String, vmid: Int
    let key: String
    let current: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("옵션 편집 — \(key)").font(.headline)
            Form {
                IMEField("값 (PID ''또는 원본 숫자/bool)", text: $value)
                Text("onboot/protection 등 bool은 0 또는 1, agent는 0/1 또는 1,fstrim_cloned_disks=1 처럼 쉼표 목록")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .formStyle(.grouped).frame(width: 420, height: 150)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 400).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("저장") }
                }
                .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .padding(20)
        .onAppear { value = current }
    }

    private func save() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/config", form: [key: value])
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 모니터 (QEMU 모니터)
struct GuestMonitorView: View {
    let node: String
    let type: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @State private var cmd = ""
    @State private var log = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("게스트 모니터 (QEMU hmp)").font(.headline)
                Spacer()
                Button("지우기") { log = "" }
            }
            .padding(10)
            Divider()
            ScrollView {
                ScrollViewReader { proxy in
                    Text(log.isEmpty ? "info status / info block 등 QEMU 명령을 아래에서 입력하세요" : log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                        .onChange(of: log) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                IMEField("QEMU 명령 (예: info status)", text: $cmd)
                    .onSubmit { Task { await run() } }
                Button("실행") {
                    Task { await run() }
                }
                .disabled(cmd.isEmpty || busy)
            }
            .padding(10)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
        }
    }

    private func run() async {
        guard let c = app.client, !cmd.isEmpty else { return }
        busy = true; defer { busy = false }
        let line = "> \(cmd)"
        log += (log.isEmpty ? "" : "\n") + line + "\n"
        do {
            if let out = try await c.postJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/monitor", form: ["command": cmd]) as? String {
                log += out + "\n"
            }
            cmd = ""
        } catch {
            log += "오류: \((error as? PVEError)?.message ?? "\(error)")\n"
        }
    }
}

// MARK: - 권한 (Access Control List)
struct ClientACL: Codable, Identifiable {
    public let path: String
    public let propagate: Int?
    public let ugid: String?
    public let roleid: String?
    public var id: String { "\(path)|\(ugid ?? "")|\(roleid ?? "")" }
}

struct GuestPermissionsView: View {
    let node: String
    let type: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @State private var acls: [ClientACL] = []
    @State private var notice: String?
    @State private var showGrant = false
    /// 대상 VM 경로: /vms/{vmid} (컨테이너는 LXC도 /vms 사용)
    private var vmPath: String { "/vms/\(vmid)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("권한 (구경 경로 \(vmPath))").font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: { Label("새로고침", systemImage: "arrow.clockwise") }.controlSize(.small)
                Button { showGrant = true } label: { Label("부여/수정", systemImage: "plus") }.controlSize(.small)
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            Table(acls) {
                TableColumn("경로") { a in Text(a.path).monospaced() }
                TableColumn("사용자/그룹") { a in Text(a.ugid ?? "?") }
                TableColumn("역할") { a in Text(a.roleid ?? "?") }
                TableColumn("전파") { a in Text((a.propagate ?? 0) == 1 ? "예" : "아니오") }
                TableColumn("") { a in
                    Button("삭제", role: .destructive) { Task { await remove(a) } }
                        .controlSize(.small).buttonStyle(.link).disabled(a.path != vmPath)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showGrant, onDismiss: { Task { await load() } }) {
            ACLGrantSheet(path: vmPath)
        }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/access/acl")
            guard let arr = raw as? [[String: Any]] else { return }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            acls = ((try? JSONDecoder().decode([ClientACL].self, from: json))) ?? []
            notice = nil
        } catch { notice = "ACL 조회 실패: \((error as? PVEError)?.message ?? "\(error)")" }
    }

    private func remove(_ a: ClientACL) async {
        guard let c = app.client else { return }
        let ugid = a.ugid ?? ""
        var f: [String: String] = ["delete": "1", "path": a.path, "roles": a.roleid ?? ""]
        if ugid.hasPrefix("@") { f["groups"] = String(ugid.dropFirst()) } else { f["users"] = ugid }
        do {
            _ = try await c.putJSON("/api2/json/access/acl", form: f)
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - ACL 부여 시트 (사용자/그룹 + 역할)
struct ACLGrantSheet: View {
    let path: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [(id: String, name: String)] = []  // 사용자+그룹 목록
    @State private var target = ""
    @State private var role = "PVEVMUser"
    @State private var propagate = true
    @State private var notice: String?
    @State private var busy = false

    static let roles = ["PVEVMAdmin", "PVEVMUser", "PVETokenUser", "PVEAdmin", "PVEAuditor", "Administrator", "Operator"]

    var body: some View {
        VStack(spacing: 12) {
            Text("권한 부여 — \(path)").font(.headline)
            Form {
                Picker("대상", selection: $target) {
                    Text("-").tag("")
                    ForEach(targets, id: \.0) { t in Text(t.name).tag(t.id) }
                }
                Picker("역할", selection: $role) {
                    ForEach(Self.roles, id: \.self) { Text($0) }
                }
                Toggle("하위 경로에 전파 (propagate)", isOn: $propagate)
            }
            .formStyle(.grouped).frame(width: 400, height: 170)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 380).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await grant() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("부여") }
                }
                .buttonStyle(.borderedProminent).disabled(target.isEmpty || busy)
            }
        }
        .padding(20)
        .task { await loadTargets() }
    }

    private func loadTargets() async {
        guard let c = app.client else { return }
        var list: [(String, String)] = []
        if let users = try? await c.getJSON("/api2/json/access/users?full=1") as? [[String: Any]] {
            for u in users {
                if let uid = u["userid"] as? String, !uid.isEmpty {
                    list.append((uid, uid))
                }
            }
        }
        if let groups = try? await c.getJSON("/api2/json/access/groups") as? [[String: Any]] {
            for g in groups {
                if let gid = g["groupid"] as? String, !gid.isEmpty {
                    list.append(("@\(gid)", "@\(gid)"))
                }
            }
        }
        targets = list
    }

    private func grant() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        var f: [String: String] = ["path": path, "roles": role,
                                   "propagate": propagate ? "1" : "0"]
        if target.hasPrefix("@") { f["groups"] = String(target.dropFirst()) } else { f["users"] = target }
        do {
            _ = try await c.putJSON("/api2/json/access/acl", form: f)
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 복제 (Replication)
struct ReplicationJob: Codable, Identifiable {
    public let id: String
    public let guest: Int?
    public let target: String?
    public let schedule: String?
    public let disable: Int?
}

struct GuestReplicationView: View {
    let node: String
    let type: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @State private var jobs: [ReplicationJob] = []
    @State private var notice: String?
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("복제 (Replication)").font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: { Label("새로고침", systemImage: "arrow.clockwise") }.controlSize(.small)
                Button { showAdd = true } label: { Label("작업 추가", systemImage: "plus") }.controlSize(.small)
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            List(jobs) { j in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(j.id).bold().monospaced()
                        Text("guest \(j.guest ?? vmid) → \(j.target ?? "?") · 스킴 \(j.schedule ?? "-")\(j.disable == 1 ? " · 비활성" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // 클러스터 작업이라 삭제만 로컬 제공
                    Button("삭제", role: .destructive) { Task { await remove(j) } }
                        .controlSize(.small).buttonStyle(.link)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
            ReplicationAddSheet(node: node, vmid: vmid)
        }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let arr = try await c.getJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/replication") ?? []
            guard let list = arr as? [[String: Any]] else { return }
            let json = try JSONSerialization.data(withJSONObject: list, options: [.fragmentsAllowed])
            jobs = ((try? JSONDecoder().decode([ReplicationJob].self, from: json))) ?? []
            notice = nil
        } catch {
            // 501은 스탠드얼론 노드에서 replication이 꺼졌음을 의미
            notice = "복제 조회 실패 (스탠드얼론 노드면 클러스터 기능이 필요합니다): \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func remove(_ j: ReplicationJob) async {
        guard let c = app.client else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/replication/\(j.id)")
            notice = "복제 작업 삭제 완료"
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

struct ReplicationAddSheet: View {
    let node: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var schedule = "*/15"
    @State private var notice: String?
    @State private var busy = false
    @State private var nodes: [String] = []

    var body: some View {
        VStack(spacing: 12) {
            Text("복제 작업 추가").font(.headline)
            Form {
                Picker("대상 노드", selection: $target) {
                    Text("-").tag("")
                    ForEach(nodes, id: \.self) { Text($0).tag($0) }
                }
                IMEField("스케줄 (예: */15, 매15분)", text: $schedule)
            }
            .formStyle(.grouped).frame(width: 380, height: 140)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 360).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("추가") }
                }
                .buttonStyle(.borderedProminent).disabled(target.isEmpty || busy)
            }
        }
        .padding(20)
        .task {
            if let c = app.client, let ns = try? await c.getJSON("/api2/json/nodes") as? [[String: Any]] {
                nodes = ns.compactMap { $0["node"] as? String }
            }
        }
    }

    private func add() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        let id = "\(vmid)-\(target)"
        do {
            _ = try await c.postJSON("/api2/json/cluster/replication", form:
                ["id": id, "type": "local", "target": target, "guest": "\(vmid)", "schedule": schedule])
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}
