import SwiftUI
import ProxmoxKit

// MARK: - 스냅샷 목록 (가져오기/생성/롤백/삭제)
struct SnapshotListView: View {
    let node: String
    let type: String        // vm | lxc
    let vmid: Int
    @EnvironmentObject var app: AppState
    @State private var snaps: [Snapshot] = []
    @State private var notice: String?
    @State private var newName = ""
    @State private var desc = ""
    @State private var includeRam = false
    @State private var showNew = false
    @State private var busy = false

    var apiPath: String { "/api2/json/nodes/\(node)/\(type)/\(vmid)" }
    private var isVMKind: Bool { type == "vm" || type == "qemu" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("스냅샷").font(.headline)
                Spacer()
                Button {
                    showNew = true
                } label: { Label("스냅샷 생성", systemImage: "plus") }
            }
            .padding(10)
            Divider()
            Table(snaps) {
                TableColumn("이름") { s in
                    HStack {
                        Image(systemName: s.name == "current" ? "tray.full" : "camera")
                            .foregroundStyle(s.name == "current" ? .gray : .orange)
                        Text(s.name)
                    }
                }
                TableColumn("시간") { s in
                    Text(s.snaptime.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .standard) } ?? "-")
                }
                TableColumn("설명") { s in Text(s.description ?? "") }
                TableColumn("상태") { s in
                    if s.vmstate == 1 { Text("RAM 저장됨").foregroundStyle(.blue) }
                }
                TableColumn("작업") { s in
                    if s.name != "current" {
                        HStack(spacing: 6) {
                            Button("롤백") { Task { await act("rollback", "/" + s.name) } }.controlSize(.small)
                            Button("삭제", role: .destructive) { Task { await act("delsnapshot", "/" + s.name) } }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showNew) { newSheet }
        .alert("결과", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") {}
        } message: { Text(notice ?? "") }
    }

    private var newSheet: some View {
        VStack(spacing: 14) {
            Text("새 스냅샷").font(.headline)
            Form {
                IMEField("이름 (영문/숫자/-/_)", text: $newName)
                IMEField("설명", text: $desc)
                if isVMKind {
                    Toggle("RAM 상태 포함 (vmstate)", isOn: $includeRam)
                }
            }
            .formStyle(.grouped)
            .frame(width: 360, height: 150)
            HStack {
                Button("취소") { showNew = false }
                Button("생성") {
                    Task { await createSnapshot(); showNew = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.isEmpty)
            }
        }
        .padding(20)
    }

    private func load() async {
        guard let c = app.client else { return }
        if let arr = try? await c.getJSON("\(apiPath)/snapshot") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
            snaps = (try? JSONDecoder().decode([Snapshot].self, from: json)) ?? []
        }
    }

    private func createSnapshot() async {
        guard let c = app.client else { return }
        var form: [String: String] = ["snapname": newName, "description": desc]
        if isVMKind && includeRam { form["vmstate"] = "1" }
        busy = true
        defer { busy = false }
        do {
            if let upid = try await c.postJSON("\(apiPath)/snapshot", form: form) as? String {
                notice = await pollTask(c, upid) ?? "스냅샷 생성 완료"
            }
            await load()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }

    private func act(_ action: String, _ snap: String) async {
        guard let c = app.client else { return }
        do {
            let path = action == "delsnapshot" ? "\(apiPath)/snapshot\(snap)" : "\(apiPath)/snapshot\(snap)/rollback"
            let method = action == "delsnapshot" ? "DELETE" : "POST"
            if let data = try await (action == "delsnapshot" ? c.deleteJSON(path) : c.postJSON(path, form: [:])) as? String {
                notice = await pollTask(c, data) ?? "\(action) 완료"
            }
            await load()
            app.refreshQuiet()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

/// UPID 태스크를 0.5초 간격 폴링해 상태 문자열 반환
public func pollTask(_ c: PVEClient, _ upid: String, maxSeconds: Int = 180) async -> String? {
    if !(upid.hasPrefix("UPID:")) { return upid }
    let node = nodeOf(upid)
    let path = "/api2/json/nodes/\(node)/tasks/\(c.percentEncode(upid))/status"
    for _ in 0..<(maxSeconds * 2) {
        if let st = try? await c.getJSON(path) as? [String: Any],
           let status = st["status"] as? String, status != "running" {
            let exit = st["exitstatus"] as? String
            return exit == "OK" ? "완료 (OK)" : "실패: \(exit ?? "?")"
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    return "작업이 여전히 실행 중입니다 (태스크 탭에서 확인)"
}

private func nodeOf(_ upid: String) -> String {
    let parts = upid.split(separator: ":")
    return parts.count > 1 ? String(parts[1]) : "local"
}

// MARK: - 태스크 목록
struct TaskListView: View {
    let tasks: [PVETask]
    var body: some View {
        Table(tasks) {
            TableColumn("시작") { t in Text(t.date) }
            TableColumn("유형") { t in Text(t.type ?? "") }
            TableColumn("설명") { t in Text(t.desc ?? "") }
            TableColumn("노드") { t in Text(t.node ?? "") }
            TableColumn("사용자") { t in Text(t.user) }
            TableColumn("상태") { t in
                if t.isRunning {
                    HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("실행 중") }
                } else {
                    Text(t.status ?? "").foregroundStyle(t.status == "OK" ? .green : .red)
                }
            }
        }
    }
}

// MARK: - 클러스터 태스크
struct TasksView: View {
    @EnvironmentObject var app: AppState
    @State private var tasks: [PVETask] = []
    @State private var filterText = ""

    var filtered: [PVETask] {
        filterText.isEmpty ? tasks : tasks.filter { ($0.desc ?? "").localizedCaseInsensitiveContains(filterText) || $0.user.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("클러스터 태스크").font(.headline)
                IMEField("필터", text: $filterText).frame(width: 200)
                Spacer()
                Button("새로고침") { Task { await load() } }
            }
            .padding(10)
            Divider()
            TaskListView(tasks: filtered)
        }
        .task { await load() }
    }

    private func load() async {
        guard let c = app.client else { return }
        if let arr = try? await c.getJSON("/api2/json/cluster/tasks?limit=100") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
            tasks = (try? JSONDecoder().decode([PVETask].self, from: json)) ?? []
        }
    }
}
