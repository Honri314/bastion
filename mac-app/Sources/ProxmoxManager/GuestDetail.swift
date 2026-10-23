import SwiftUI
import ProxmoxKit

// MARK: - 공용 헬퍼
func ByteCount(_ v: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
}
func UptimeString(_ s: Int) -> String {
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)일 \(h)시간" }
    if h > 0 { return "\(h)시간 \(m)분" }
    return "\(m)분"
}
/// 임의 JSON을 예쁘게 문자열로
func pretty(_ any: Any?) -> String {
    guard let any else { return "-" }
    if let ordered = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys]),
       let obj = try? JSONSerialization.jsonObject(with: ordered),
       let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]) {
        return String(decoding: prettyData, as: UTF8.self)
    }
    return String(describing: any)
}

struct MiniBar: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color).frame(width: max(8, geo.size.width * Double(min(1, value))))
            }
        }.frame(height: 5)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }
}

// MARK: - RRD 스파크라인
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let v = values.filter { $0.isFinite && $0 > 0 }
            let maxV = v.max() ?? 1
            let minV = min(v.min() ?? 0, maxV * 0.2)
            let range = max(maxV - minV, 0.000001)
            Path { p in
                guard v.count > 1, geo.size.width > 0 else { return }
                for (i, x) in v.enumerated() {
                    let px = CGFloat(i) / CGFloat(v.count - 1) * geo.size.width
                    let py = geo.size.height - CGFloat((x - minV) / range) * geo.size.height
                    if i == 0 { p.move(to: CGPoint(x: px, y: py)) } else { p.addLine(to: CGPoint(x: px, y: py)) }
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
        .background(Color.primary.opacity(0.03))
        .frame(height: 60)
    }
}

/// rrddata 차트: path 예 "/api2/json/nodes/pve/rrddata"
struct RRDSeriesView: View {
    let path: String
    let series: [(key: String, label: String, color: Color)]
    /// rrddata는 1분 간격 데이터라 초당 폴링은 무의미 — 기본 30초 자동 갱신
    var refreshSeconds: Double = 30
    @EnvironmentObject var app: AppState
    @State private var points: [RRDPoint] = []
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note {
                Text(note).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(series, id: \.label) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.label).font(.caption).foregroundStyle(.secondary)
                    Sparkline(values: points.map { value(of: s.key, in: $0) }, color: s.color)
                }
            }
        }
        .task {
            // rrddata는 1분 간격 데이터 — refreshSeconds(기본 30초) 주기로 갱신
            await load()
            while true {
                do { try await Task.sleep(nanoseconds: UInt64(refreshSeconds * 1_000_000_000)) }
                catch { break }   // 뷰 소멸 시 취소
                await load()
            }
        }
        .onChange(of: app.resources) { _ in Task { await load() } }
    }

    private func value(of key: String, in p: RRDPoint) -> Double {
        for child in Mirror(reflecting: p).children where child.label == key {
            return (child.value as? Double) ?? 0
        }
        return 0
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("\(path)?timeframe=hour")
            guard let arr = raw as? [[String: Any]] else {
                note = "rrddata 응답이 배열이 아닙니다: \(String("\(raw)".prefix(150)))"
                return
            }
            // JSONDecoder는 null 필드 하나로 전체 valueNotFound → 딕셔너리 직접 파싱 (null/누락 허용)
            points = arr.map { RRDPoint(fromDict: $0) }
            note = points.isEmpty ? "rrddata 포인트 0건 (서버가 빈 배열 반환)" : nil
        } catch {
            note = "rrddata 조회 실패: \(String(error.localizedDescription.prefix(200)))"
        }
    }
}

// MARK: - 게스트 상세
enum GuestAction: String, CaseIterable {
    case start, stop, reboot, shutdown
    case reset = "reset"
    case suspend = "suspend"
    case resume = "resume"
    case migrate
    case clone
    case delete

    var label: String {
        switch self {
        case .start: "시작"; case .stop: "정지"; case .reboot: "재시작"; case .shutdown: "셧다운"
        case .reset: "리셋"; case .suspend: "일시정지"; case .resume: "재개"
        case .migrate: "다른 노드로 이동"; case .clone: "복제"; case .delete: "영구 삭제"
        }
    }
    var destructive: Bool { self == .stop || self == .reset || self == .delete }
}

struct GuestDetail: View {
    let node: String
    let type: String        // vm | lxc
    let vmid: Int
    let name: String
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var tab = 0
    @State private var status: GuestStatus?
    @State private var decodeError: String?
    @State private var config: [String: Any]?
    @State private var notice: String?
    @State private var confirmingAction: GuestAction?
    @State private var showMigrate = false
    @State private var showClone = false

    var res: ClusterResource? {
        app.resources.first { $0.isGuest && $0.vmid == vmid }
    }

