import Foundation

// MARK: - 클러스터 리소스 (VM/LXC/노드/스토리지 통합 목록)
public struct ClusterResource: Codable, Identifiable, Hashable {
    public let vmid: Int?
    public let name: String
    public let type: String        // vm | lxc | node | storage | pool | sdn
    public let status: String
    public let node: String?
    public let maxmem: Int?
    public let mem: Int?
    public let maxcpu: Double?
    public let cpu: Double?
    public let uptime: Int?
    public let tags: String?
    public let disk: Int?
    public let maxdisk: Int?

    /// PVE는 항목 유형별로 식별자 필드가 다르다:
    /// vm/lxc → name, node → node, storage → storage, pool → poolname
    /// name이 없는 유형이 있으므로 커스텀 디코더로 보강한다.
    private enum CodingKeys: String, CodingKey {
        case vmid, name, type, status, node, maxmem, mem, maxcpu, cpu, uptime, tags, disk, maxdisk, storage, poolname
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmid = try c.decodeIfPresent(Int.self, forKey: .vmid)
        type = (try c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        status = (try c.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        node = try c.decodeIfPresent(String.self, forKey: .node)
        maxmem = try c.decodeIfPresent(Int.self, forKey: .maxmem)
        mem = try c.decodeIfPresent(Int.self, forKey: .mem)
        maxcpu = try c.decodeIfPresent(Double.self, forKey: .maxcpu)
        cpu = try c.decodeIfPresent(Double.self, forKey: .cpu)
        uptime = try c.decodeIfPresent(Int.self, forKey: .uptime)
        tags = try c.decodeIfPresent(String.self, forKey: .tags)
        disk = try c.decodeIfPresent(Int.self, forKey: .disk)
        maxdisk = try c.decodeIfPresent(Int.self, forKey: .maxdisk)
        name = (try? c.decodeIfPresent(String.self, forKey: .name))
            ?? (try? c.decodeIfPresent(String.self, forKey: .node))
            ?? (try? c.decodeIfPresent(String.self, forKey: .storage))
            ?? (try? c.decodeIfPresent(String.self, forKey: .poolname))
            ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(vmid, forKey: .vmid)
        try c.encodeIfPresent(name.isEmpty ? nil : name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(node, forKey: .node)
        try c.encodeIfPresent(maxmem, forKey: .maxmem)
        try c.encodeIfPresent(mem, forKey: .mem)
        try c.encodeIfPresent(maxcpu, forKey: .maxcpu)
        try c.encodeIfPresent(cpu, forKey: .cpu)
        try c.encodeIfPresent(uptime, forKey: .uptime)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(disk, forKey: .disk)
        try c.encodeIfPresent(maxdisk, forKey: .maxdisk)
    }

    public var id: String { "\(type)/\(vmid ?? -1)/\(node ?? "")/\(name)" }
    /// PVE /cluster/resources 의 게스트 type: QEMU→"qemu", LXC→"lxc" (GUI가 "vm"으로 매핑해 보여줄 뿐이다)
    public var isVMKind: Bool { type == "vm" || type == "qemu" }
    public var isGuest: Bool { isVMKind || type == "lxc" }
    public var humanMem: String {
        guard let m = maxmem, m > 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(mem ?? 0), countStyle: .memory) + " / " + ByteCountFormatter.string(fromByteCount: Int64(m), countStyle: .memory)
    }
}

// MARK: - 노드 상세
public struct NodeStatus: Codable {
    public let uptime: Int?
    public let cpu: Double?
    public let cpus: Int?
    public let maxmem: Int?
    public let mem: Int?
    public let loadavg: [String]?
    public let pveversion: String?
    public let ksmshared: Int?
    public let rootfs: FileSystem?
    public let kversion: String?
    public struct FileSystem: Codable {
        public let used: Int?
        public let total: Int?
        public let free: Int?
    }
}

// MARK: - 게스트 상태
public struct GuestStatus: Codable {
    public let status: String?
    public let uptime: Int?
    public let cpu: Double?
    public let cpus: Int?
    public let mem: Int?
    public let maxmem: Int?
    public let swapfree: Int?
    public let maxswap: Int?
    public let netin: Double?
    public let netout: Double?
    public let diskread: Double?
    public let diskwrite: Double?
    public let diskfree: Int?
    public let ha: [String: AnyCodable]?
    public let qmpstatus: String?
}

// MARK: - 태스크
public struct PVETask: Codable, Identifiable {
    public let upid: String
    public let user: String
    public let type: String?
    public let desc: String?
    public let status: String?
    public let node: String?
    public let starttime: Int?
    public let endtime: Int?

