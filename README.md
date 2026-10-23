# Bastion (프록스목스 관리 프로그램)

Proxmox VE 클러스터를 관제하는 크로스 플랫폼 GUI 앱 — **Bastion**.

| 플랫폼 | 기술 | 위치 |
|---|---|---|
| macOS | Swift / SwiftUI (네이티브) | `mac-app/` |
| Windows | Electron | `windows-app/` |

## 주요 기능 (양쪽 동일)
- 로그인 (PVEAuthCookie 세션, 2FA OTP 지원, 자체 서명 인증서 수용)
- **여러 Proxmox 인스턴스(서버 프로필) 전환 관리** — 프로필 선택/추가/삭제
- **비밀번호 저장** — macOS 키체인 / Windows OS 보안 스토리지(DPAPI, safeStorage)로 암호화 보관, 프로필 재선택 시 자동 채움
- 클러스터/노드/VM/LXC 실시간 목록 (5초 폴링) + 검색/태그
- 게스트 전원 액션: 시작/정지/재시작/셧다운/리셋/일시정지/재개
- 모니터링: 노드·게스트 CPU/메모리/네트워크/디스크 RRD 그래프
- 스냅샷: 생성 / 롤백 / 삭제
- 백업: vzdump 즉시 실행 (모드/압축 선택) + 백업 파일 목록
- 스토리지 현황 + 볼륨(백업/ISO) 목록
- 태스크(작업) 로그 + 진행 상태
- **셸 콘솔**: 노드 셸 / LXC 콘솔 / VM 시리얼 (termproxy + xterm.js)
- **VM 그래픽 콘솔**: noVNC (VNC websocket + RFB 릴레이)
- **API 탐색기**: 모든 PVE API 엔드포인트를 직접 호출 (폼 파라미터 지원)
- 자동 재로그인: 티켓 만료(2시간) 시 자동 갱신

## macOS 실행
```bash
cd mac-app
swift run          # 요구 사항: macOS 13+, Xcode CLI (Swift 5.9+)
```
> 패키징된 앱: `mac-app/dist/Bastion.app` (더블클릭으로 바로 실행 가능)

## Windows 실행
```bat
cd windows-app
npm install
npm start
```
> 요구 사항: Node.js 18+ (Electron 설치 포함). noVNC 콘솔은 CDN에서 로드하므로 인터넷 연결 필요.
> 배포용 빌드: `npm run build` (NSIS 인스톨러 대상, Windows 환경에서 실행)
> 설치파일: `windows-app/dist/Bastion Setup 1.0.0.exe` / 포터블: `win-unpacked/`
> 아이콘: `tools/icon/` (원본 SVG는 `icon.html`, 렌더 PNG는 `icon-1024.png`)

## 보안 주의사항
- PVE 기본이 자체 서명 인증서여서, 양쪽 앱 모두 **인증서 경고를 수용**하고 있습니다.
  공인 인증서 환경이면 각 설정 지점(`PVEClient.swift`의 `insecureTLS`, `main.js`의 `ignore-certificate-errors`)을 비활성화하세요.
- 비밀번호 저장을 켜면 OS 보안 스토리지(macOS 키체인 / Windows DPAPI)에만 암호화 저장됩니다 (평문 파일 저장 없음). 끄면 로그인 시점마다 입력 필요.
- 내부(신뢰할 수 있는 LAN) 환경에서 사용을 권장합니다.

## 문서
- `rule.md`: 프로젝트 구조/코딩 규칙/Proxmox 프로토콜 정리
- `build.log`: 빌드·검증 이력

## 알려진 제한
- VM 그래픽 콘솔(noVNC)은 cdn.jsdelivr 네트워크 필요 (오프라인 불가).
- Ceph/방화벽/ACME 등 데이터센터 고급 관리 UI는 API 탐색기로 대체 가능.
- 실제 클러스터에 연결한 E2E 테스트는 아직 수행되지 않음(빌드/런치 검증만 완료) — `build.log` 참조.
