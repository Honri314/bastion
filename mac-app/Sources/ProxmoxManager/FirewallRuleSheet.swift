import SwiftUI
import ProxmoxKit

// 방화벽 규칙 (PVE pos 기반 CRUD)
struct FirewallRule: Codable, Identifiable {
    public let pos: Int?
    public let type: String?
    public let action: String?
    public let direction: String?
    public let enable: Int?
    public let proto: String?
    public let dport: String?
    public let sport: String?
    public let dest: String?
    public let source: String?
    public let macro: String?
    public let comment: String?
    public var id: String { "pos-\(pos ?? -9999)-\(source ?? "")" }
}

// MARK: - 방화벽 규칙 추가/편집 시트
// apiBase 예:
//   클러스터: /api2/json/cluster/firewall/rules
//   노드:     /api2/json/nodes/{node}/firewall/rules
//   게스트:   /api2/json/nodes/{node}/{qemu|lxc}/{vmid}/firewall/rules
struct FirewallRuleSheet: View {
    var nodeRule: FirewallRule?   // nil이면 새 규칙(POST), 있으면 편집(PUT pos)
    var apiBase: String = "/api2/json/cluster/firewall/rules"
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var direction = "in"
    @State private var action = "ACCEPT"
    @State private var enableOn = true
    @State private var proto = "tcp"
    @State private var source = ""
    @State private var dest = ""
    @State private var dport = ""
    @State private var sport = ""
    @State private var comment = ""
    @State private var notice: String?
    @State private var busy = false

    var isEdit: Bool { nodeRule != nil }

    var body: some View {
        VStack(spacing: 14) {
            Text(isEdit ? "방화벽 규칙 편집 (#\(nodeRule?.pos ?? -1))" : "방화벽 규칙 추가").font(.headline)
            Form {
                Picker("방향", selection: $direction) {
                    Text("IN").tag("in"); Text("OUT").tag("out")
                }.pickerStyle(.segmented)
                Picker("동작", selection: $action) {
                    Text("허용 (ACCEPT)").tag("ACCEPT")
                    Text("차단 (DROP)").tag("DROP")
                    Text("거부 (REJECT)").tag("REJECT")
                }
                Picker("프로토콜", selection: $proto) {
                    Text("tcp").tag("tcp"); Text("udp").tag("udp"); Text("icmp").tag("icmp"); Text("(비움=모두)").tag("")
                }
                IMEField("소스 (비우면 모두, 예: 10.0.0.0/8)", text: $source)
                IMEField("목적지 (비우면 모두)", text: $dest)
                HStack {
                IMEField("대상 포트 (예: 8006 또는 1000:2000)", text: $dport)
                IMEField("소스 포트", text: $sport)
                }
                IMEField("설명", text: $comment)
                Toggle("활성화", isOn: $enableOn)
            }
            .formStyle(.grouped)
            .frame(width: 460, height: 300)
            HStack {
                if isEdit {
                    Button("삭제", role: .destructive) {
                        Task { await deleteRule() }
                    }
                }
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(isEdit ? "저장" : "추가") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(notice.contains("완료") ? .green : .red)
                    .frame(width: 440).lineLimit(3)
            }
        }
        .padding(20)
        .onAppear {
            if let r = nodeRule {
                direction = (r.direction ?? "in").lowercased() == "out" ? "out" : "in"
                action = r.action ?? "ACCEPT"
                enableOn = (r.enable ?? 1) == 1
                proto = r.proto ?? ""
                source = r.source ?? ""
                dest = r.dest ?? ""
                dport = r.dport ?? ""
                sport = r.sport ?? ""
                comment = r.comment ?? ""
            }
        }
    }

    private var formFields: [String: String] {
        var f: [String: String] = ["type": direction, "action": action, "enable": enableOn ? "1" : "0"]
        if !proto.isEmpty { f["proto"] = proto }
        if !source.isEmpty { f["source"] = source }
        if !dest.isEmpty { f["dest"] = dest }
        if !dport.isEmpty { f["dport"] = dport }
        if !sport.isEmpty { f["sport"] = sport }
        if !comment.isEmpty { f["comment"] = comment }
        return f
    }

    private func save() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            if let r = nodeRule, let pos = r.pos {
                _ = try await c.putJSON("\(apiBase)/\(pos)", form: formFields)
            } else {
                _ = try await c.postJSON("\(apiBase)", form: formFields)
            }
            notice = "저장 완료"
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }

    private func deleteRule() async {
        guard let c = app.client, let pos = nodeRule?.pos else { return }
        do {
            _ = try await c.deleteJSON("\(apiBase)/\(pos)")
            notice = "삭제 완료"
            try? await Task.sleep(nanoseconds: 400_000_000)
            dismiss()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}
