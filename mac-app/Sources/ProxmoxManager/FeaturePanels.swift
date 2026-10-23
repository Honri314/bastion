import SwiftUI
import ProxmoxKit

// MARK: - 노드 '시스템' 탭 (하위 탭 스트립)
struct NodeSystemView: View {
    let node: String
    @State private var tab = 0
    private let titles = ["노트", "네트워크", "DNS", "Hosts", "시간", "시스템 로그", "업데이트", "리포지토리", "구독", "인증서", "Ceph"]

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(titles: titles, tab: $tab)
            Divider()
            switch tab {
            case 0: NodeNotesView(node: node)
            case 1: NodeNetworkView(node: node)
            case 2: NodeDNSView(node: node)
            case 3: NodeHostsView(node: node)
            case 4: NodeTimeView(node: node)
            case 5: NodeSyslogView(node: node)
            case 6: NodeUpdatesView(node: node)
            case 7: NodeRepositoriesView(node: node)
            case 8: NodeSubscriptionView(node: node)
            case 9: NodeCertificatesView(node: node)
            case 10: NodeCephView(node: node)
            default: EmptyView()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 게스트 '시스템' 탭 (하위 탭 스트립)
struct GuestSystemView: View {
    let node: String
    let type: String
    let vmid: Int
    let isVMKind: Bool
    @State private var tab = 0
    private var titles: [String] {
        var t = ["옵션", "모니터", "권한"]
        if isVMKind { t.insert("Cloud-Init", at: 1) }
        t.append("방화벽")
        t.append("복제")
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(titles: titles, tab: $tab)
            Divider()
            // 확장/축소 탭에서 인덱스 안전 보정
            if tab >= titles.count { Color.clear.onAppear { tab = 0 } }
            else {
                switch tab {
                case 0: GuestOptionsView(node: node, type: type, vmid: vmid)
                default:
                    if isVMKind {
                        switch tab {
                        case 1: GuestCloudInitView(node: node, vmid: vmid)
                        case 2: GuestMonitorView(node: node, type: type, vmid: vmid)
                        case 3: GuestPermissionsView(node: node, type: type, vmid: vmid)
                        case 4: GuestFirewallView(node: node, type: type, vmid: vmid)
                        case 5: GuestReplicationView(node: node, type: type, vmid: vmid)
                        default: EmptyView()
                        }
                    } else {
                        switch tab {
                        case 1: GuestMonitorView(node: node, type: type, vmid: vmid)
                        case 2: GuestPermissionsView(node: node, type: type, vmid: vmid)
                        case 3: GuestFirewallView(node: node, type: type, vmid: vmid)
                        case 4: GuestReplicationView(node: node, type: type, vmid: vmid)
                        default: EmptyView()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: isVMKind) { _ in tab = 0 }
    }
}
