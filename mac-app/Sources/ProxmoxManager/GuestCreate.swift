import SwiftUI
import ProxmoxKit

/// 새 VM/컨테이너 생성 마법사 (메인 툴바 "+"에서 호출)
struct GuestCreateView: View {
    let isVM: Bool   // true: QEMU VM, false: LXC 컨테이너
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var node = ""
    @State private var vmid = ""
    @State private var name = ""
    @State private var cores = "2"
    @State private var memoryMB = "2048"
    @State private var diskGB = "20"
    @State private var storage = ""
    @State private var iso = ""          // VM용
    @State private var template = ""     // LXC용
    @State private var bridge = ""
    @State private var unprivileged = true
    @State private var password = ""
    @State private var notice: String?
    @State private var busy = false

    // 동적으로 불러오는 데이터
    @State private var storages: [StorageInfo] = []
    @State private var isos: [String] = []       // volid
    @State private var templates: [String] = []  // volid
    @State private var bridges: [String] = []    // iface

    var nodes: [String] { app.nodeNames() }
    private var typePath: String { isVM ? "qemu" : "lxc" }

    var body: some View {
        VStack(spacing: 14) {
            Text(isVM ? "새 VM 생성" : "새 컨테이너(LXC) 생성").font(.headline)
            Form {
                Picker("노드", selection: $node.animation()) {
                    Text("선택…").tag("")
                    ForEach(nodes, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: node) { _ in Task { await loadNodeData() } }
                HStack {
                IMEField("VMID", text: $vmid).frame(width: 120)
                IMEField(isVM ? "이름" : "호스트명", text: $name)
                }
                HStack {
                IMEField("코어", text: $cores).frame(width: 80)
                IMEField("메모리 (MB)", text: $memoryMB).frame(width: 130)
                IMEField("디스크 (GB)", text: $diskGB).frame(width: 120)
                }
                Picker("스토리지", selection: $storage) {
                    Text("선택…").tag("")
                    ForEach(storages, id: \.id) { s in Text("\(s.storage) (\(s.type))").tag(s.storage) }
                }
                if isVM {
                    Picker("설치 ISO", selection: $iso) {
                        Text("나중에 연결").tag("")
                        ForEach(isos, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Picker("OS 템플릿", selection: $template) {
                        Text("선택…").tag("")
                        ForEach(templates, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Unprivileged 컨테이너", isOn: $unprivileged)
                IMEField("루트 비밀번호 (선택)", secure: true, text: $password)
                }
                Picker("네트워크 브릿지", selection: $bridge) {
                    Text("선택…").tag("")
                    ForEach(bridges, id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.grouped)
            .frame(width: 480, height: isVM ? 300 : 340)

            HStack {
                Button("취소") { dismiss() }
                Button {
                    Task { await create() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("생성") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(node.isEmpty || vmid.isEmpty || storage.isEmpty || (isVM ? false : template.isEmpty) || busy)
            }
            if let notice {
                Text(notice).font(.footnote)
                    .foregroundStyle(notice.contains("완료") || notice.contains("OK") ? .green : .red)
                    .frame(width: 440).lineLimit(3)
            }
        }
        .padding(20)
        .task {
            if vmid.isEmpty, let c = app.client,
               let nid = try? await c.getJSON("/api2/json/cluster/nextid") as? String {
                vmid = nid
            }
        }
    }

    /// 노드 바꿀 때 스토리지/ISO/템플릿/브릿지 불러오기
    private func loadNodeData() async {
        guard let c = app.client, !node.isEmpty else { return }
        storages = []; isos = []; templates = []; bridges = []
        storage = ""; iso = ""; template = ""; bridge = ""
        do {
            if let arr = try await c.getJSON("/api2/json/nodes/\(node)/storage") as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]),
               let all = try? JSONDecoder().decode([StorageInfo].self, from: data) {
                storages = all.filter { s in
                    let content = s.content ?? ""
                    return content.contains(isVM ? "images" : "rootdir")
                }
                if storage.isEmpty { storage = storages.first?.storage ?? "" }
            }
            if let brs = try await c.getJSON("/api2/json/nodes/\(node)/network") as? [[String: Any]] {
                bridges = brs.compactMap { d -> String? in
                    guard (d["type"] as? String) == "bridge", let f = d["iface"] as? String else { return nil }
                    return f
                }
                if bridge.isEmpty { bridge = bridges.first ?? "" }
            }
            if isVM, !storage.isEmpty {
                if let arr = try await c.getJSON("/api2/json/nodes/\(node)/storage/\(storage)/content?content=iso") as? [[String: Any]] {
                    isos = arr.compactMap { $0["volid"] as? String }
                }
            } else if !isVM, !storage.isEmpty {
                if let arr = try await c.getJSON("/api2/json/nodes/\(node)/storage/\(storage)/content?content=vztmpl") as? [[String: Any]] {
                    templates = arr.compactMap { $0["volid"] as? String }
                }
            }
        } catch {
            notice = "기본 데이터 로드 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func create() async {
        guard let c = app.client, let id = Int(vmid) else { return }
        busy = true; defer { busy = false }
        do {
            var form: [String: String] = [
                "vmid": "\(id)",
                "cores": cores,
                "memory": memoryMB
            ]
            let disk: String = "\(storage):\(diskGB)"
            if isVM {
                form["name"] = name.isEmpty ? "vm-\(id)" : name
                form["scsi0"] = disk
                form["net0"] = "virtio,bridge=\(bridge.isEmpty ? "vmbr0" : bridge)"
                if !iso.isEmpty { form["ide2"] = "\(iso),cdrom" }
            } else {
                form["hostname"] = name.isEmpty ? "ct-\(id)" : name
                form["ostemplate"] = template
                form["rootfs"] = disk
                form["net0"] = "name=eth0,bridge=\(bridge.isEmpty ? "vmbr0" : bridge),ip=dhcp"
                if unprivileged { form["unprivileged"] = "1" }
                if !password.isEmpty { form["password"] = password }
            }
            if let upid = try await c.postJSON("/api2/json/nodes/\(node)/\(typePath)", form: form) as? String {
                let result = await pollTask(c, upid) ?? "생성 완료"
                notice = result
                app.refreshQuiet()
                if result.contains("완료") { try? await Task.sleep(nanoseconds: 800_000_000); dismiss() }
            }
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}
