import SwiftUI
import ProxmoxKit

// MARK: - 노드 인증서 정보 + ACME 계정 관리
// GET /nodes/{node}/certificates/info · GET/POST/DELETE /cluster/acme/account/{name}
struct CertInfo: Codable, Identifiable {
    public let filename: String?
    public let fingerprint: String?
    public let issuer: String?
    public let notafter: Int?
    public let notbefore: Int?
    public let subject: String?
    public var id: String { filename ?? subject ?? UUID().uuidString }

    var daysLeft: Int {
        guard let n = notafter else { return -1 }
        return (n - Int(Date().timeIntervalSince1970)) / 86400
    }
}

struct ACMEAccount: Codable, Identifiable {
    public let name: String
    public var id: String { name }
}

struct NodeCertificatesView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var certs: [CertInfo] = []
    @State private var accounts: [ACMEAccount] = []
    @State private var notice: String?
    @State private var showAddACME = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("인증서").font(.headline)
                    Spacer()
                    Button("새로고침") { Task { await loadCerts() } }
                }
                ForEach(certs) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: "checkmark.seal")
                                .foregroundStyle(c.daysLeft < 14 ? .orange : .green)
                            Text(c.filename ?? "-").font(.caption.monospaced()).bold()
                            if c.daysLeft >= 0 {
                                Text("만료까지 \(c.daysLeft)일")
                                    .font(.caption2)
                                    .foregroundStyle(c.daysLeft < 14 ? .orange : .secondary)
                                    .padding(2).background(Color.primary.opacity(0.05), in: Capsule())
                            }
                        }
                        Text("주체: \(c.subject ?? "-")").font(.caption)
                        Text("발급자: \(c.issuer?.replacingOccurrences(of: ", CN = ", with: ", CN=") ?? "-")").font(.caption)
                        Text(c.fingerprint ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
                if certs.isEmpty { Text("-").font(.caption) }

                Divider()
                HStack {
                    Text("ACME 계정 (Let's Encrypt 등)").font(.headline)
                    Spacer()
                    Button { showAddACME = true } label: { Label("계정 추가", systemImage: "plus") }
                        .controlSize(.small)
                    Button("새로고침") { Task { await loadACME() } }
                }
                ForEach(accounts) { a in
                    HStack {
                        Image(systemName: "person.badge.key").foregroundStyle(.blue)
                        Text(a.name).font(.body.monospaced())
                        Spacer()
                        Button("삭제", role: .destructive) {
                            Task { await removeAccount(a) }
                        }.controlSize(.small).buttonStyle(.link)
                    }
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
                if accounts.isEmpty { Text("ACME 계정 없음").font(.caption).foregroundStyle(.secondary) }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.red) }
            }
            .padding(14)
        }
        .task { await loadCerts(); await loadACME() }
        .sheet(isPresented: $showAddACME, onDismiss: { Task { await loadACME() } }) {
            ACMEAccountAddSheet()
        }
    }

    private func loadCerts() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/nodes/\(node)/certificates/info")
            guard let arr = raw as? [[String: Any]] else {
                notice = "인증서 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            // subject/pem 등이 딕셔너리로도 오므로 실패해도 목록은 유지
            certs = ((try? JSONDecoder().decode([CertInfo].self, from: json))) ?? []
            notice = nil
        } catch {
            notice = "인증서 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func loadACME() async {
        guard let c = app.client else { return }
        if let raw = try? await c.getJSON("/api2/json/cluster/acme/account") as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) {
            accounts = (try? JSONDecoder().decode([ACMEAccount].self, from: json)) ?? []
        }
    }

    private func removeAccount(_ a: ACMEAccount) async {
        guard let c = app.client else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/cluster/acme/account/\(c.percentEncode(a.name))")
            notice = "ACME 계정 '\(a.name)' 삭제 완료"
            await loadACME()
        } catch {
            notice = (error as? PVEError)?.message ?? "\(error)"
        }
    }
}

