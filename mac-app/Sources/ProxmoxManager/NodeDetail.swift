import SwiftUI
import ProxmoxKit

struct NodeDetail: View {
    let node: String
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var status: NodeStatus?
    @State private var decodeError: String?
    @State private var services: [ServiceInfo] = []
    @State private var tasks: [PVETask] = []
    @State private var notice: String?
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(node, systemImage: "desktopcomputer").font(.title3.bold())
                    Text(status?.pveversion ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                NodePowerMenu(node: node)
                Button {
                    app.openShell(.init(node: node))
                    openWindow(id: "shell")
                } label: { Label("셸", systemImage: "terminal") }
            }
            .padding(12)
            Divider()
            Picker("탭", selection: $tab.animation()) {
                Text("모니터링").tag(0)
                Text("서비스").tag(1)
                Text("태스크").tag(2)
                Text("디스크").tag(3)
                Text("시스템").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 520)
            .padding(.vertical, 6)
            Divider()
            tabContent
        }
        .navigationTitle(node)
        .task { await load() }
        .onChange(of: app.resources) { _ in Task { await load() } }
        .alert("결과", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") {}
        } message: { Text(notice ?? "") }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 0:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RRDSeriesView(path: "/api2/json/nodes/\(node)/rrddata",
                                  series: [("cpu", "CPU", .orange),
                                           ("mem", "메모리", .blue),
                                           ("loadavg", "로드 평균", .yellow),
                                           ("rootused", "루트 디스크 사용", .red),
                                           ("netin", "네트워크 In", .green),
                                           ("netout", "네트워크 Out", .purple)])
                    LazyVStack(alignment: .leading) {
                        if let de = decodeError {
                            Text(de).font(.footnote).foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        StatRow(label: "코어", value: "\(status?.cpus ?? 0)")
                        StatRow(label: "로드 평균", value: (status?.loadavg ?? []).joined(separator: " / "))
                        StatRow(label: "메모리", value: "\(ByteCount(status?.mem ?? 0)) / \(ByteCount(status?.maxmem ?? 0))")
                        StatRow(label: "루트 디스크", value: "\(ByteCount(status?.rootfs?.used ?? 0)) / \(ByteCount(status?.rootfs?.total ?? 0))")
                        StatRow(label: "KSM", value: ByteCount(status?.ksmshared ?? 0))
                        StatRow(label: "업타임", value: UptimeString(status?.uptime ?? 0))
                        StatRow(label: "커널", value: status?.kversion ?? "-")
                    }
                }
                .padding()
            }
        case 1:
            NodeServiceListView(node: node)
        case 2:
            TaskListView(tasks: tasks)
        case 3:
            NodeDiskListView(node: node)
        case 4:
            NodeSystemView(node: node)
        default: EmptyView()
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        if let st = try? await c.getJSON("/api2/json/nodes/\(node)/status") as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: st, options: [.fragmentsAllowed]) {
            do {
                status = try JSONDecoder().decode(NodeStatus.self, from: json)
                decodeError = nil
            } catch {
                decodeError = "상태 디코딩 실패: \(error.localizedDescription)"
            }
        }
        if let sv = try? await c.getJSON("/api2/json/nodes/\(node)/services") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: sv, options: [.fragmentsAllowed]) {
            services = (try? JSONDecoder().decode([ServiceInfo].self, from: json)) ?? []
        }
        if let t = try? await c.getJSON("/api2/json/nodes/\(node)/tasks?limit=30") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: t, options: [.fragmentsAllowed]) {
            tasks = (try? JSONDecoder().decode([PVETask].self, from: json)) ?? []
        }
    }
}
