import SwiftUI
import ProxmoxKit

// MARK: - 공용: 결과 알림 모디파이어
extension View {
    func pveNotice(_ text: Binding<String?>) -> some View {
        alert("결과", isPresented: Binding(
            get: { text.wrappedValue != nil },
            set: { if !$0 { text.wrappedValue = nil } })) {
            Button("확인") {}
        } message: { Text(text.wrappedValue ?? "") }
    }
}

// MARK: - 탭 스트립 (탭이 많을 때 가로 스크롤 캡슐)
struct TabStrip: View {
    let titles: [String]
    @Binding var tab: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { tab = i }
                    } label: {
                        Text(titles[i])
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(i == tab ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                        in: Capsule())
                            .foregroundStyle(i == tab ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 30)
    }
}

// MARK: - 노드 노트 (Description)
struct NodeNotesView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var text = ""
    @State private var notice: String?
    @State private var dirty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("노드 노트 (Description)").font(.headline)
                Spacer()
                Button {
                    Task { await save() }
                } label: { Label("저장", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            ScrollView {
                ZStack(alignment: .topLeading) {

                IMETextArea(text: $text, mono: true)
                        .frame(minHeight: 180, maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .background(.background)
                        .border(Color.primary.opacity(0.1))
                    if text.isEmpty {
                        Text("노트 내용…").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                    }
                }
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red) }
        }
        .padding(12)
        .task { await load() }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        if let cfg = try? await c.getJSON("/api2/json/nodes/\(node)/config") as? [String: Any] {
            text = cfg["description"] as? String ?? ""
        }
    }

    private func save() async {
        guard let c = app.client else { return }
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/config", form: ["description": text])
            notice = "노트 저장 완료"
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 네트워크 인터페이스 CRUD
struct NodeIface: Codable, Identifiable {
    public let iface: String
    public let type: String?
    public let active: Int?
    public let autostart: Int?
    public let vlanAware: Int?
    public let address: String?
    public let gateway: String?
    public let bridgePorts: String?
    public let bondMode: String?
    public let comments: String?

    public var id: String { iface }

    public init(from decoder: Decoder) throws {
        enum K: String, CodingKey {
            case iface, type, active, autostart, address, gateway, comments
            case vlanAwareKey = "vlan-aware"
            case bridgePortsKey = "bridge_ports"
            case bondModeKey = "bond_mode"
        }
        let c = try decoder.container(keyedBy: K.self)
        iface = try c.decodeIfPresent(String.self, forKey: .iface) ?? "?"
        type = try c.decodeIfPresent(String.self, forKey: .type)
        active = try c.decodeIfPresent(Int.self, forKey: .active)
        autostart = try c.decodeIfPresent(Int.self, forKey: .autostart)
        vlanAware = try c.decodeIfPresent(Int.self, forKey: .vlanAwareKey)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway)
        bridgePorts = try c.decodeIfPresent(String.self, forKey: .bridgePortsKey)
        bondMode = try c.decodeIfPresent(String.self, forKey: .bondModeKey)
        comments = try c.decodeIfPresent(String.self, forKey: .comments)
    }
}