struct ACMEAccountAddSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = "default"
    @State private var email = ""
    @State private var directory = "https://acme-v02.api.letsencrypt.org/directory"
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("ACME 계정 추가").font(.headline)
            Form {
                IMEField("계정 이름", text: $name)
                IMEField("연락 이메일 (예: mailto:me@example.com)", text: $email)
                IMEField("ACME 디렉터리 URL", text: $directory)
            }
            .formStyle(.grouped).frame(width: 480, height: 170)
            Text("주의: 생성하려면 약관 동의가 필요하며, PVE는 ag, 방화벽이 443/80 아웃바운드를 허용해야 합니다.")
                .font(.caption2).foregroundStyle(.tertiary).frame(width: 460)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 460).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("추가 (TOS 동의 포함)") }
                }
                .buttonStyle(.borderedProminent).disabled(name.isEmpty || email.isEmpty || busy)
            }
        }
        .padding(20)
    }

    private func add() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        do {
            let f: [String: String] = ["name": name, "contact": email, "directory": directory, "tos_url": "https://letsencrypt.org/documents/lets-encrypt-rsa-end-user-license-v1.3-Nov-12-2024.pdf"]
            _ = try await c.postJSON("/api2/json/cluster/acme/account/\(c.percentEncode(name))", form: f)
            notice = "ACME 계정 생성 완료"
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - Ceph 대시보드 (상태 + 풀)
// GET /nodes/{node}/ceph/status · GET /nodes/{node}/ceph/pools
struct CephPool: Codable, Identifiable {
    public let name: String?
    public let size: Int?
    public let min_size: Int?
    public let pg_num: Int?
    public var id: String { name ?? UUID().uuidString }
}

struct NodeCephView: View {
    let node: String
    @EnvironmentObject var app: AppState
    @State private var health = ""
    @State private var healthDetails: String = ""
    @State private var osds = ""
    @State private var pgs = ""
    @State private var mons = ""
    @State private var pools: [CephPool] = []
    @State private var rawStatus = ""
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Ceph — \(node)").font(.headline)
                    Spacer()
                    Button("새로고침") { Task { await load() } }
                }
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.red)
                }
                statusCard
                Divider()
                Text("풀 (Pools)").font(.headline)
                Table(pools) {
                    TableColumn("이름") { p in Text(p.name ?? "-").monospaced() }
                    TableColumn("복제 개수(size)") { p in Text("\(p.size ?? 0)") }
                    TableColumn("min_size") { p in Text("\(p.min_size ?? 0)") }
                    TableColumn("PG 수") { p in Text("\(p.pg_num ?? 0)") }
                }
                .frame(minHeight: 150)
                Divider()
                DisclosureGroup("원본 상태 JSON") {
                    ScrollView(.horizontal) {
                        Text(rawStatus.isEmpty ? "-" : rawStatus)
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .padding(14)
        }
        .task { await load() }
    }

    @ViewBuilder private var statusCard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(health.isEmpty ? "상태 -" : health,
                      systemImage: health.lowercased() == "health_ok" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(health.lowercased() == "health_ok" ? .green : .orange)
                Text("OSD: \(osds.isEmpty ? "-" : osds)").font(.caption)
                Text("PG: \(pgs.isEmpty ? "-" : pgs)").font(.caption)
                Text("MON: \(mons.isEmpty ? "-" : mons)").font(.caption)
            }
            Spacer()
            if !healthDetails.isEmpty {
                ScrollView {
                    Text(healthDetails)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: 340, maxHeight: 120)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let st = try await c.getJSON("/api2/json/nodes/\(node)/ceph/status")
            guard let stDict = st as? [String: Any] else {
                notice = "Ceph 상태 응답이 객체가 아님"
                return
            }
            let h = stDict["health"] as? [String: Any]
            health = h?["status"] as? String ?? ""
            if let checks = h?["checks"] as? [[String: Any]] {
                healthDetails = checks.compactMap { "\($0["summary"] ?? "")" }.joined(separator: "\n")
            } else { healthDetails = "" }
            if let o = stDict["osdmap"] as? [String: Any], let om = o["osdmap"] as? [String: Any] {
                osds = "전체 \(om["num_osds"] ?? 0) · up \(om["num_up_osds"] ?? 0) · in \(om["num_in_osds"] ?? 0)"
            }
            if let pg = stDict["pgmap"] as? [String: Any] {
                pgs = "전체 \(pg["pgs_total"] ?? 0) · active+clean \(pg["pgs_active_clean"] ?? 0)"
            }
            if let m = stDict["mons"] as? [[String: Any]] {
                mons = m.compactMap { ($0["name"] as? String) }.joined(separator: ", ")
            }
            rawStatus = pretty(st)
            notice = nil

            if let arr = try? await c.getJSON("/api2/json/nodes/\(node)/ceph/pools") as? [[String: Any]],
               let json = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]) {
                pools = ((try? JSONDecoder().decode([CephPool].self, from: json))) ?? []
            }
        } catch {
            notice = "Ceph 조회 실패 (클러스터 미구성 포함): \((error as? PVEError)?.message ?? "\(error)")"
        }
    }
}
