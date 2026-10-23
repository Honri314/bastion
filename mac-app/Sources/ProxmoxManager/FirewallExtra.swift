import SwiftUI
import ProxmoxKit

// MARK: - 방화벽 보안 그룹 (Security Groups)
// GET/POST /cluster/firewall/groups · GET/PUT/DELETE /cluster/firewall/groups/{group}
struct SecurityGroup: Codable, Identifiable {
    public let group: String
    public let comment: String?
    public var id: String { group }
}

struct SecurityGroupsView: View {
    @EnvironmentObject var app: AppState
    @State private var groups: [SecurityGroup] = []
    @State private var notice: String?
    @State private var showAddGroup = false
    @State private var groupRules: [String: [FirewallRule]] = [:]
    @State private var editingRule: FirewallRule?
    @State private var showRuleEditor = false
    @State private var showAddRule = false
    @State private var ruleGroup = ""   // 현재 시트가 대상으로 삼는 그룹

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("보안 그룹").font(.headline)
                Spacer()
                Button("새로고침") { Task { await load() } }
                Button { showAddGroup = true } label: { Label("그룹 추가", systemImage: "plus") }.controlSize(.small)
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            List {
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "shield.lefthalf.filled.badge.checkmark").foregroundStyle(.blue)
                            Text(g.group).font(.body.monospaced()).bold()
                            Text(g.comment ?? "").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("규칙 추가") {
                                ruleGroup = g.group; showAddRule = true
                            }.controlSize(.small).buttonStyle(.link)
                            Button("삭제", role: .destructive) {
                                Task { await removeGroup(g) }
                            }.controlSize(.small).buttonStyle(.link)
                        }
                        DisclosureGroup("규칙 보기") {
                            GroupRulesInline(group: g.group,
                                             rules: groupRules[g.group] ?? [],
                                             onEdit: { r in ruleGroup = g.group; editingRule = r; showRuleEditor = true },
                                             onDelete: { r in Task { await removeGroupRule(g.group, r) } })
                        }
                        .onChange(of: groupRules[g.group]?.count) { _ in }   // 인라인 갱신 트리거
                    }
                    // 펼쳤을 때 규칙 로드
                    .background(GroupRulesLoader(group: g.group) {
                        Task { await loadGroupRules(g.group) }
                    })
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAddGroup, onDismiss: { Task { await load() } }) {
            SecurityGroupAddSheet()
        }
        .sheet(isPresented: $showRuleEditor, onDismiss: { Task { await loadGroupRules(ruleGroup) } }) {
            BackendRuleEditor
        }
        .sheet(isPresented: $showAddRule, onDismiss: { Task { await loadGroupRules(ruleGroup) } }) {
            FirewallRuleSheet(nodeRule: nil,
                              apiBase: "/api2/json/cluster/firewall/groups/\(ruleGroup)/rules")
        }
    }

    /// 편집 시트 내용 (아이템을 상태에서 직접 꺼냄 — isPresented 시트라 본문은 무인자)
    @ViewBuilder private var BackendRuleEditor: some View {
        if let r = editingRule {
            FirewallRuleSheet(nodeRule: r,
                              apiBase: "/api2/json/cluster/firewall/groups/\(ruleGroup)/rules")
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/cluster/firewall/groups")
            guard let arr = raw as? [[String: Any]] else {
                notice = "보안 그룹 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            groups = (try? JSONDecoder().decode([SecurityGroup].self, from: json)) ?? []
            notice = nil
        } catch {
            notice = "보안 그룹 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func loadGroupRules(_ g: String) async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/cluster/firewall/groups/\(c.percentEncode(g))")
            guard let arr = raw as? [[String: Any]] else { return }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            let list = (try? JSONDecoder().decode([FirewallRule].self, from: json)) ?? []
            groupRules[g] = list
        } catch {
            notice = "그룹 규칙 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func removeGroup(_ g: SecurityGroup) async {
        guard let c = app.client else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/cluster/firewall/groups/\(c.percentEncode(g.group))")
            notice = "그룹 '\(g.group)' 삭제 완료"
            await load()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }

    private func removeGroupRule(_ g: String, _ r: FirewallRule) async {
        guard let c = app.client, let p = r.pos else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/cluster/firewall/groups/\(c.percentEncode(g))/rules/\(p)")
            await loadGroupRules(g)
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

struct SecurityGroupAddSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var comment = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("보안 그룹 추가").font(.headline)
            Form {
                IMEField("그룹 이름 (예: web-servers)", text: $name)
                IMEField("설명", text: $comment)
            }
            .formStyle(.grouped).frame(width: 380, height: 130)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 360).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("추가") }
                }
                .buttonStyle(.borderedProminent).disabled(name.isEmpty || busy)
            }
        }
        .padding(20)
    }

    private func add() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        var f: [String: String] = ["group": name]
        if !comment.isEmpty { f["comment"] = comment }
        do {
            _ = try await c.postJSON("/api2/json/cluster/firewall/groups", form: f)
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// DisclosureGroup 펼침 시 규칙 로드 트리거 (간단 구현: 배경 뷰는 로드만 담당 — 규칙은 '규칙 보기' 클릭 시 반영)
struct GroupRulesLoader: View {
    let group: String
    let onLoad: () -> Void
    var body: some View { Color.clear.frame(width: 0, height: 0).task(id: group) { onLoad() } }
}

struct GroupRulesInline: View {
    let group: String
    let rules: [FirewallRule]
    let onEdit: (FirewallRule) -> Void
    let onDelete: (FirewallRule) -> Void

    var body: some View {
        ForEach(rules) { r in
            HStack {
                Circle().fill(r.action == "ACCEPT" ? .green : (r.action == "DROP" ? .red : .orange))
                    .frame(width: 7, height: 7)
                Text("#\(r.pos ?? -1) \((r.direction ?? "in").uppercased()) \(r.action ?? "-")")
                    .font(.caption.monospaced())
                if let pr = r.proto, !pr.isEmpty { Text(pr).font(.caption2) }
                if let dp = r.dport, !dp.isEmpty { Text(":\(dp)").font(.caption2.monospaced()) }
                if let src = r.source, !src.isEmpty { Text("src \(src)").font(.caption2) }
                Spacer()
                Button("편집") { onEdit(r) }.controlSize(.small).buttonStyle(.link)
                Button("삭제", role: .destructive) { onDelete(r) }.controlSize(.small).buttonStyle(.link)
            }
        }
        if rules.isEmpty {
            Text("규칙 없음").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - IP셋 (IP 리스트)
struct IpSet: Codable, Identifiable {
    public let name: String
    public let comment: String?
    public var id: String { name }
}

struct IpSetEntry: Codable, Identifiable {
    public let cidr: String
    public let comment: String?
    public var id: String { cidr }
}

struct IpSetsView: View {
    @EnvironmentObject var app: AppState
    @State private var sets: [IpSet] = []
    @State private var notice: String?
    @State private var showAddSet = false
    @State private var selectedSet: String?
    @State private var entries: [IpSetEntry] = []
    @State private var showAddEntry = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("IP셋").font(.headline)
                    Spacer()
                    Button { showAddSet = true } label: { Label("셋 추가", systemImage: "plus") }.controlSize(.small)
                }
                .padding(8)
                Divider()
                List(sets, selection: Binding(
                    get: { selectedSet },
                    set: { v in selectedSet = v; Task { await loadEntries() } })) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.body.monospaced())
                        Text(s.comment ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 300)

            VStack(spacing: 0) {
                HStack {
                    Text("엔트리 — \(selectedSet ?? "셋을 선택하세요")").font(.headline)
                    Spacer()
                    Button { showAddEntry = true } label: { Label("엔트리 추가", systemImage: "plus") }
                        .controlSize(.small).disabled(selectedSet == nil)
                    Button("셋 삭제", role: .destructive) {
                        Task { await removeSet() }
                    }.controlSize(.small).disabled(selectedSet == nil)
                }
                .padding(8)
                Divider()
                if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(6) }
                Table(entries) {
                    TableColumn("CIDR") { e in Text(e.cidr).monospaced() }
                    TableColumn("주석") { e in Text(e.comment ?? "") }
                    TableColumn("") { e in
                        Button("삭제", role: .destructive) {
                            Task { await removeEntry(e) }
                        }.controlSize(.small).buttonStyle(.link)
                    }
                }
            }
            .frame(minWidth: 380)
        }
        .task { await load() }
        .sheet(isPresented: $showAddSet, onDismiss: { Task { await load() } }) {
            IpSetAddSheet()
        }
        .sheet(isPresented: $showAddEntry, onDismiss: { Task { await loadEntries() } }) {
            IpSetEntryAddSheet(name: selectedSet ?? "")
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/cluster/firewall/ipset")
            guard let arr = raw as? [[String: Any]] else {
                notice = "IP셋 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            sets = ((try? JSONDecoder().decode([IpSet].self, from: json))) ?? []
            notice = nil
        } catch {
            notice = "IP셋 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func loadEntries() async {
        guard let c = app.client, let n = selectedSet else { return }
        do {
            let raw = try await c.getJSON("/api2/json/cluster/firewall/ipset/\(c.percentEncode(n))")
            guard let arr = raw as? [[String: Any]] else { return }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            entries = ((try? JSONDecoder().decode([IpSetEntry].self, from: json))) ?? []
            notice = nil
        } catch {
            notice = "엔트리 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func removeSet() async {
        guard let c = app.client, let n = selectedSet else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/cluster/firewall/ipset/\(c.percentEncode(n))")
            notice = "IP셋 '\(n)' 삭제 완료"
            selectedSet = nil
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }

    private func removeEntry(_ e: IpSetEntry) async {
        guard let c = app.client, let n = selectedSet else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/cluster/firewall/ipset/\(c.percentEncode(n))/\(c.percentEncode(e.cidr))")
            await loadEntries()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

struct IpSetAddSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var comment = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("IP셋 추가").font(.headline)
            Form {
                IMEField("이름 (예: admins)", text: $name)
                IMEField("설명", text: $comment)
            }
            .formStyle(.grouped).frame(width: 380, height: 130)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 360).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("추가") }
                }
                .buttonStyle(.borderedProminent).disabled(name.isEmpty || busy)
            }
        }
        .padding(20)
    }

    private func add() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        var f: [String: String] = ["name": name]
        if !comment.isEmpty { f["comment"] = comment }
        do {
            _ = try await c.postJSON("/api2/json/cluster/firewall/ipset", form: f)
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

struct IpSetEntryAddSheet: View {
    let name: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var cidr = ""
    @State private var comment = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("엔트리 추가 — \(name)").font(.headline)
            Form {
                IMEField("IP/CIDR (예: 10.0.0.5 또는 10.0.0.0/24 또는 +myipset)", text: $cidr)
                IMEField("주석", text: $comment)
            }
            .formStyle(.grouped).frame(width: 400, height: 130)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 380).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("추가") }
                }
                .buttonStyle(.borderedProminent).disabled(cidr.isEmpty || busy)
            }
        }
        .padding(20)
    }

    private func add() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        var f: [String: String] = ["cidr": cidr]
        if !comment.isEmpty { f["comment"] = comment }
        do {
            _ = try await c.postJSON("/api2/json/cluster/firewall/ipset/\(c.percentEncode(name))", form: f)
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// FirewallRule에 그룹 태그 부여 (in-memory 전송용; 인코딩은 건드리지 않음)