struct NodeNetworkView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var ifaces: [NodeIface] = []
    @State private var hasPending = false
    @State private var notice: String?
    @State private var showSheet = false
    @State private var editing: NodeIface?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("네트워크 (인터페이스)").font(.headline)
                if hasPending { Text("대기 변경 있음").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button {
                    Task { await apply() }
                } label: { Label("변경 적용", systemImage: "checkmark.circle") }
                .controlSize(.small).disabled(!hasPending)
                Button { editing = nil; showSheet = true } label: { Label("인터페이스 추가", systemImage: "plus") }
                .controlSize(.small)
            }
            .padding(10)
            Divider()
            List(ifaces) { n in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: (n.active ?? 0) == 1 ? "network" : "network.slash")
                            .foregroundStyle((n.active ?? 0) == 1 ? .green : .secondary)
                        Text(n.iface).font(.body.monospaced()).bold()
                        Text(n.type ?? "?").font(.caption2).padding(2)
                            .background(.blue.opacity(0.1), in: Capsule())
                        if (n.autostart ?? 0) == 1 { Text("autostart").font(.caption2).foregroundStyle(.green) }
                        if (n.vlanAware ?? 0) == 1 { Text("vlan-aware").font(.caption2).foregroundStyle(.purple) }
                        Spacer()
                        Button("편집") { editing = n; showSheet = true }.controlSize(.small).buttonStyle(.link)
                        Button("삭제", role: .destructive) {
                            Task { await delete(n) }
                        }.controlSize(.small).buttonStyle(.link)
                    }
                    HStack(spacing: 10) {
                        if let a = n.address, !a.isEmpty { Text("IP \(a)").font(.caption.monospaced()) }
                        if let g = n.gateway, !g.isEmpty { Text("GW \(g)").font(.caption.monospaced()) }
                        if let b = n.bridgePorts, !b.isEmpty { Text("포트 \(b)").font(.caption.monospaced()) }
                        if let cmm = n.comments, !cmm.isEmpty { Text(cmm).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showSheet, onDismiss: { Task { await load() } }) {
            NodeNetSheet(node: node, existing: editing)
        }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        if let arr = try? await c.getJSON("/api2/json/nodes/\(node)/network") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
            ifaces = (try? JSONDecoder().decode([NodeIface].self, from: json)) ?? []
            // 대기 변경이 있으면 iface 앞뒤에 pending 플래그/신규 항목("YES")이 온다
            hasPending = arr.contains { d in
                (d["pending"] as? Int) == 1
                || ((d["iface"] as? String) == nil && !d.isEmpty)
            }
        }
    }

    /// PUT (컬렉션) = 대기 상태의 네트워크 설정 적용 (reload)
    private func apply() async {
        guard let c = app.client else { return }
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/network", form: [:])
            notice = "네트워크 설정 적용 완료"
            hasPending = false
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }

    private func delete(_ n: NodeIface) async {
        guard let c = app.client else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/nodes/\(node)/network/\(n.iface)")
            hasPending = true
            messageNotice("…삭제 완료 — '변경 적용'으로 반영")
            await load()
        } catch { messageNotice((error as? PVEError)?.message ?? "\(error)") }
    }

    private func messageNotice(_ s: String) { notice = s }
}

