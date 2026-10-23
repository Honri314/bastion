# rule.md — Proxmox Manager 프로젝트 규칙

## 1. 프로젝트 개요
- **앱 이름**: Bastion (배스천) — Proxmox VE 클러스터 관제 도구
- **목표**: Proxmox VE 관리 프로그램 (GUI).
- **플랫폼**:
  - Mac: Swift / SwiftUI 네이티브 앱 → `mac-app/` (배포판: `mac-app/dist/Bastion.app`)
  - Windows: Electron 앱 → `windows-app/` (배포판: `windows-app/dist/Bastion Setup 1.0.0.exe`)
- **아이콘**: `tools/icon/` — 원본 SVG(`icon.html`), 렌더 PNG(`icon-1024.png`), `icon.icns`, Windows용 `windows-app/build/icon.png`
- 공용 벤더 에셋(xterm.js 등)은 `shared/vendor/`에 두고 각 앱에 복사해 사용.

## 2. 디렉터리 구조
```
프록스목스 관리 프로그램/
├── shared/vendor/        # 공용 3rd-party 에셋 (xterm.js, xterm.css, addon-fit.js)
├── mac-app/              # Swift(SwiftUI) 앱 — SwiftPM 프로젝트
│   ├── Package.swift
│   └── Sources/ProxmoxKit/       # API 클라이언트/모델/웹소켓 라이브러리
│   │   └── Resources/            # terminal.html, novnc.html, xterm 에셋
│   └── Sources/ProxmoxManager/   # SwiftUI 화면들
├── windows-app/          # Electron 앱
│   ├── main.js / preload.js
│   ├── renderer/         # index.html, app.js, vendor/
│   └── vnc.html          # VM 그래픽 콘솔 창
├── tools/icon/           # 앱 아이콘 원본/산출물 (SVG, PNG, icns, iconset)
├── rule.md / build.log   # 이 문서와 빌드 기록
└── README.md
```

## 3. Proxmox 연동 규칙 (핵심 프로토콜)
- **인증**: `POST /api2/json/access/ticket` → `PVEAuthCookie` + `CSRFPreventionToken`
  - 변경 요청(POST/DELETE/PUT)에는 반드시 `CSRFPreventionToken` 헤더 포함.
  - 401(티켓 만료) 시 자동 재로그인 1회 시도.
- **TLS**: PVE는 기본적으로 자체 서명 인증서 사용 → 양쪽 앱 모두 "수용"(accept) 처리.
  - Mac: URLSession delegate에서 `serverTrust` 수용 (PVEClient).
  - Windows: `app.commandLine.appendSwitch('ignore-certificate-errors')` + Node https `rejectUnauthorized:false`.
  - 보안상 내부(NAT/LAN) 환경 권장.
- **콘솔(셸) 프로토콜 — termproxy/vncwebsocket (binary, subprotocol `binary`)**:
  1. `POST /nodes/{node}[/{lxc|qemu}/{vmid}]/termproxy` → `{ user, ticket, port }`
  2. WS `/api2/json/nodes/{node}/vncwebsocket?port=..&vncticket=..` (Cookie + `Sec-WebSocket-Protocol: binary`)
  3. 첫 프레임: `"{user}:{ticket}\n"` → 서버 응답 `OK`
  4. 리사이즈: `"1:{cols}:{rows}:"` , 입력: `"0:{len}:{data}"`, 킵얼라이브 30초: `"2"`
- **VM 그래픽 콘솔(VNC)**:
  1. `POST /nodes/{node}/qemu/{vmid}/vncproxy` `{websocket: 1}`
  2. 동일 vncwebsocket 핸드셰이크(인증 프레임) → 이후 RFB(noVNC) 데이터는 순수 바이너릭 릴레이.
- **API 토큰 제한**: `/vncwebsocket`은 API 토큰(`!` 포함 사용자)으로 인증 불가 — 반드시 비밀번호 세션(tticket) 사용.
- **자동 갱신**: 클러스터 리소스는 5초 간격 폴링 (`/cluster/resources`).
- **태스크 폴링**: UPID로 `GET /nodes/{node}/tasks/{upid}/status`를 0.5초 간격 폴링.

## 4. 코딩/설계 규칙
- Swift:
  - API 로직은 `ProxmoxKit` 모듈, UI는 `ProxmoxManager` 모듈로 분리.
  - UI 코드는 환경(`@EnvironmentObject app: AppState`)으로 상태 공유, 네트워크는 async/await.
  - WKWebView 임베디드 페이지는 직접 네트워크 금지 → Swift URLSession(TLS 수용) 경유 브릿지.
- Electron:
  - 메인(main.js)에서만 네트워크/웹소켓 처리, renderer는 IPC로만 통신 (contextIsolation 유지).
- 데이터 모델: PVE 응답은 타입이 혼합되므로 목록은 Decodable 구조체 + 코드로 JSON 유연 처리 혼용.
- 사용자 대상 UI 문구: 한국어.

## 5. 리트리뷰/빌드 규칙
- 모든 기능 구현 후:
  - Mac: `cd mac-app && swift build` — 에러 0이어야 함.
  - Windows: `node --check main.js && node --check preload.js && node --check renderer/app.js` + Electron 스모크 런치.
- 변경 기록은 반드시 `build.log`에 남긴다(시각/명령/결과/원인).  
- 신규 기능 추가 시 본 문서(rule.md)의 규칙 준수 여부를 확인 후 커밋.

## 6. 기타
- 비밀번호는 메모리에만 보관(자동 재로그인용), 파일/설정에는 저장하지 않음. 주소/포트/사용자만 저장.
- 실행 방법은 README 참조.
