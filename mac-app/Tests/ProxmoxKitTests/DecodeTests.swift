import XCTest
@testable import ProxmoxKit

/// 실서버 응답과 동일한 형태의 샘플 JSON이 모델로 정상 디코딩되는지 검증
final class DecodeTests: XCTestCase {

    /// PVE /cluster/resources 의 실제 응답 형태 (노드/VM/LXC/스토리지 혼합)
    func testClusterResources() throws {
        let json = """
        [
          {"id":"node/pve1","type":"node","status":"online","name":"pve1",
           "node":"pve1","maxmem":34359672832,"mem":12000000000,"maxcpu":16,
           "cpu":0.0234,"uptime":123456,"disk":2000000000,"maxdisk":900000000000},
          {"id":"qemu/101","vmid":101,"type":"qemu","name":"win11","node":"pve1",
           "status":"running","cpus":4,"maxmem":8589934592,"mem":4000000000,
           "cpu":0.0511,"uptime":9900,"disk":0,"maxdisk":214748364800,"tags":""},
          {"id":"lxc/201","vmid":201,"type":"lxc","name":"docker","node":"pve1",
           "status":"running","cpus":2,"maxmem":2147483648,"mem":800000000,
           "cpu":0.003,"uptime":300,"disk":2000000000,"maxdisk":8589934592},
          {"id":"storage/pve1","storage":"local","type":"storage","node":"pve1",
           "status":"available","disk":900000000,"maxdisk":900000000000,
           "plugintype":"dir","content":"iso,vztmpl,backup"}
        ]
        """.data(using: .utf8)!

        let res = try JSONDecoder().decode([ClusterResource].self, from: json)
        XCTAssertEqual(res.count, 4)

        let node = try XCTUnwrap(res.first { $0.type == "node" })
        XCTAssertEqual(node.name, "pve1")
        XCTAssertEqual(node.cpu ?? -1, 0.0234, accuracy: 0.0000001)
        XCTAssertEqual(node.mem, 12_000_000_000)
        XCTAssertEqual(node.maxmem, 34_359_672_832)

        let vm = try XCTUnwrap(res.first { $0.vmid == 101 })
        XCTAssertEqual(vm.name, "win11")
        XCTAssertEqual(vm.cpu ?? -1, 0.0511, accuracy: 0.0000001)
        XCTAssertEqual(vm.mem, 4_000_000_000)
        XCTAssertTrue(vm.isGuest)
    }

    /// 노드 상세: /nodes/{node}/status 응답 형태
    func testNodeStatus() throws {
        let json = """
        {"uptime":123456,"pveversion":"pve-manager/8.2.4/1",
         "wait":0.001,"idle":12.5,"loadavg":["0.50","0.40","0.30"],
         "kversion":"Linux 6.8.12-1-pve","ksmshared":1073741824,
         "cpu":0.0234,"cpus":16,"maxmem":34359672832,"mem":12000000000,
         "rootfs":{"used":2000000000,"total":900000000000,"free":898000000000}}
        """.data(using: .utf8)!

        let st = try JSONDecoder().decode(NodeStatus.self, from: json)
        XCTAssertEqual(st.cpu ?? -1, 0.0234, accuracy: 0.0000001)
        XCTAssertEqual(st.mem, 12_000_000_000)
        XCTAssertEqual(st.loadavg?.count, 3)
        XCTAssertEqual(st.rootfs?.total, 900_000_000_000)
    }

    /// 게스트(VM) 상세: /nodes/{node}/qemu/{vmid}/status/current 응답 형태
    func testGuestStatusVM() throws {
        let json = """
        {"status":"running","uptime":9900,"cpu":0.0511,"cpus":4,
         "mem":4000000000,"maxmem":8589934592,"swapfree":0,"maxswap":0,
         "netin":1048576.5,"netout":524288.2,"diskread":2621440.0,
         "diskwrite":1310720.0,"diskfree":107374182400,"qmpstatus":"running",
         "ha":{"managed":0},"running-qemu":1,"running-machine":"pc-q35-9.0"}
        """.data(using: .utf8)!

        let st = try JSONDecoder().decode(GuestStatus.self, from: json)
        XCTAssertEqual(st.cpu ?? -1, 0.0511, accuracy: 0.0000001)
        XCTAssertEqual(st.mem, 4_000_000_000)
        XCTAssertEqual(st.netin ?? -1, 1_048_576.5, accuracy: 0.01)
        XCTAssertEqual(st.qmpstatus, "running")
    }

    /// rrddata 포인트
    func testRRDPoint() throws {
        let json = """
        [{"t":1729500000,"cpu":0.0511,"mem":4000000000,"maxmem":8589934592,
          "netin":1048576.5,"netout":524288.2,"diskread":2621440.0,"diskwrite":1310720.0},
         {"t":1729500060,"cpu":0.0311,"mem":4100000000}]
        """.data(using: .utf8)!

        let pts = try JSONDecoder().decode([RRDPoint].self, from: json)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].cpu ?? -1, 0.0511, accuracy: 0.0000001)
        XCTAssertNil(pts[1].netin)
    }
}