    public var id: String { upid }
    public var isRunning: Bool { status == nil || status == "running" || status!.isEmpty }
    public var date: String {
        guard let s = starttime else { return "-" }
        return Date(timeIntervalSince1970: TimeInterval(s)).formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - 스냅샷
public struct Snapshot: Codable, Identifiable {
    public let name: String
    public let vmstate: Int?
    public let description: String?
    public let parent: String?
    public let snaptime: Int?
    public var id: String { name }
}

// MARK: - 스토리지
public struct StorageInfo: Codable, Identifiable, Hashable {
    public let storage: String
    public let node: String
    public let `type`: String
    public let active: Int?
    public let content: String?
    public let used_fraction: Double?
    public let used: Int?
    public let total: Int?
    public let enabled: Int?
    public var id: String { node + "/" + storage }

    public init(storage: String, node: String, type: String,
                active: Int?, content: String?, used_fraction: Double?,
                used: Int?, total: Int?, enabled: Int?) {
        self.storage = storage
        self.node = node
        self.type = type
        self.active = active
        self.content = content
        self.used_fraction = used_fraction
        self.used = used
        self.total = total
        self.enabled = enabled
    }
}

// MARK: - 스토리지 컨텐츠(백업/ISO)
public struct StorageContent: Codable, Identifiable {
    public let volid: String
    public let vmid: Int?
    public let size: Int?
    public let format: String?
    public let notes: String?
    public let creation: Int?
    public var id: String { volid }
}

// MARK: - RRD 모니터링 포인트
public struct RRDPoint: Codable {
    public let t: Double
    public let cpu: Double?
    public let mem: Double?
    public let maxmem: Double?
    public let netin: Double?
    public let netout: Double?
    public let diskread: Double?
    public let diskwrite: Double?
    public let loadavg: Double?
    public let roottotal: Double?
    public let rootused: Double?
    public let uptime: Double?
}

public extension RRDPoint {
    /// PVE rrddata 포인트는 값이 null/누락될 수 있어 JSONDecoder로는 전체 실패한다.
    /// [String: Any]에서 안전하게 숫자만 뽑아 담는다 (null → nil, t 누락 → 0).
    init(fromDict d: [String: Any]) {
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        self.init(t: num("t") ?? 0,
                  cpu: num("cpu"),
                  mem: num("mem"),
                  maxmem: num("maxmem"),
                  netin: num("netin"),
                  netout: num("netout"),
                  diskread: num("diskread"),
                  diskwrite: num("diskwrite"),
                  loadavg: num("loadavg"),
                  roottotal: num("roottotal"),
                  rootused: num("rootused"),
                  uptime: num("uptime"))
    }
}

// MARK: - 임의 JSON 값 (Codable 서류 내 Any 유지용)
public struct AnyCodable: Codable, Hashable {
    public let value: Any
    public init(_ v: Any) { value = v }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else { value = (try? c.decode([String: AnyCodable].self).mapValues(\.value)) ?? NSNull() }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let b = value as? Bool { try c.encode(b) }
        else if let i = value as? Int { try c.encode(i) }
        else if let d = value as? Double { try c.encode(d) }
        else if let s = value as? String { try c.encode(s) }
        else { try c.encodeNil() }
    }
    public static func == (a: AnyCodable, b: AnyCodable) -> Bool { String(describing: a.value) == String(describing: b.value) }
    public func hash(into h: inout Hasher) { h.combine(String(describing: value)) }
}