    var running: Bool { (res?.status) == "running" }
    var apiPath: String { "/api2/json/nodes/\(node)/\(type)/\(vmid)" }
    private var isVMKind: Bool { type == "vm" || type == "qemu" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack {
                Picker("탭", selection: $tab.animation()) {
                    Text("모니터링").tag(0)
                    Text("스냅샷").tag(1)
                    Text("백업").tag(2)
                    Text("설정").tag(3)
                    Text("시스템").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 480)
                Spacer()
                consoleButtons
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            tabContent
        }
        .navigationTitle("\(vmid) · \(name)")
        .task { await load() }
        .onChange(of: app.resources) { _ in Task { await load() } }
        .confirmationDialog("정말 \(confirmingAction?.label ?? "") 하시겠습니까?",
                            isPresented: Binding(get: { confirmingAction != nil }, set: { if !$0 { confirmingAction = nil } }),
                            titleVisibility: .visible) {
            Button("실행", role: confirmingAction?.destructive == true ? .destructive : .cancel) {
                if let a = confirmingAction { Task { await doAction(a) } }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("결과", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") {}
        } message: { Text(notice ?? "") }
        .sheet(isPresented: $showMigrate) {
            MigrateGuestSheet(node: node, type: type, vmid: vmid, name: name,
                              running: running, isVMKind: isVMKind)
        }
        .sheet(isPresented: $showClone) {
            CloneGuestSheet(node: node, type: type, vmid: vmid, name: name, isVMKind: isVMKind)
        }
    }

    private var header: some View {
        HStack {
            Circle().fill(running ? .green : .gray).frame(width: 10, height: 10)
            Text(running ? "실행 중" : "정지").font(.headline)
            Text(res?.node ?? node).font(.caption).foregroundStyle(.secondary)
            if running {
                Text("업타임 \(UptimeString(res?.uptime ?? 0))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(GuestAction.allCases, id: \.self) { a in
                    if a == .migrate {
                        Button(a.label) { showMigrate = true }
                    } else if a == .clone {
                        Button(a.label) { showClone = true }
                    } else {
                        Button(a.label) { confirmingAction = a }
                    }
                }
            } label: { Label("액션", systemImage: "bolt") }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
        }
        .padding(12)
    }

    private var consoleButtons: some View {
        HStack(spacing: 6) {
            Button {
                app.openShell(.init(node: node, vmid: vmid, isVM: isVMKind))
                openWindow(id: "shell")
            } label: { Label("셸", systemImage: "terminal") }
                .help(isVMKind ? "VM 시리얼 콘솔 (qemu)" : "LXC 콘솔")

            if isVMKind {
                Button {
                    app.openVNC(VNCConfig(host: app.client?.host ?? "", port: app.client?.port ?? 8006, node: node, vmid: vmid))
                    openWindow(id: "vnc")
                } label: { Label("VNC", systemImage: "display") }
                .help("noVNC 그래픽 콘솔")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 0:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RRDSeriesView(path: "\(apiPath)/rrddata",
                                  series: [("cpu", "CPU 사용률", .orange),
                                           ("mem", "메모리", .blue),
                                           ("netin", "네트워크 In", .green),
                                           ("netout", "네트워크 Out", .purple),
                                           ("diskread", "디스크 Read", .red),
                                           ("diskwrite", "디스크 Write", .indigo)])
                    LazyVStack(alignment: .leading) {
                        if let de = decodeError {
                            Text(de).font(.footnote).foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        StatRow(label: "상태", value: res?.status ?? "-")
                        StatRow(label: "코어", value: "\(status?.cpus ?? 0)")
                        StatRow(label: "메모리", value: "\(ByteCount(status?.mem ?? 0)) / \(ByteCount(status?.maxmem ?? 0))")
                        if status?.maxswap != nil && status!.maxswap! > 0 {
                            StatRow(label: "스왑", value: ByteCount(status?.maxswap ?? 0))
                        }
                        StatRow(label: "네트워크", value: "in \(ByteCount(Int(status?.netin ?? 0)))/s · out \(ByteCount(Int(status?.netout ?? 0)))/s")
                        StatRow(label: "디스크", value: "read \(ByteCount(Int(status?.diskread ?? 0)))/s · write \(ByteCount(Int(status?.diskwrite ?? 0)))/s")
                    }
                }
                .padding()
            }
        case 1: SnapshotListView(node: node, type: type, vmid: vmid)
        case 2: BackupView(node: node, type: type, vmid: vmid)
        case 3:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    GuestHardwareEditor(node: node, type: type, vmid: vmid, config: config)
                        .padding(.horizontal).padding(.top, 8)
                    Divider()
                    ConfigView(raw: config).padding(.horizontal)
                }
            }
        case 4:
            GuestSystemView(node: node, type: type, vmid: vmid, isVMKind: isVMKind)
        default: EmptyView()
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        if let st = try? await c.getJSON("\(apiPath)/status/current") as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: st, options: [.fragmentsAllowed]) {
            do {
                status = try JSONDecoder().decode(GuestStatus.self, from: json)
                decodeError = nil
            } catch {
                decodeError = "상태 디코딩 실패: \(error.localizedDescription)"
            }
        }
        if let cf = try? await c.getJSON("\(apiPath)/config") as? [String: Any] {
            config = cf
        }
    }

    private func doAction(_ action: GuestAction) async {
        guard let c = app.client else { return }
        do {
            switch action {
            case .delete:
                if let upid = try await c.deleteJSON("\(apiPath)?destroy-unreferenced-disks=1&purge=1") as? String {
                    notice = await pollTask(c, upid) ?? "삭제 완료"
                } else { notice = "삭제 요청 전송" }
            case .migrate, .clone:
                return   // 파라미터 필요 — 별도 시트로 처리 (showMigrate/showClone)
            default:
                _ = try await c.postJSON("\(apiPath)/status/\(action.rawValue)", form: [:])
                notice = "\(action.label) 작업을 요청했습니다."
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            app.refreshQuiet()
            await load()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

// MARK: - 설정(JSON) 뷰
struct ConfigView: View {
    let raw: [String: Any]?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(pretty(raw))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
