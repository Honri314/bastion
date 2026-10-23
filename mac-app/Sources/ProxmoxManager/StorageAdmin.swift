import SwiftUI
import ProxmoxKit

// MARK: - 스토리지 정의 (클러스터 스토리지 설정 CRUD)
// GET/POST /api2/json/storage, PUT/DELETE /api2/json/storage/{id}
struct StorageDef: Codable, Identifiable {
    public let storage: String
    public let type: String?
    public let content: String?
    public let enable: Int?
    public let path: String?
    public let server: String?
    public let export: String?
    public let digest: String?
    public var id: String { storage }
}

// MARK: - 스토리지 정의 관리 시트 (전체 목록 + 추가/편집/삭제)
struct StorageDefsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var defs: [StorageDef] = []
    @State private var notice: String?
    @State private var editing: StorageDef?
    @State private var showAdd = false
    @State private var busyID: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("스토리지 정의 (데이터센터)").font(.headline)
                Spacer()
                Button("새로고침") { Task { await load() } }
                Button {
                    showAdd = true
                } label: { Label("추가", systemImage: "plus") }
            }
            List(defs) { d in
                HStack {
                    let isOff = (d.enable ?? 1) == 0
                    let iconName = isOff ? "externaldrive.badge.exclamationmark" : "externaldrive.fill"
                    Image(systemName: iconName)
                        .foregroundStyle(isOff ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(d.storage) — \(d.type ?? "?")").font(.body.monospaced())
                        Text("콘텐츠: \(d.content ?? "-")\(d.path.map { " · 경로 \($0)" } ?? "")\(d.server.map { " · 서버 \($0)\(d.export.map { "/\($0)" } ?? "")" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("편집") { editing = d }.controlSize(.small).buttonStyle(.link)
                    Button("삭제", role: .destructive) {
                        Task { await remove(d) }
                    }.controlSize(.small).buttonStyle(.link).disabled(busyID == d.storage)
                }
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 520).lineLimit(3)
            }
            HStack { Spacer(); Button("닫기") { dismiss() } }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .task { await load() }
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
            StorageDefSheet(existing: nil)
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { d in
            StorageDefSheet(existing: d)
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/storage")
            guard let arr = raw as? [[String: Any]] else {
                notice = "스토리지 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            defs = (try? JSONDecoder().decode([StorageDef].self, from: json)) ?? []
            notice = nil
        } catch {
            notice = "스토리지 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func remove(_ d: StorageDef) async {
        guard let c = app.client else { return }
        busyID = d.storage
        defer { busyID = nil }
        do {
            _ = try await c.deleteJSON("/api2/json/storage/\(c.percentEncode(d.storage))")
            notice = "스토리지 '\(d.storage)' 삭제 완료"
            await load()
        } catch {
            notice = "삭제 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}

// MARK: - 스토리지 정의 추가/편집 시트
struct StorageDefSheet: View {
    var existing: StorageDef?
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var type = "dir"
    @State private var content = "images,iso"
    @State private var path = ""
    @State private var server = ""
    @State private var export = ""
    @State private var username = ""
    @State private var nodes = ""
    @State private var disable = false
    @State private var notice: String?
    @State private var busy = false

    static let contentTypes = ["images", "rootdir", "vztmpl", "iso", "backup", "snippets", "import"]

    var body: some View {
        VStack(spacing: 12) {
            Text(existing == nil ? "스토리지 추가" : "스토리지 편집 (\(existing?.storage ?? ""))").font(.headline)
            Form {
                IMEField("스토리지 ID (예: local-nfs)", text: $id).disabled(existing != nil)
                Picker("유형", selection: $type) {
                    ForEach(["dir", "nfs", "cifs", "lvm", "lvmthin", "zfspool", "rbd", "pbs"], id: \.self) { Text($0) }
                }
                HStack {
                    Text("콘텐츠").font(.caption)
                    ForEach(Self.contentTypes, id: \.self) { t in
                        Button {
                            toggleContent(t)
                        } label: {
                            Text(t)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(content.contains(t) ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                IMEField("\(type) 경로 (예: /mnt/data)", text: $path)
                    .disabled(!(type == "dir" || type == "lvm" || type == "lvmthin" || type == "zfspool"))
                HStack {
                IMEField("서버 (nfs/cifs/rbd)", text: $server)
                        .disabled(!(type == "nfs" || type == "cifs" || type == "rbd"))
                IMEField("export (nfs/cifs)", text: $export)
                        .disabled(!(type == "nfs" || type == "cifs"))
                IMEField("사용자 (cifs 선택)", text: $username)
                        .disabled(type != "cifs")
                }
                IMEField("노드 제한 (비우면 전체, 쉼표로 여러 개)", text: $nodes)
                Toggle("비활성 (disable)", isOn: $disable)
            }
            .formStyle(.grouped).frame(width: 520, height: 300)
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 500).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(existing == nil ? "추가" : "저장") }
                }
                .buttonStyle(.borderedProminent).disabled(id.isEmpty || busy)
            }
        }
        .padding(20)
        .onAppear {
            if let e = existing {
                id = e.storage
                type = e.type ?? "dir"
                content = e.content ?? ""
                path = e.path ?? ""
                server = e.server ?? ""
                export = e.export ?? ""
                disable = (e.enable ?? 1) == 0
            }
        }
    }

    private func toggleContent(_ t: String) {
        var parts = Set(content.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if parts.contains(t) { parts.remove(t) } else { parts.insert(t) }
        content = parts.sorted().joined(separator: ",")
    }

    private func formFields() -> [String: String] {
        var f: [String: String] = [
            "type": type,
            "content": content,
            "enable": disable ? "0" : "1",
        ]
        if !path.isEmpty { f["path"] = path }
        if !server.isEmpty { f["server"] = server }
        if !export.isEmpty { f["export"] = export }
        if !username.isEmpty { f["username"] = username }
        if !nodes.isEmpty { f["nodes"] = nodes }
        return f
    }

    private func save() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            if existing != nil {
                _ = try await c.putJSON("/api2/json/storage/\(c.percentEncode(id))", form: formFields())
            } else {
                var f = formFields(); f["storage"] = id
                _ = try await c.postJSON("/api2/json/storage", form: f)
            }
            notice = "저장 완료"
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}


// MARK: - 볼 정리 (백업 일괄 삭제 / prune)
struct PruneSheet: View {
    let node: String
    let storage: String
    let volumes: [StorageContent]
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var keepLast = "3"
    @State private var keepDaily = "7"
    @State private var keepWeekly = "0"
    @State private var keepMonthly = "0"
    @State private var dryRun = true
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("볼 정리 (백업 프루닝) — \(storage)").font(.headline)
            Form {
                IMEField("최근 N개 유지 (keep-last)", text: $keepLast)
                HStack {
                IMEField("일별 유지 (keep-daily)", text: $keepDaily)
                IMEField("주별 유지 (keep-weekly)", text: $keepWeekly)
                IMEField("월별 유지 (keep-monthly)", text: $keepMonthly)
                }
                Toggle("드라이런 (삭제 대상만미보기, 실제 삭제 안 함)", isOn: $dryRun)
                Text("현재 백업 볼: \(volumes.filter { $0.volid.contains(":backup") || ($0.format ?? "").contains("tar") || ($0.format ?? "").contains("zst") }.count)건")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .formStyle(.grouped).frame(width: 460, height: 210)
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(notice.contains("완료") ? .green : .red)
                    .frame(width: 440).lineLimit(6).font(.caption.monospaced())
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await prune() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("실행") }
                }
                .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .padding(20)
    }

    private func prune() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        func toInt(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces)) }
        var f: [String: String] = [:]
        if (toInt(keepLast) ?? 0) > 0 { f["keep-last"] = keepLast }
        if (toInt(keepDaily) ?? 0) > 0 { f["keep-daily"] = keepDaily }
        if (toInt(keepWeekly) ?? 0) > 0 { f["keep-weekly"] = keepWeekly }
        if (toInt(keepMonthly) ?? 0) > 0 { f["keep-monthly"] = keepMonthly }
        if dryRun { f["dry-run"] = "1" }
        do {
            if let raw = try await c.postJSON("/api2/json/nodes/\(node)/storage/\(storage)/prunebackups", form: f) {
                if let arr = raw as? [[String: Any]], !arr.isEmpty {
                    notice = "프루닝 결과 (\(dryRun ? "시뮬레이션" : "삭제")): " +
                        arr.compactMap { "\($0["volid"] ?? "") → \($0["notes"] ?? "")" }
                        .joined(separator: "\n")
                } else {
                    notice = "삭제 대상 없음 (완료)"
                }
            }
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

// MARK: - 볼륨 개별 삭제는 StorageView.swift의 StorageListView 내부에 구현 (private 멤버 접근)