// MARK: - 네트워크 인터페이스 추가/편집 시트
struct NodeNetSheet: View {
    let node: String
    var existing: NodeIface?
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var iface = ""
    @State private var type = "bridge"
    @State private var address = ""
    @State private var gateway = ""
    @State private var ports = ""
    @State private var bondMode = "active-backup"
    @State private var autostart = true
    @State private var vlanAware = false
    @State private var comments = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text(existing == nil ? "네트워크 인터페이스 추가" : "인터페이스 편집 (\(existing?.iface ?? ""))").font(.headline)
            Form {
                IMEField("이름 (예: vmbr1 / enp3s0)", text: $iface)
                    .disabled(existing != nil)
                Picker("유형", selection: $type) {
                    Text("브리지 (vmbr)").tag("bridge")
                    Text("NIC (eth)").tag("eth")
                    Text("본드 (bond)").tag("bond")
                    Text("VLAN (vlan)").tag("vlan")
                    Text("루프백 (lo)").tag("lo")
                }
                HStack {

                IMEField("IPv4 CIDR (예: 192.168.1.5/24)", text: $address)
                IMEField("게이트웨이", text: $gateway)
                }
                if type == "bridge" || type == "bond" {
                IMEField(type == "bond" ? "슬레이브 포트(쉼표)" : "브리지 물리 포트 (비우면 순수 브리지)", text: $ports)
                }
                if type == "bridge" {
                    Toggle("VLAN-aware", isOn: $vlanAware)
                }
                if type == "bond" {
                    Picker("모드", selection: $bondMode) {
                        ForEach(["active-backup", "802.3ad", "balance-rr", "balance-xor", "broadcast", "balance-tlb", "balance-alb"], id: \.self) { Text($0) }
                    }
                }
                Toggle("autostart (부팅 시 활성)", isOn: $autostart)
                IMEField("설명", text: $comments)
            }
            .formStyle(.grouped).frame(width: 460, height: 340)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 440).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(existing == nil ? "추가" : "저장") }
                }
                .buttonStyle(.borderedProminent).disabled(iface.isEmpty || busy)
            }
        }
        .padding(20)
        .onAppear {
            if let e = existing {
                iface = e.iface
                type = e.type ?? "bridge"
                address = e.address ?? ""
                gateway = e.gateway ?? ""
                ports = e.bridgePorts ?? ""
                bondMode = e.bondMode ?? "active-backup"
                autostart = (e.autostart ?? 0) == 1
                vlanAware = (e.vlanAware ?? 0) == 1
                comments = e.comments ?? ""
            }
        }
    }

    private func formFields() -> [String: String] {
        var f: [String: String] = ["type": type, "autostart": autostart ? "1" : "0"]
        if !address.isEmpty { f["address"] = address }
        if !gateway.isEmpty { f["gateway"] = gateway }
        if type == "bridge" || type == "bond", !ports.isEmpty { f["bridge_ports"] = ports }
        if type == "bond" { f["bond_mode"] = bondMode }
        if type == "bridge" && vlanAware { f["vlan-aware"] = "1" }
        if !comments.isEmpty { f["comments"] = comments }
        return f
    }

    private func save() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            if existing != nil {
                _ = try await c.putJSON("/api2/json/nodes/\(node)/network/\(iface)", form: formFields())
            } else {
                _ = try await c.postJSON("/api2/json/nodes/\(node)/network", form: formFields())
            }
            notice = "저장 완료 — '변경 적용'으로 반영하세요"
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - DNS 설정
struct NodeDNSView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var domain1 = ""
    @State private var domain2 = ""
    @State private var domain3 = ""
    @State private var servers = ""
    @State private var notice: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DNS (resolv.conf)").font(.headline)
                Spacer()
                Button {
                    Task { await save() }
                } label: { Label("저장", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(loading)
            }
            Form {
                IMEField("검색 도메인 (search)", text: $search)
                IMEField("1차 도메인 (domain1 — nsswitch 전용)", text: $domain1)
                IMEField("2차 도메인 (domain2 — nsswitch 전용)", text: $domain2)
                IMEField("3차 도메인 (domain3 — nsswitch 전용)", text: $domain3)
                IMEField("네임서버 (예: 8.8.8.8 1.1.1.1)", text: $servers)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 520)
            .disabled(loading)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding(14)
        .task { await load() }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client, !loading else { return }
        if let d = try? await c.getJSON("/api2/json/nodes/\(node)/dns") as? [String: Any] {
            search = d["search"] as? String ?? ""
            domain1 = d["domain1"] as? String ?? ""
            domain2 = d["domain2"] as? String ?? ""
            domain3 = d["domain3"] as? String ?? ""
            servers = d["servers"] as? String ?? ""
        }
    }

    private func save() async {
        guard let c = app.client else { return }
        var f: [String: String] = ["search": search, "servers": servers]
        if !domain1.isEmpty { f["domain1"] = domain1 }
        if !domain2.isEmpty { f["domain2"] = domain2 }
        if !domain3.isEmpty { f["domain3"] = domain3 }
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/dns", form: f)
            notice = "DNS 저장 완료"
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - Hosts (/etc/hosts)
struct NodeHostRow: Identifiable {
    let ip: String
    let hostname: String
    let comment: String
    var id: String { "\(ip)-\(hostname)" }
}

struct NodeHostsView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var rows: [NodeHostRow] = []
    @State private var digest = ""
    @State private var notice: String?
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Hosts (etc/hosts)").font(.headline)
                Spacer()
                Button { showAdd = true } label: { Label("호스트 추가", systemImage: "plus") }.controlSize(.small)
            }
            .padding(10)
            Divider()
            Table(rows) {
                TableColumn("IP") { r in Text(r.ip).monospaced() }
                TableColumn("호스트명") { r in Text(r.hostname).monospaced() }
                TableColumn("주석") { r in Text(r.comment) }
                TableColumn("") { r in
                    Button("삭제", role: .destructive) { Task { await remove(r) } }
                        .controlSize(.small).buttonStyle(.link)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
            NodeHostAddSheet(node: node)
        }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        if let d = try? await c.getJSON("/api2/json/nodes/\(node)/hosts") as? [String: Any] {
            digest = d["digest"] as? String ?? ""
            let raw = d["data"] as? String ?? ""
            rows = parseHosts(raw)
        }
    }

    private func parseHosts(_ s: String) -> [NodeHostRow] {
        s.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { return nil }
            let parts = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            return NodeHostRow(ip: parts[0],
                               hostname: parts[1],
                               comment: parts.count > 2 ? parts.dropFirst(2).joined(separator: " ") : "")
        }
    }

    private func remove(_ r: NodeHostRow) async {
        guard let c = app.client, !digest.isEmpty else { return }
        let q = "?hostname=\(c.percentEncode(r.hostname))&ip=\(c.percentEncode(r.ip))&digest=\(c.percentEncode(digest))"
        do {
            _ = try await c.deleteJSON("/api2/json/nodes/\(node)/hosts\(q)")
            notice = "호스트 삭제 완료"
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

struct NodeHostAddSheet: View {
    let node: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""
    @State private var hostname = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("호스트 추가").font(.headline)
            Form {
                IMEField("IP (예: 10.0.0.10)", text: $ip)
                IMEField("호스트명", text: $hostname)
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
                .buttonStyle(.borderedProminent).disabled(ip.isEmpty || hostname.isEmpty || busy)
            }
        }
        .padding(20)
    }

    private func add() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await c.postJSON("/api2/json/nodes/\(node)/hosts", form: ["hostname": hostname, "ip": ip])
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 시간 (timezone)
struct NodeTimeView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var timezone = ""
    @State private var info = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("시간 (Timezone)").font(.headline)
                Spacer()
                Button {
                    Task { await save() }
                } label: { Label("저장", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(timezone.isEmpty)
            }
            Form {
                IMEField("Timezone (예: Asia/Seoul)", text: $timezone)
            }.formStyle(.grouped).frame(maxWidth: 420)
            if !info.isEmpty { Text(info).font(.caption).foregroundStyle(.secondary) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding(14)
        .task { await load() }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        if let d = try? await c.getJSON("/api2/json/nodes/\(node)/time") as? [String: Any] {
            timezone = d["timezone"] as? String ?? ""
            if let t = d["localtime"] as? Int {
                let date = Date(timeIntervalSince1970: TimeInterval(t))
                info = "노드 현재 시간: \(date.formatted(date: .complete, time: .standard))"
            }
        }
    }

    private func save() async {
        guard let c = app.client else { return }
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/time", form: ["timezone": timezone])
            notice = "Timezone 저장 완료"
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 시스템 로그 (syslog)
struct NodeSyslogRow: Codable, Identifiable {
    public let t: String?
    public let l: String?
    public let n: String?
    public var id: String { "\(t ?? "")-\(n ?? "")-\(UUID().uuidString)" }
}

struct NodeSyslogView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var lines: [NodeSyslogRow] = []
    @State private var notice: String?
    @State private var filterText = ""
    @State private var limit = "200"

    var filtered: [NodeSyslogRow] {
        filterText.isEmpty ? lines : lines.filter { ($0.t ?? "").contains(filterText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("시스템 로그").font(.headline)
                IMEField("필터", text: $filterText).frame(width: 180)
                Text("줄수").font(.caption)
                IMEField("200", text: $limit).frame(width: 50)
                Spacer()
                Button("새로고침") { Task { await loadJson() } }
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { row in
                        Text([row.t ?? "", row.n ?? ""].filter { !$0.isEmpty }.joined(separator: "  "))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
        }
        .task { await loadJson() }
        .pveNotice($notice)
    }

    private func loadJson() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/nodes/\(node)/syslog?limit=\(limit)") ?? []
            guard let arr = raw as? [[String: Any]] else {
                notice = "syslog 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            lines = (try? JSONDecoder().decode([NodeSyslogRow].self, from: json)) ?? []
            notice = nil
        } catch { notice = "syslog 조회 실패: \((error as? PVEError)?.message ?? "\(error)")" }
    }
}

// MARK: - 업데이트 (패키지)
struct NodeUpdatePkg: Codable, Identifiable {
    public let Package: String?
    public let Version: String?
    public let OldVersion: String?
    public let Title: String?
    public let Description: String?
    public var id: String { Package ?? UUID().uuidString }
}

struct NodeUpdatesView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var packages: [NodeUpdatePkg] = []
    @State private var notice: String?
    @State private var busy = false
    @State private var lastUpdate = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("업데이트 (APT)").font(.headline)
                if !lastUpdate.isEmpty { Text(lastUpdate).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button {
                    Task { await refreshIndex() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Label("인덱스 갱신 (apt update)", systemImage: "arrow.triangle.2.circlepath") }
                }
                .controlSize(.small).disabled(busy)
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.orange).padding(10) }
            if packages.isEmpty && !busy {
                Text("업그레이드할 패키지 없음").font(.caption).foregroundStyle(.secondary)
            }
            List(packages) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(p.Package ?? "?").bold().monospaced()
                        Text("\(p.OldVersion ?? "-") → \(p.Version ?? "-")").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let d = p.Description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .task { await loadPkg() }
        .pveNotice($notice)
    }

    private func loadPkg() async {
        guard let c = app.client, !busy else { return }
        do {
            let raw = try await c.getJSON("/api2/json/nodes/\(node)/apt/update")
            guard let arr = raw as? [[String: Any]] else {
                notice = "패키지 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            packages = (try? JSONDecoder().decode([NodeUpdatePkg].self, from: json)) ?? []
            lastUpdate = "업그레이드 \(packages.count)건"
            notice = nil
        } catch {
            // 루트가 아닌 API 사용자면 패키지 조회가 거부될 수 있음
            notice = "패키지 목록 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func refreshIndex() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            if let upid = try await c.postJSON("/api2/json/nodes/\(node)/apt/update", form: [:]) as? String {
                notice = await pollTask(c, upid) ?? "인덱스 갱신 완료"
            }
            await loadPkg()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 리포지토리
struct NodeRepo: Codable, Identifiable {
    public let handle: String
    public let name: String?
    public let status: Int?
    public let components: String?
    public var id: String { handle }
}

struct NodeRepositoriesView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var repos: [NodeRepo] = []
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("리포지토리").font(.headline)
                Spacer()
                Button("새로고침") { Task { await load() } }
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.orange).padding(8) }
            List(repos) { r in
                HStack {
                    Image(systemName: (r.status ?? 0) == 1 ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle((r.status ?? 0) == 1 ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name ?? r.handle).font(.body)
                        Text(r.handle).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { (r.status ?? 0) == 1 },
                        set: { on in Task { await toggle(r, on: on) } }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .task { await load() }
        .pveNotice($notice)
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/nodes/\(node)/apt/repositories") as? [String: Any]
            if let std = raw?["standard-repos"] as? [[String: Any]],
               let json = try? JSONSerialization.data(withJSONObject: std, options: [.fragmentsAllowed]) {
                repos = (try? JSONDecoder().decode([NodeRepo].self, from: json)) ?? []
            }
            notice = nil
        } catch { notice = "리포지토리 조회 실패: \((error as? PVEError)?.message ?? "\(error)")" }
    }

    private func toggle(_ r: NodeRepo, on: Bool) async {
        guard let c = app.client else { return }
        do {
            // PUT /apt/repositories {handle, enabled} — 표준 리포지토리 on/off
            _ = try await c.putJSON("/api2/json/nodes/\(node)/apt/repositories",
                                    form: ["handle": r.handle, "enabled": on ? "1" : "0"])
            await load()
        } catch {
            notice = "리포지토리 변경 실패: \((error as? PVEError)?.message ?? "\(error)")"
            await load()
        }
    }
}

// MARK: - 구독 (Subscription)
struct NodeSubscriptionView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var status = ""
    @State private var level = ""
    @State private var message = ""
    @State private var key = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("구독 (Subscription)").font(.headline)
                Spacer()
                Button("새로고침") { Task { await load() } }
            }
            Form {
                IMEField("구독 키 입력 후 등록", text: $key)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 460)
            HStack {
                Button {
                    Task { await uploadKey() }
                } label: { Label("키 등록", systemImage: "key") }
                .disabled(key.isEmpty)
                Button(role: .destructive) {
                    Task { await removeKey() }
                } label: { Label("키 삭제", systemImage: "trash") }
                Spacer()
            }
            statusCard
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding(14)
        .task { await load() }
        .pveNotice($notice)
    }

    @ViewBuilder private var statusCard: some View {
        HStack {
            Image(systemName: status == "active" ? "checkmark.seal.fill" : "info.circle")
                .foregroundStyle(status == "active" ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("상태: \(status.isEmpty ? "-" : status)\(level.isEmpty ? "" : " · 레벨 \(level)")").font(.body)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        guard let c = app.client else { return }
        if let d = try? await c.getJSON("/api2/json/nodes/\(node)/subscription") as? [String: Any] {
            status = d["status"] as? String ?? ""
            level = d["level"] as? String ?? ""
            message = d["message"] as? String ?? ""
        }
    }

    private func uploadKey() async {
        guard let c = app.client else { return }
        do {
            _ = try await c.postJSON("/api2/json/nodes/\(node)/subscription", form: ["key": key])
            notice = "구독 키 등록 완료"
            key = ""
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }

    private func removeKey() async {
        guard let c = app.client else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/nodes/\(node)/subscription")
            notice = "구독 키 삭제 완료"
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}
