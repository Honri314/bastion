import SwiftUI
import ProxmoxKit

// MARK: - 노드 서비스 제어 (start / restart / stop)
@MainActor
final class NodeServiceController: ObservableObject {
    @Published var notice: String?

    func control(_ app: AppState, node: String, service: String, action: String) async {
        guard let c = app.client else { return }
        do {
            if let upid = try await c.postJSON("/api2/json/nodes/\(node)/services/\(service)/\(action)", form: [:]) as? String {
                notice = await pollTask(c, upid) ?? "\(service) \(action) 완료"
            } else {
                notice = "\(service) \(action) 완료"
            }
            app.refreshQuiet()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

/// 노드 상세 "서비스" 탭 (시작/재시작/정지 버튼 포함)
struct NodeServiceListView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var services: [ServiceInfo] = []
    @State private var decodeError: String?
    @StateObject private var ctl = NodeServiceController()

    var body: some View {
        VStack(spacing: 0) {
            if let de = decodeError {
                Text(de).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            List(services) { s in
                HStack(spacing: 10) {
                    Circle().fill(s.state == "running" ? .green : .red)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.body.monospaced())
                        Text(s.desc ?? "-").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    controlButtons(s, running: s.state == "running")
                }
            }
        }
        .task { await load() }
        .onChange(of: app.resources) { _ in Task { await load() } }
        .alert("결과", isPresented: Binding(get: { ctl.notice != nil }, set: { if !$0 { ctl.notice = nil } })) {
            Button("확인") {}
        } message: { Text(ctl.notice ?? "") }
    }

    @ViewBuilder private func controlButtons(_ s: ServiceInfo, running: Bool) -> some View {
        if running {
            Button("정지") {
                Task { await ctl.control(app, node: node, service: s.name, action: "stop") }
            }
            .controlSize(.small)
            Button("재시작") {
                Task { await ctl.control(app, node: node, service: s.name, action: "restart") }
            }
            .controlSize(.small)
        } else {
            Button("시작") {
                Task { await ctl.control(app, node: node, service: s.name, action: "start") }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/nodes/\(node)/services")
            guard let arr = raw as? [[String: Any]] else {
                decodeError = "서비스 응답이 배열이 아님: \(String("\(raw)".prefix(120)))"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            services = try JSONDecoder().decode([ServiceInfo].self, from: json)
            decodeError = nil
        } catch {
            decodeError = "서비스 목록 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}

// MARK: - 노드 전원 (재부팅 / 셧다운)
struct NodePowerMenu: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var confirmPower: String?   // "reboot" | "shutdown"
    @State private var notice: String?

    var body: some View {
        Menu {
            Button("재부팅") { confirmPower = "reboot" }
            Button("전원끄기", role: .destructive) { confirmPower = "shutdown" }
        } label: { Label("전원", systemImage: "power") }
        .confirmationDialog("노드 \(node)를 \(confirmPower == "reboot" ? "재부팅" : "전원끄기") 하시겠습니까?",
                            isPresented: Binding(get: { confirmPower != nil }, set: { if !$0 { confirmPower = nil } }),
                            titleVisibility: .visible) {
            Button("실행", role: .destructive) {
                if let cmd = confirmPower { Task { await power(cmd) } }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("결과", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") {}
        } message: { Text(notice ?? "") }
    }

    private func power(_ cmd: String) async {
        guard let c = app.client else { return }
        do {
            try await c.postJSON("/api2/json/nodes/\(node)/status", form: ["command": cmd])
            notice = "\(cmd) 명령 전송 — 노드가 응답을 잠시 끊습니다"
            app.refreshQuiet()
        } catch {
            // 셧다운 중엔 연결이 끊기는 게 정상 — 실패가 아니라 전송됨으로 취급
            notice = "명령 전송 (노드 응답이 끊길 수 있음): \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}

// MARK: - 노드 디스크 헬스
struct NodeDisk: Codable, Identifiable {
    public let devpath: String?
    public let model: String?
    public let serial: String?
    public let size: Int?
    public let health: String?
    public let type: String?
    public let used: String?
    public let wearout: StringOrInt?
    public let gpt: Int?
    public var id: String { devpath ?? model ?? UUID().uuidString }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devpath = try c.decodeIfPresent(String.self, forKey: .devpath)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        health = try c.decodeIfPresent(String.self, forKey: .health)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        used = try c.decodeIfPresent(String.self, forKey: .used)
        wearout = try? c.decodeIfPresent(StringOrInt.self, forKey: .wearout)
        gpt = try c.decodeIfPresent(Int.self, forKey: .gpt)
    }
    public enum CodingKeys: String, CodingKey {
        case devpath, model, serial, size, health, type, used, wearout, gpt
    }
}

/// wearout이 Int(0~100) 또는 "N/A" 둘 다 올 수 있음
public enum StringOrInt: Codable {
    case str(String)
    case num(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .num(i) }
        else if let s = try? c.decode(String.self) { self = .str(s) }
        else { self = .str("?") }
    }

    var display: String {
        switch self {
        case .str(let s): return s
        case .num(let i): return i == 100 ? "100 / 신제품" : "\(i)"
        }
    }
}

struct NodeDiskListView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var disks: [NodeDisk] = []
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            if let note {
                Text(note).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            List(disks) { d in
                HStack(spacing: 10) {
                    Image(systemName: d.health == "PASSED" ? "internaldrive.fill" : "internaldrive")
                        .foregroundStyle(d.health == "PASSED" ? .green : (d.health == "FAILED" ? .red : .secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(d.devpath ?? "-") · \(d.model ?? "-")").font(.body.monospaced())
                        Text("직렬 \(d.serial ?? "-") · \(d.type ?? "-") · 사용처 \(d.used ?? "-") \(d.wearout.map { "· 마모 \($0.display)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(d.size.map { ByteCount($0) } ?? "-").font(.caption.monospaced())
                        Text(d.health ?? "-")
                            .font(.caption.bold())
                            .foregroundStyle(d.health == "PASSED" ? .green : (d.health == "FAILED" ? .red : .secondary))
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: app.resources) { _ in Task { await load() } }
    }

    private func load() async {
        guard let c = app.client, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let raw = try await c.getJSON("/api2/json/nodes/\(node)/disks/list")
            guard let arr = raw as? [[String: Any]] else {
                note = "디스크 응답이 배열이 아님: \(String("\(raw)".prefix(120)))"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            disks = try JSONDecoder().decode([NodeDisk].self, from: json)
            note = nil
        } catch {
            note = "디스크 목록 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}
