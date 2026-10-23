import SwiftUI
import ProxmoxKit

// MARK: - 공용 헬퍼
extension AppState {
    /// 온라인 노드 목록 (마이그레이션 대상/생성 위치 선택용)
    func nodeNames() -> [String] {
        resources.filter { $0.type == "node" }.map { $0.name }.sorted()
    }
}

// MARK: - 게스트 마이그레이션
struct MigrateGuestSheet: View {
    let node: String, type: String, vmid: Int, name: String
    let running: Bool, isVMKind: Bool
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var notice: String?
    @State private var busy = false

    var nodes: [String] { app.nodeNames().filter { $0 != node } }

    var body: some View {
        VStack(spacing: 14) {
            Text("\(vmid) · \(name) 이동").font(.headline)
            Form {
                Picker("대상 노드", selection: $target) {
                    ForEach(nodes, id: \.self) { Text($0).tag($0) }
                }
                if running {
                    if isVMKind {
                        Text("실행 중인 VM은 온라인(라이브) 마이그레이션으로 시도합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("LXC는 실행 중 이동이 제한됩니다 — 정지 후 시도하는 것이 안전합니다.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 420, height: 170)
            HStack {
                Button("취소") { dismiss() }
                Button {
                    Task { await migrate() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("이동") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(target.isEmpty || busy)
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(notice.contains("완료") ? .green : .red)
                    .frame(width: 400).lineLimit(3)
            }
        }
        .padding(20)
        .onAppear {
            if target.isEmpty { target = nodes.first ?? "" }
        }
    }

    private func migrate() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            var form = ["target": target]
            if running && isVMKind { form["restart"] = "1" }   // 실행 중이면 restart 마이그레이션
            if let upid = try await c.postJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/migrate", form: form) as? String {
                let result = await pollTask(c, upid) ?? "이동 완료"
                notice = result
                app.refreshQuiet()
                if result.contains("완료") { try? await Task.sleep(nanoseconds: 800_000_000); dismiss() }
            }
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

// MARK: - 게스트 복제
struct CloneGuestSheet: View {
    let node: String, type: String, vmid: Int, name: String
    let isVMKind: Bool
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newid = ""
    @State private var newName = ""
    @State private var full = true
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 14) {
            Text("\(vmid) · \(name) 복제").font(.headline)
            Form {                 HStack { IMEField("새 VMID", text: $newid).frame(width: 120) }
                IMEField("새 이름 (선택)", text: $newName)
                Toggle("전체 복제 (linked 아닌 실제 복사)", isOn: $full)
                Text(isVMKind
                     ? "전체 복제는 디스크 용량만큼 시간이 걸립니다. 원본은 건드리지 않습니다."
                     : "컨테이너 복제는 정지 상태에서 가장 안전합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(width: 420, height: 210)
            HStack {
                Button("취소") { dismiss() }
                Button {
                    Task { await clone() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("복제") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newid.isEmpty || busy)
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(notice.contains("완료") ? .green : .red)
                    .frame(width: 400).lineLimit(3)
            }
        }
        .padding(20)
        .task {
            if newid.isEmpty, let c = app.client,
               let nid = try? await c.getJSON("/api2/json/cluster/nextid") as? String {
                newid = nid
            }
        }
    }

    private func clone() async {
        guard let c = app.client, let nid = Int(newid) else { return }
        busy = true; defer { busy = false }
        do {
            var form = ["newid": "\(nid)", "full": full ? "1" : "0"]
            if !newName.isEmpty { form["name"] = newName }
            if let upid = try await c.postJSON("/api2/json/nodes/\(node)/\(type)/\(vmid)/clone", form: form) as? String {
                let result = await pollTask(c, upid) ?? "복제 완료"
                notice = result
                app.refreshQuiet()
                if result.contains("완료") { try? await Task.sleep(nanoseconds: 800_000_000); dismiss() }
            }
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}
