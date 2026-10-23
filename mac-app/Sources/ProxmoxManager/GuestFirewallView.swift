import SwiftUI
import ProxmoxKit

// MARK: - 게스트 방화벽 (rules + options)
/// GET/POST/PUT/DELETE /nodes/{node}/{type}/{vmid}/firewall/rules
/// GET/PUT /nodes/{node}/{type}/{vmid}/firewall/options
struct GuestFirewallView: View {
    let node: String
    let type: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var rules: [FirewallRule] = []
    @State private var options: [String: Any] = [:]
    @State private var notice: String?
    @State private var showRuleSheet = false
    @State private var editing: FirewallRule?

    private var apiBase: String { "/api2/json/nodes/\(node)/\(type)/\(vmid)/firewall/rules" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("방화벽").font(.headline)
                if isGuestFWEnabled {
                    Text("활성").font(.caption).foregroundStyle(.green)
                } else {
                    Text("비활성").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("게스트 방화벽", isOn: Binding(
                    get: { isGuestFWEnabled },
                    set: { on in Task { await setOption("enable", on ? "1" : "0") } }))
                    .toggleStyle(.switch).labelsHidden()

                Spacer()
                Button("새로고침") { Task { await load() } }.controlSize(.small)
                Button {
                    editing = nil; showRuleSheet = true
                } label: { Label("규칙 추가", systemImage: "plus") }.controlSize(.small)
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            List(rules) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("#\(r.pos ?? -1)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                        Text((r.direction ?? "in").uppercased()).font(.caption2).padding(2)
                            .background(.blue.opacity(0.12), in: Capsule())
                        Text(r.action == "DROP" ? "차단" : r.action == "REJECT" ? "거부" : "허용")
                            .font(.caption2)
                            .foregroundStyle(r.action == "DROP" || r.action == "REJECT" ? .red : .green)
                        if let p = r.proto, !p.isEmpty { Text(p).font(.caption.monospaced()) }
                        if let d = r.dport, !d.isEmpty { Text("dport:\(d)").font(.caption.monospaced()) }
                        if let s = r.source, !s.isEmpty { Text("src:\(s)").font(.caption.monospaced()) }
                        if let dd = r.dest, !dd.isEmpty { Text("dst:\(dd)").font(.caption.monospaced()) }
                        if (r.enable ?? 1) != 1 { Text("비활성").font(.caption2).foregroundStyle(.orange) }
                        Spacer()
                        Button("편집") { editing = r; showRuleSheet = true }.controlSize(.small).buttonStyle(.link)
                        Button("삭제", role: .destructive) {
                            Task { await deleteRule(r) }
                        }.controlSize(.small).buttonStyle(.link)
                    }
                    if let cm = r.comment, !cm.isEmpty { Text(cm).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            if !othOpts.isEmpty {
                Text("기타 옵션").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
                ForEach(othOpts, id: \.0) { (k, v) in
                    HStack {
                        Text(k).font(.caption.monospaced()).frame(width: 160, alignment: .leading)
                        Text(v).font(.caption.monospaced())
                        Spacer()
                    }.padding(.horizontal, 12)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showRuleSheet, onDismiss: { Task { await load() } }) {
            FirewallRuleSheet(nodeRule: editing, apiBase: apiBase)
        }
        .pveNotice($notice)
    }

    private var isGuestFWEnabled: Bool { (options["enable"] as? Int ?? 0) == 1 }

    private var othOpts: [(String, String)] {
        var out: [(String, String)] = []
        for (k, v) in options.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            if k == "enable" { continue }
            out.append((k, "\(v)"))
        }
        return out
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let arr = try await c.getJSON(apiBase)
            guard let list = arr as? [[String: Any]] else {
                notice = "방화벽 규칙 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: list, options: [.fragmentsAllowed])
            rules = ((try? JSONDecoder().decode([FirewallRule].self, from: json))) ?? []
            if let o = try? await c.getJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/firewall/options") as? [String: Any] {
                options = o
            }
            notice = nil
        } catch { notice = "방화벽 조회 실패: \((error as? PVEError)?.message ?? "\(error)")" }
    }

    private func deleteRule(_ r: FirewallRule) async {
        guard let c = app.client, let pos = r.pos else { return }
        do {
            _ = try await c.deleteJSON("\(apiBase)/\(pos)")
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }

    private func setOption(_ key: String, _ val: String) async {
        guard let c = app.client else { return }
        do {
            _ = try await c.putJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/firewall/options",
                                    form: [key: val])
            await load()
        } catch {
            notice = "옵션 저장 실패: \((error as? PVEError)?.message ?? "\(error)")"
            await load()
        }
    }
}
