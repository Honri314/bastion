# Bastion — Proxmox VE 관리 프로그램

Proxmox VE 클러스터를 관제하는 크로스 플랫폼 GUI 앱입니다. macOS는 Swift/SwiftUI 네이티브로, Windows는 Electron으로 개발되었으며 양쪽이 동일한 기능 세트를 제공합니다.

| 플랫폼 | 기술 | 위치 |
|---|---|---|
| macOS | Swift 5.9 / SwiftUI, 외부 의존성 0개 | `mac-app/` |
| Windows | Electron 33 + `ws` (WebSocket 통신용) | `windows-app/` |

## 다운로드 / 웹
- 웹: https://ubuntu.tail543772.ts.net/bastion
- 릴리스: https://github.com/Honri314/bastion/releases (Windows Setup.exe)

## 주요 기능

### 세션·인스턴스 관리
- PVEAuthCookie 티켓 방식 로그인 (PAM / PVE / 사용자 정의 realm 선택, 2FA TOTP OTP 지원)
- **여러 Proxmox 인스턴스(서버 프로필) 전환** — 프로필 목록 관리(추가/삭제/선택), 재선택 시 자동 로그인
- **비밀번호 안전 저장** — macOS는 키체인(Keychain), Windows는 safeStorage(DPAPI)로 OS 수준 암호화 보관. 코드/설정파일에 평문 저장 없음
- 티켓 만료(401) 시 자동 재로그인 1회. 재귀 무한루프 방지 로직 내장(`allowReauth` 플래그)
- 자체 서명 인증서 수용 (PVE 기본 구성 대응)

### 클러스터 관제
- 클러스터/노드/VM/LXC 실시간 목록 — 기본 5초 폴링, 개별 리소스 파싱 실패 시에도 나머지 유지(전체 실패 방지)
- 클러스터명/마스터 감지, 검색·태그 필터
- 게스트 전원 액션: 시작 / 정지 / 재시작 / 셧다운 / 리셋 / suspend / resume
- 노드 전원·서비스(start/stop/restart) 제어와 시스템 정보(업타임, 커널, PVE 버전, KVM/CPU 지원, 업데이트)

### 모니터링
- 노드·게스트 CPU/메모리/네트워크/디스크 RRD 그래프 (hourly/daily/weekly/monthly 구간 선택)
- 실시간 상태 배지(status, uptime, agents, hibernate 등)

### 게스트 관리
- 하드웨어 편집(CPU/메모리/디스크/네트워크), VM 생성 마법사, LXC 생성
- 스냅샷 생성/롤백/삭제
- 백업: vzdump 즉시 실행(모드 snapshot/suspend/stop, 압축 zstd/lzo/gzip/0) + 백업 파일 목록 조회
- 게스트별 방화벽 규칙 보기/편집

### 스토리지·인프라
- 스토리지 현황(타입별 용량/사용률), 볼륨(백업/ISO/컨테이너 템플릿) 목록과 세부 내용
- 스토리지 관리(추가/편집/활성화), 업로드/다운로드(ISO·템플릿 URL 다운로드)
- Ceph 상태/풀/OSD 확인, Ceph 풀 생성
- 방화벽: 클러스터/노드/게스트 3단계 규칙 관리, 규칙 시트(포트/프로토콜/소스/대상/동작/주석), 옵션(input/output 정책 등), IP셋/별칭/보안그룹 관리

