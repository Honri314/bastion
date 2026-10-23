import SwiftUI
import ProxmoxKit

/// 설정 탭 상단의 하드웨어 빠른 편집 (코어/메모리 저장, 디스크 용량 확장)
/// - 코어/메모리: PUT /nodes/{node}/{type}/{vmid}/config
/// - 디스크 확장: POST /nodes/{node}/{type}/{vmid}/resize
struct GuestHardwareEditor: View {
    let node: String, type: String, vmid: Int
    let config: [String: Any]?
    @EnvironmentObject var app: AppState
    @State private var cores = ""
    @State private var memory = ""
    @State private var diskOptions: [DiskOpt] = []
    @State private var selectedDisk = ""
    @State private var addGB = "10"
    @State private var notice: String?
    @State private var showDeleteDiskConfirm = false

    var apiPath: String { "/api2/json/nodes/\(node)/\(type)/\(vmid)" }

    private struct DiskOpt: Identifiable {
        var key: String
        var info: String
        var sizeGB: Int?
        var id: String { key }
    }

    static let diskKeys = ["rootfs", "scsi0", "scsi1", "scsi2", "virtio0", "virtio1", "virtio2", "sata0", "sata1", "sata2", "ide0", "ide1"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 코어/메모리
            HStack(spacing: 10) {
                Text("코어").foregroundStyle(.secondary).font(.caption).frame(width: 44, alignment: .leading)
                IMEField("코어", text: $cores).frame(width: 70)
                Text("메모리(MB)").foregroundStyle(.secondary).font(.caption).frame(width: 72, alignment: .trailing)
                IMEField("MB", text: $memory).frame(width: 90)
                Button {
                    Task { await saveConfig() }
                } label: { Text("저장") }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(cores.isEmpty || memory.isEmpty)
                Spacer()
            }
            Text("코어/메모리 저장은 일부 항목에서 VM 정지 상태가 필요할 수 있습니다 (PVE가 거부하면 결과에 표시됨).")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()

            // 디스크
            if !diskOptions.isEmpty {
                Picker("디스크", selection: $selectedDisk) {
                    ForEach(diskOptions) { d in
                        Text("\(d.key) — \(d.info)").tag(d.key)
                    }
                }
                .frame(width: 520)
                HStack {
                    Text("현재 크기: \(currentSizeText)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                IMEField("추가 GB", text: $addGB).frame(width: 70)
                    Button {
                        Task { await resize() }
                    } label: { Label("디스크 확장", systemImage: "arrow.up.right.square") }
                    .controlSize(.small)
                    .disabled(selectedDisk.isEmpty || Int(addGB) == nil)
                    Button("삭제", role: .destructive) { showDeleteDiskConfirm = true }
                        .controlSize(.small)
                        .disabled(selectedDisk.isEmpty || selectedDisk == "rootfs")
                        .help("디스크를 VM 설정에서 분리·삭제합니다 (데이터 소실!)")
                }
            } else {
                Text("디스크 찾기 실패 — 원본 JSON에서 확인하세요.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onAppear { refreshFromConfig() }
        .alert("정말 디스크를 삭제하시겠습니까? (\(selectedDisk))", isPresented: $showDeleteDiskConfirm) {
            Button("삭제", role: .destructive) { Task { await deleteDisk() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("디스크 이미지가 스토리지에서 제거됩니다. 되돌릴 수 없습니다.")
        }
        .alert("결과", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") {}
        } message: { Text(notice ?? "") }
    }

    var currentSizeText: String {
        diskOptions.first(where: { $0.key == selectedDisk })?.sizeGB.map { "\($0) GB" } ?? "-"
    }

    private func refreshFromConfig() {
        guard let c = config else { return }
        if let cc = c["cores"] { cores = "\(cc)" }
        if let mem = c["memory"], let mem = mem as? (any FixedWidthInteger) {
            memory = "\(mem)"
        } else if let mem = c["memory"] { memory = "\(mem)" }

        var found: [DiskOpt] = []
        for key in Self.diskKeys {
            if let val = c[key] as? String {
                // size=12G 추출 (radiating: keIDE supports 만 허용)
                let sizeGB: Int? = {
                    if let r = val.range(of: "size=([0-9.]+)G", options: .regularExpression) {
                        return Double(String(val[r].dropFirst(5)).filter { $0.isNumber || $0 == "." })
                            .flatMap { Int($0.rounded()) }
                    }
                    return nil
                }()
                let short = val.count > 70 ? String(val.prefix(70)) + "…" : val
                found.append(DiskOpt(key: key, info: short, sizeGB: sizeGB))
            }
        }
        diskOptions = found
        if selectedDisk.isEmpty { selectedDisk = found.first?.key ?? "" }
    }

    private func saveConfig() async {
        guard let c = app.client else { return }
        do {
            _ = try await c.putJSON("\(apiPath)/config", form: ["cores": cores, "memory": memory])
            notice = "설정 저장 완료"
            app.refreshQuiet()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }

    private func resize() async {
        guard let c = app.client, let g = Int(addGB) else { return }
        do {
            if let upid = try await c.postJSON("\(apiPath)/resize", form: ["disk": selectedDisk, "size": "+\(g)G"]) as? String {
                notice = await pollTask(c, upid) ?? " 확장 완료"
            } else {
                notice = "확장 완료"
            }
            app.refreshQuiet()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }

    private func deleteDisk() async {
        guard let c = app.client else { return }
        do {
            if let upid = try await c.deleteJSON("\(apiPath)/\(selectedDisk)") as? String {
                notice = await pollTask(c, upid) ?? "삭제 완료"
            } else {
                notice = "삭제 요청 완료"
            }
            app.refreshQuiet()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}
