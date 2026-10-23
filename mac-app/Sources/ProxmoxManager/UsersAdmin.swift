import SwiftUI
import ProxmoxKit

// MARK: - 사용자 수정 시트
struct UserEditSheet: View {
    var user: PVEUser
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var email = ""
    @State private var enable = true
    @State private var newPassword = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("사용자 편집 — \(user.userid)").font(.headline)
            Form {
                IMEField("설명", text: $comment)
                IMEField("이메일", text: $email)
                Toggle("활성", isOn: $enable)
                IMEField("새 비밀번호 (비우면 변경 안 함)", secure: true, text: $newPassword)
            }
            .formStyle(.grouped).frame(width: 400, height: 200)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 380).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("저장") }
                }
                .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .padding(20)
        .onAppear {
            comment = user.comment ?? ""
            enable = (user.enable ?? 1) != 0
        }
    }

    private func save() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        var f: [String: String] = ["enable": enable ? "1" : "0"]
        if comment != (user.comment ?? "") { f["comment"] = comment }
        if !email.isEmpty { f["email"] = email }
        if !newPassword.isEmpty { f["password"] = newPassword }
        do {
            _ = try await c.putJSON("/api2/json/access/users/\(c.percentEncode(user.userid))", form: f)
            notice = "사용자 수정 완료"
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - API 토큰 탭
struct APIToken: Codable, Identifiable {
    public let tokenid: String
    public let comment: String?
    public let expire: Int?
    public let privsep: Int?
    public var id: String { tokenid }
}

struct TokensView: View {
    @EnvironmentObject var app: AppState
    @State private var users: [String] = []
    @State private var selectedUser = ""
    @State private var tokens: [APIToken] = []
    @State private var notice: String?
    @State private var showCreate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("사용자", selection: $selectedUser) {
                    Text("-").tag("")
                    ForEach(users, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: selectedUser) { _ in Task { await loadTokens() } }
                .frame(width: 240)
                Text("API 토큰 \(tokens.count)개").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showCreate = true } label: { Label("토큰 생성", systemImage: "plus") }
                    .controlSize(.small).disabled(selectedUser.isEmpty)
                Button("새로고침") { Task { await loadAll() } }
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            Table(tokens) {
                TableColumn("토큰 ID") { t in Text(t.tokenid).monospaced() }
                TableColumn("설명") { t in Text(t.comment ?? "") }
                TableColumn("권한분리") { t in Text((t.privsep ?? 0) == 0 ? "없음(토큰=사용자)" : "있음") }
                TableColumn("만료") { t in
                    Text(t.expire.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted) } ?? "만료 없음")
                }
                TableColumn("") { t in
                    Button("삭제", role: .destructive) {
                        Task { await remove(t) }
                    }.controlSize(.small).buttonStyle(.link)
                }
            }
        }
        .task { await loadAll() }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await loadTokens() } }) {
            TokenCreateSheet(userid: selectedUser)
        }
    }

    private func loadAll() async {
        guard let c = app.client else { return }
        if let raw = try? await c.getJSON("/api2/json/access/users?full=1") as? [[String: Any]] {
            users = raw.compactMap { $0["userid"] as? String }
            if selectedUser.isEmpty, let first = users.first { selectedUser = first }
        }
        await loadTokens()
    }

    private func loadTokens() async {
        guard let c = app.client, !selectedUser.isEmpty else { return }
        // tokenid 비우면 해당 사용자의 토큰 목록 반환
        let path = "/api2/json/access/users/\(c.percentEncode(selectedUser))/token/"
        if let raw = try? await c.getJSON(path) as? [[String: Any]],
           let json = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) {
            tokens = (try? JSONDecoder().decode([APIToken].self, from: json)) ?? []
        } else {
            tokens = []
        }
    }

    private func remove(_ t: APIToken) async {
        guard let c = app.client else { return }
        do {
            _ = try await c.deleteJSON("/api2/json/access/users/\(c.percentEncode(selectedUser))/token/\(c.percentEncode(t.tokenid))")
            notice = "토큰 '\(t.tokenid)' 삭제 완료"
            await loadTokens()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

struct TokenCreateSheet: View {
    let userid: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tokenid = ""
    @State private var comment = ""
    @State private var privsep = false
    @State private var expireDays = ""
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("API 토큰 생성 — \(userid)").font(.headline)
            Form {
                IMEField("토큰 ID (예: automation)", text: $tokenid)
                IMEField("설명", text: $comment)
                Toggle("권한 분리 (privsep)", isOn: $privsep)
                IMEField("만료일 수 (비우면 무기한)", text: $expireDays)
            }
            .formStyle(.grouped).frame(width: 420, height: 190)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 400).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("생성") }
                }
                .buttonStyle(.borderedProminent).disabled(tokenid.isEmpty || busy)
            }
        }
        .padding(20)
    }

    private func add() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        var f: [String: String] = ["privsep": privsep ? "1" : "0"]
        if !comment.isEmpty { f["comment"] = comment }
        if let d = Int(expireDays.trimmingCharacters(in: .whitespaces)), d > 0 {
            f["expire"] = String(Int(Date().timeIntervalSince1970) + d * 86400)
        }
        do {
            _ = try await c.postJSON("/api2/json/access/users/\(c.percentEncode(userid))/token/\(c.percentEncode(tokenid))", form: f)
            notice = "토큰 생성 완료"
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 그룹 탭
struct PVEGroup: Codable, Identifiable {
    public let groupid: String
    public let comment: String?
    public let users: String?
    public var id: String { groupid }
}

struct GroupsView: View {
    @EnvironmentObject var app: AppState
    @State private var groups: [PVEGroup] = []
    @State private var notice: String?
    @State private var showAdd = false
    @State private var editing: PVEGroup?
    @State private var busyID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("그룹 \(groups.count)개").font(.headline)
                Spacer()
                Button { showAdd = true } label: { Label("그룹 추가", systemImage: "plus") }.controlSize(.small)
                Button("새로고침") { Task { await load() } }
            }
            .padding(10)
            Divider()
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).padding(8) }
            List(groups) { g in
                HStack {
                    Image(systemName: "person.2.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.groupid).font(.body.monospaced()).bold()
                        Text("구성원: \(g.users?.isEmpty == false ? (g.users ?? "-") : "없임")\(g.comment.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("편집") { editing = g }.controlSize(.small).buttonStyle(.link)
                    Button("삭제", role: .destructive) {
                        Task { await remove(g) }
                    }.controlSize(.small).buttonStyle(.link).disabled(busyID == g.groupid)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
            GroupEditSheet(existing: nil)
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { g in
            GroupEditSheet(existing: g)
        }
    }

    private func load() async {
        guard let c = app.client else { return }
        do {
            let raw = try await c.getJSON("/api2/json/access/groups")
            guard let arr = raw as? [[String: Any]] else {
                notice = "그룹 응답이 배열이 아님"
                return
            }
            let json = try JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed])
            groups = (try? JSONDecoder().decode([PVEGroup].self, from: json)) ?? []
            notice = nil
        } catch {
            notice = "그룹 조회 실패: \((error as? PVEError)?.message ?? "\(error)")"
        }
    }

    private func remove(_ g: PVEGroup) async {
        guard let c = app.client else { return }
        busyID = g.groupid
        defer { busyID = nil }
        do {
            _ = try await c.deleteJSON("/api2/json/access/groups/\(c.percentEncode(g.groupid))")
            notice = "그룹 '\(g.groupid)' 삭제 완료"
            await load()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

struct GroupEditSheet: View {
    var existing: PVEGroup?
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var groupid = ""
    @State private var comment = ""
    @State private var usersText = ""   // 쉼표 구분 userid 목록
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text(existing == nil ? "그룹 추가" : "그룹 편집 — \(existing?.groupid ?? "")").font(.headline)
            Form {
                IMEField("그룹 ID", text: $groupid).disabled(existing != nil)
                IMEField("설명", text: $comment)
                IMEField("구성원 (쉼표 구분 userid)", text: $usersText)
            }
            .formStyle(.grouped).frame(width: 420, height: 180)
            if let notice { Text(notice).font(.footnote).foregroundStyle(.red).frame(width: 400).lineLimit(3) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(existing == nil ? "추가" : "저장") }
                }
                .buttonStyle(.borderedProminent).disabled(groupid.isEmpty || busy)
            }
        }
        .padding(20)
        .onAppear {
            if let e = existing {
                groupid = e.groupid
                comment = e.comment ?? ""
                usersText = e.users ?? ""
            }
        }
    }

    private func save() async {
        guard let c = app.client else { return }
        busy = true; defer { busy = false }
        var f: [String: String] = [:]
        if !comment.isEmpty { f["comment"] = comment }
        if !usersText.isEmpty {
            f["users"] = usersText.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ",")
        }
        do {
            if existing != nil {
                _ = try await c.putJSON("/api2/json/access/groups/\(c.percentEncode(groupid))", form: f)
            } else {
                f["groupid"] = groupid
                _ = try await c.postJSON("/api2/json/access/groups", form: f)
            }
            notice = "저장 완료"
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch { notice = (error as? PVEError)?.message ?? "\(error)" }
    }
}

// MARK: - 사용자 삭제 (MoreFeatures.swift의 UsersView에 통합)
// deleteUser는 UsersView 내부 private 멤버 접근이 필요해 MoreFeatures.swift 쪽에 둔다.
