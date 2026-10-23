import SwiftUI
import ProxmoxKit

// MARK: - 스토리지 목록 (클러스터 리소스에서 추출)
struct StorageListView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: StorageInfo?
    @State private var contents: [StorageContent] = []
    @State private var notice: String?
    @State private var showBackup: Bool = false
    @State private var showPrune = false
    @State private var showStorageDefs = false

    var storages: [StorageInfo] {
        app.resources.filter { $0.type == "storage" }.compactMap { _ in nil }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                let list = storageList()
                ForEach(list) { s in
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(s.active == 1 ? .green : .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.storage).font(.body)
                            Text("\(s.node) · \((s.content ?? "").split(separator: ",").joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let f = s.used_fraction {
                            Text("\(Int(f * 100))%").font(.caption.monospaced())
                        }
                        MiniBar(value: s.used_fraction ?? 0, color: (s.used_fraction ?? 0) > 0.9 ? .red : .blue)
                            .frame(width: 60)
                    }
                    .tag(s)
                }
            }
            .navigationTitle("스토리지")
        } detail: {
            VStack(spacing: 0) {
                if let s = selected {
                    HStack {
                        Text("\(s.node) ▸ \(s.storage)").font(.headline)
                        Spacer()
                        Button("볼 정리 (프루닝)") { showPrune = true }
                        Button("백업 지금 실행") { showBackup = true }
                        Button("스토리지 정의 관리") { showStorageDefs = true }
                    }
                    .padding(10)
                    Divider()
                    Table(contents) {
                        TableColumn("볼륨", value: \.volid)
                        TableColumn("VMID") { c in Text(c.vmid.map(String.init) ?? "-") }
                        TableColumn("포맷") { c in Text(c.format ?? "-") }
                        TableColumn("크기") { c in Text(c.size.map { ByteCount($0) } ?? "-") }
                        TableColumn("생성") { c in
                            Text(c.creation.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened) } ?? "-")
                        }
                        TableColumn("메모") { c in Text(c.notes ?? "") }
                        TableColumn("") { c in
                            Button("삭제", role: .destructive) {
                                Task { await deleteVolume(c) }
                            }.controlSize(.small).buttonStyle(.link)
                        }
                    }
                } else {
                    Text("왼쪽에서 스토리지를 선택하세요").foregroundStyle(.secondary)
                }
            }
            .task(id: selected) { await loadContent() }
            .sheet(isPresented: $showBackup) { BackupNowSheet(node: selected?.node ?? "", storage: selected?.storage ?? "") }
            .sheet(isPresented: $showPrune) {
                PruneSheet(node: selected?.node ?? "", storage: selected?.storage ?? "", volumes: contents)
            }
            .sheet(isPresented: $showStorageDefs) { StorageDefsSheet() }
            .alert("결과", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("확인") {}
            } message: { Text(notice ?? "") }
        }
    }

    /// /cluster/resources 중 type=storage 항목을 StorageInfo로 변환
    private func storageList() -> [StorageInfo] {
        app.resources.filter { $0.type == "storage" }.compactMap { r in
            StorageInfo(storage: r.name, node: r.node ?? "", type: "unknown",
                        active: r.status == "available" ? 1 : 0, content: nil,
                        used_fraction: nil, used: r.disk, total: r.maxdisk, enabled: 1)
        }
    }

    private func loadContent() async {
        guard let c = app.client, let s = selected else { return }
        if let arr = try? await c.getJSON("/api2/json/nodes/\(s.node)/storage/\(s.storage)/content") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
            contents = (try? JSONDecoder().decode([StorageContent].self, from: json)) ?? []
        }
    }

    private func deleteVolume(_ v: StorageContent) async {
        guard let c = app.client, let s = selected else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/nodes/\(s.node)/storage/\(s.storage)/content/\(c.percentEncode(v.volid))")
            notice = "볼륨 삭제 완료: \(v.volid)"
            await loadContent()
        } catch {
            notice = "볼륨 삭제 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}

// MARK: - vzdump 즉시 백업
struct BackupNowSheet: View {
    let node: String
    let storage: String
    @EnvironmentObject var app: AppState
    @State private var vmidText = ""
    @State private var mode = "snapshot"
    @State private var compress = "zstd"
    @State private var result: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("vzdump 백업 실행").font(.headline)
            Form {
                IMEField("VMID (VM/CT 번호, 여러 개는 쉼표)", text: $vmidText)
                Picker("모드", selection: $mode) {
                    Text("스냅샷").tag("snapshot")
                    Text("일시정지").tag("suspend")
                    Text("정지").tag("stop")
                }
                Picker("압축", selection: $compress) {
                    Text("zstd").tag("zstd")
                    Text("gzip").tag("gzip")
                    Text("없음").tag("0")
                }
            }
            .formStyle(.grouped)
            .frame(width: 380, height: 170)
            if let r = result {
                Text(r).font(.caption).foregroundStyle(.secondary).frame(width: 380)
                Button("닫기") {}
            }
            HStack {
                Button("취소") {}
                Button("백업 시작") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(vmidText.isEmpty)
            }
        }
        .padding(20)
    }

    private func run() async {
        guard let c = app.client else { return }
        do {
            let form: [String: String] = [
                "vmid": vmidText.replacingOccurrences(of: " ", with: ""),
                "storage": storage,
                "mode": mode,
                "compress": compress,
            ]
            if let upid = try await c.postJSON("/api2/json/nodes/\(node)/vzdump", form: form) as? String {
                result = await pollTask(c, upid, maxSeconds: 600) ?? upid
            } else {
                result = "업무 요청됨 (태스크 탭 확인)"
            }
        } catch {
            result = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

// MARK: - 게스트 내 백업 탭 (최근 백업 나열)
struct BackupView: View {
    let node: String
    let type: String
    let vmid: Int
    @EnvironmentObject var app: AppState
    @State private var rows: [StorageContent] = []
    @State private var storages: [StorageInfo] = []
    @State private var chosen = BackupView.placeholder
    @State private var notice: String?

    static var placeholder = StorageInfo(storage: "", node: "", type: "", active: nil, content: nil, used_fraction: nil, used: nil, total: nil, enabled: nil)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("백업 (vzdump)").font(.headline)
                Picker("저장소", selection: $chosen) {
                    ForEach(storages) { s in
                        Text("\(s.node)/\(s.storage)").tag(s)
                    }
                }
                .frame(width: 260)
                Button("지금 백업") { Task { await backupNow() } }
            }
            .padding(10)
            Divider()
            Table(rows) {
                TableColumn("볼륨", value: \.volid)
                TableColumn("포맷") { r in Text(r.format ?? "-") }
                TableColumn("크기") { r in Text(r.size.map { ByteCount($0) } ?? "-") }
                TableColumn("생성") { r in
                    Text(r.creation.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .standard) } ?? "-")
                }
            }
        }
        .task { await load() }
        .alert("결과", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") {}
        } message: { Text(notice ?? "") }
    }

    private func load() async {
        guard let c = app.client else { return }
        if let arr = try? await c.getJSON("/api2/json/cluster/resources?type=storage") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
            let raw = (try? JSONDecoder().decode([StorageInfo].self, from: json)) ?? []
            storages = raw.filter { ($0.content ?? "").contains("backup") }
            if chosen.storage.isEmpty { chosen = storages.first ?? BackupView.placeholder }
        }
        await refreshRows()
    }

    private func refreshRows() async {
        guard let c = app.client, chosen.storage != "" else { return }
        if let arr = try? await c.getJSON("/api2/json/nodes/\(chosen.node)/storage/\(chosen.storage)/content?content=backup") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
            let all = (try? JSONDecoder().decode([StorageContent].self, from: json)) ?? []
            rows = all.filter { $0.vmid == vmid }
        }
    }

    private func backupNow() async {
        guard let c = app.client, chosen.storage != "" else { return }
        do {
            let form: [String: String] = ["vmid": "\(vmid)", "storage": chosen.storage, "mode": "snapshot", "compress": "zstd"]
            if let upid = try await c.postJSON("/api2/json/nodes/\(node)/vzdump", form: form) as? String {
                notice = await pollTask(c, upid, maxSeconds: 600) ?? upid
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshRows()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

// MARK: - API 탐색기 (모든 API 수동 호출)
struct ApiExplorerView: View {
    @EnvironmentObject var app: AppState
    @State private var pathInput = "/api2/json/cluster/status"
    @State private var method = "GET"
    @State private var bodyText = ""
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proxmox API 탐색기 — 모든 API 엔드포인트에 직접 호출").font(.headline)
            HStack {
                Picker("", selection: $method) {
                    Text("GET").tag("GET")
                    Text("POST").tag("POST")
                    Text("DELETE").tag("DELETE")
                }.frame(width: 110)
                IMEField("/api2/json/...", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                Button("실행") { Task { await run() } }
            }
            if method != "GET" {
                IMEField("폼 파라미터: key=value&key2=value2", text: $bodyText)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                Text(output.isEmpty ? "결과가 여기에 표시됩니다" : output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private func run() async {
        guard let c = app.client else { return }
        do {
            var form: [String: String]? = nil
            if method != "GET", !bodyText.isEmpty {
                form = bodyText
                    .split(separator: "&")
                    .compactMap { sub -> [String: String]? in
                        let kv = sub.split(separator: "=", maxSplits: 1)
                        guard kv.count == 2 else { return nil }
                        return [String(kv[0]): String(kv[1])]
                    }
                    .reduce(into: [:]) { $0.merge($1) { _, n in n } }
            }
            let data: Any?
            if method == "GET" {
                data = try await c.getJSON(pathInput)
            } else if method == "POST" {
                data = try await c.postJSON(pathInput, form: form ?? [:])
            } else {
                data = try await c.deleteJSON(pathInput)
            }
            output = pretty(result: data)
        } catch {
            output = "오류: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    func pretty(result: Any?) -> String { PVEpretty(result) }
}

private func PVEpretty(_ any: Any?) -> String { pretty(any) }