### 사용자·시스템
- 사용자/그룹/권한 관리, API 토큰 발급/관리
- ACME 계정 추가(pem 방식, Let's Encrypt 연동 안내 포함), 인증서 관리
- 작업(Task) 로그와 진행 상태 확인, UPID 파싱으로 상태 추적
- 도움말/정보 패널(프로그램 정보, 서버 상태 요약)

### 콘솔
- **노드 셸 / LXC 콘솔 / VM 시리얼 콘솔** — `termproxy` + `vncwebsocket` 프로토콜을 직접 구현해 xterm.js로 임베드
- **VM VNC 콘솔** — noVNC를 WKWebView로 임베드, 연결 로그 패널(메뉴바 콘솔 메뉴에서 토글, Cmd+Shift+L)
- 셸/콘솔은 독립 창으로 열림 (여러 대상 동시 오픈 가능)

## macOS 앱 아키텍처

SwiftPM 기반 2개 모듈:

```
mac-app/Sources/
  ProxmoxKit/       API·프로토콜 계층 (UI 미포함, Tests 있는 유일 모듈)
  ProxmoxManager/   SwiftUI UI 계층
```

### ProxmoxKit (API·프로토콜 계층)
| 파일 | 역할 |
|---|---|
| `PVEClient.swift` | PVE REST API 래퍼. PVEAuthCookie/CSRF 토큰 부착, form 인코딩, 401 시 자동 재로그인(1회 한정, 무한 재귀 방지), URLSessionDelegate로 자체서명 인증서 수용 |
| `Models.swift` | `ClusterResource` 등 디코딩 모델. API 응답 형태가 다양해 관대한 파싱 전략 사용 |
| `Profiles.swift` | 서버 프로필 CRUD (호스트/포트/사용자/realm/비밀번호) — 비밀번호는 키체인 저장 |
| `TermService.swift` | 콘솔(노드 셸/LXC/VM 시리얼) 세션: termproxy 응답의 `user/ticket/port`로 `vncwebsocket` 연결 → 첫 프레임 `user:ticket\n` 인증("OK" 확인) → 리사이즈 `1:cols:rows:` → 입력 `0:len:data` → 30초 간격 킵얼라이브 `2` |
| `RFBWebSocket.swift` | **RFC 6455를 직접 구현한 WebSocket**. URLSessionWebSocketTask는 `Sec-WebSocket-Protocol: binary` 등 커스텀 헤더가 유실될 수 있어 PVE `vncwebsocket`이 1006으로 거부하는 문제가 있음 → Network.framework(NWConnection) 위에 핸드셰이크/프레임 파싱(연속/분할 프레임 조립, ping/pong, close 코드 해석, 클라이언트 마스킹)을 직접 처리 |
| `TermService.swift` 내 URLSession | 분할 프레임 조립·읽기 루프, 30초 킵얼라이브 태스크 |
| Resources/ | `terminal.html`(xterm.js 콘솔 UI, base64 브릿지), `xterm.js`, `addon-fit.js`(자동 맞춤), `novnc.html`, `noVNC.js`(번들된 noVNC) |

### ProxmoxManager (SwiftUI UI 계층)
| 파일 | 역할 |
|---|---|
| `App.swift` | @main 앱. AppState(세션·폴링 타이머·콘솔 창 요청 큐)와 창 3종(메인/셸/VM콘솔), 콘솔 메뉴바 |
| `Views.swift` | 로그인 화면(realm 선택, 2FA, 포트 입력, 자체서명 안내), 메인 3분할 레이아웃(사이드바+목록+상세) |
| `NodeSystem.swift` | 노드 상세 — 시스템 정보, 요약/RRD 그래프, 서비스 제어, 업데이트 |
| `NodeDetail.swift` / `NodeOps.swift` | 노드 목록 상세 요약, 전원/작업 |
| `GuestsSystem.swift` | 게스트 목록(검색/태그/정렬) + 게스트 상세 |
| `GuestDetail.swift`, `GuestOps.swift`, `GuestHardware.swift`, `GuestCreate.swift` | 게스트 전원 작업, 하드웨어 편집, VM/LXC 생성 |
| `Snapshots.swift` | 스냅샷 생성/롤백/삭제 UI |
| `StorageView.swift`, `StorageAdmin.swift` | 스토리지 현황/볼륨/ISO, 스토리지 설정 |
| `FirewallRuleSheet.swift`, `FirewallExtra.swift`, `GuestFirewallView.swift` | 방화벽 규칙 편집 UI, IP셋/별칭/보안그룹, 게스트 방화벽 |
| `CertsAndCeph.swift` | ACME 계정/인증서, Ceph 상태와 풀 관리 |
| `UsersAdmin.swift` | 사용자/그룹/권한/API 토큰 |
| `MoreFeatures.swift` | 백업 잡, 태스크 로그, API 응답 탐색기 등 |
| `TerminalViews.swift`, `FeaturePanels.swift` | 셸/VNC 창 SwiftUI 임베드(WebKit), 기능 패널 |

### 방어적 파싱 전략
- PVE API는 버전/커뮤니티 확장에 따라 응답 필드가 달라질 수 있어, 개별 항목 디코드 실패 시 나머지 유지 + 실패 타입 목록을 로그로 안내합니다.
- 프레임 사이즈 상한(50MB) 검사, close 프레임 코드 해석 등 프로토콜 오류를 앱 내 콘솔 로그로 보여줍니다.

## Windows 앱 (Electron)

```
windows-app/
  main.js       PVE REST 래퍼(https, Cookie/CSRF, 401 자동 재로그인), IPC 핸들러,
                WebSocket 셸(V2 단일 세션), 프로필 CRUD(safeStorage 암호화)
  preload.js    컨텍스트브리지로 renderer에 안전 API 노출
  renderer/     UI(목록/상세/그래프/설정), app.js
  vnc.html      noVNC 임베드 콘솔
  vnc-app/      vnc 콘솔 서브 앱 소스
```
- 비밀번호: Electron `safeStorage`(DPAPI) 기반 암호화 후 프로필에 저장
- 자체서명 인증서: `ignore-certificate-errors` 스위치 + `rejectUnauthorized: false`
- 셸: node `ws` 라이브러리로 termproxy/vncwebsocket 프로토콜 구현(macOS의 HandWebSocket과 동일 프로토콜)
- 빌드: `npm run build` (electron-builder, NSIS 설치 프로그램)

## 빌드 (macOS)

```
cd mac-app
swift build            # 개발 빌
swift run              # 실행
swift test             # ProxmoxKitTests (JSON 디코딩 회귀 테스트)
swift build -c release # 배포용
```
외부 의존성이 없어 Swift 툴체이만 있으면 빌드됩니다. UI 계층은 NSImage/WKWebView 등 AppKit API를 사용하므로 macOS 13+ 권한입니다.

## 빌드 (Windows)
```
cd windows-app
npm install
npm start              # 개발 실행
npm run build          # NSIS 설치 파일 생성 (dist/)
```

## 보안 노트
- 비밀번호는 절대 평문으로 설정파일에 저장하지 않습니다(macOS 키체인 / Windows safeStorage).
- PVE 비밀번호는 401 자동 재로그인 용도로만 프로세스 메모리에 존재하고, 로그아웃 시 함께 삭제됩니다.
- 기여자 커밋 서명은 GitHub noreply 이메일(개인정보 노출 아님)을 씁니다.

## 라이선스
사개 프로젝트로 배포됩니다 (라이선스 명시 요청 시 추가).
