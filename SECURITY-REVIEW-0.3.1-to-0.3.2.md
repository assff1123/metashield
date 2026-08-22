# MetaShield 0.3.1 외부 보안 검증 결과

검증일: 2026-08-22
검증자: 독립 검토 (Claude Code)
대상:
- 배포물 `outputs/MetaShield-0.3.1-direct.dmg` (SHA-256 `75ae3b9f…40cf6`)
- 설치본 `/Applications/MetaShield.app` (0.3.1, build 14)
- 설치된 빠른 동작 `~/Library/Services/MetaShield 메타데이터 완전 제거.workflow`
- 소스 `Sources/` 전체 (3,204 줄)

## 수정 반영 상태 (2026-08-22, 0.3.2)

이 보고서의 F1·F5·F6 은 **0.3.2 (build 15) 에서 코드로 수정**했고, F3·F4 와 F2 의 경고 문구는
문서에 반영했습니다. 재검증 결과는 문서 끝의 "0.3.2 재검증" 절에 있습니다.
남은 필수 항목은 F8(LICENSE·지원 연락처·보안 신고 주소)뿐입니다.

## 종합 판정 (0.3.1 기준)

**조건부 배포 가능 (베타 표시 필수).** 시스템 보안 관점의 취약점(권한 상승, 코드 실행,
경로 조작, 임의 파일 쓰기, 네트워크 유출)은 발견되지 않았습니다. 배포 차단 수준의
결함은 없으나, **제품이 문서에서 주장하는 "알파 LSB 은닉 데이터 제거"는 공격자가
의도적으로 만든 이미지에 대해서는 성립하지 않습니다.** 코드를 고치거나 주장 문구를
수정해야 합니다. 그 외에는 법적·지원 문서 공백이 남아 있습니다.

## 설치 경로와 파일 목록

| 경로 | 내용 |
|---|---|
| `/Applications/MetaShield.app` | 앱 번들 (jiho:staff, 755) |
| `└ Contents/MacOS/MetaShield` | 호스트 앱 883,952 B, Universal 2 |
| `└ Contents/Resources/metashield-cli` | CLI 431,184 B, Universal 2 |
| `└ Contents/Resources/MetaShieldQuickAction.workflow` | Automator 빠른 동작 원본 |
| `└ Contents/Resources/AppIcon.icns` | 아이콘 1,125,429 B |
| `└ Contents/PlugIns/MetaShield Share.appex` | 공유 확장 630,720 B, sandbox |
| `~/Library/Services/MetaShield 메타데이터 완전 제거.workflow` | 설치된 빠른 동작 (0.3.1/14, 번들본과 바이트 동일) |
| `~/Library/Preferences/kr.metashield.app.plist` | NSOpenPanel 마지막 폴더 북마크만 저장 |
| `~/Library/Containers/kr.metashield.app.share` | 공유 확장 샌드박스 컨테이너 |

pkgutil 수신 기록 없음(드래그 설치), 실행 중 프로세스 없음, LaunchAgent/Daemon 없음.

## 무결성 검증 (통과)

- DMG SHA-256 이 동봉 `.sha256` 와 일치.
- `hdiutil verify` CRC 전부 유효, DMG 자체 ad-hoc 서명 유효.
- **DMG 내부 앱과 설치본이 `diff -r` 로 완전히 동일** — 설치본 변조 없음.
- `codesign --verify --deep --strict` 통과, 중첩 서명(appex·CLI) 정상, Designated Requirement 충족.
- `spctl` 은 예상대로 `rejected` (공증 없음, 문서와 일치).
- 앱·CLI·appex 모두 `flags=0x10002(adhoc,runtime)`, Hardened Runtime 적용,
  `com.apple.security.cs.*` 완화 entitlement 없음, library validation 유효.
- entitlement: 호스트 = photos-library 만, appex = app-sandbox + photos-library. 최소 권한 준수.
- Universal 2 (arm64/x86_64), `minos 13.0` 로 LSMinimumSystemVersion 과 일치.
- 링크된 라이브러리는 Apple 시스템 프레임워크와 `libz` 뿐. **네트워크 프레임워크·소켓 심볼 0개.**
- 바이너리에 `/Users/…` 등 빌드 머신 경로 문자열 없음(개발자 정보 유출 없음), DMG 에 `.DS_Store` 등 불필요 파일 없음.
- 공식 스크립트 `scripts/verify-direct-dmg.sh` 및 자체 테스트 14/14 재현 성공.

## 동적 취약점 시험 결과

직접 제작한 악성 PNG 코퍼스와 설치된 CLI(코어 로직 동일)로 시험했습니다.

| 시험 | 결과 |
|---|---|
| tEXt·zTXt·iTXt(XMP)·eXIf·비표준 청크·IEND 뒤 트레일러 삽입 | 전부 제거, 출력은 IHDR/IDAT/IEND 만 |
| xattr(kMDItemComment, user.*, **com.apple.quarantine**) | 전부 제거 (아래 F3 참고) |
| POSIX 권한 0640 보존 | 보존됨 |
| JPEG EXIF(GPS 문자열)·COM 주석 | `.clean.png` 에 흔적 없음, Spotlight 속성도 null |
| 압축 폭탄(60000×60000, 69 B) | 거부 |
| APNG(다중 프레임) | 거부 |
| 심볼릭 링크 / 하드 링크 | 각각 거부 |
| 한글·공백·작은따옴표·`$var` 파일명 | 정상 처리 (빠른 동작 스크립트는 `"$@"` 로 안전) |
| 16-bit RGBA, 팔레트+tRNS | 정상 처리 |
| 처리 중 원본 truncate (5회 × 5구간, 119 MB 입력) | SIGBUS 없음, `sourceChangedDuringProcessing` 로 실패 안전 |
| 실패 후 `.metashield-*` 임시 파일 잔존 | 없음 |
| 40 MP(6300×6300) 비압축성 입력 | 4.8 초, **최대 RSS 1.37 GB** (아래 F4) |

## 발견 사항

### F1. (중) 알파 채널 은닉 데이터가 파괴되지 않고 RGB 로 이전됨

`ImageSanitizer.makeCanonicalPNG` 는 `quantizedAlpha` 로 알파를 16단계로 뭉갠 뒤
흰색에 합성하지만, **premultiplied 값에서 straight 색을 복원할 때 원본 알파를
그대로 나눗셈에 사용**합니다 (`ImageSanitizer.swift:256`).
그 결과 알파의 하위 비트가 출력 RGB 에 ±1 잡음으로 각인됩니다.

재현 (PoC):
- 64×64, 색상 고정 `(123,200,77)`, 알파를 8/9 로 번갈아 심어 24 바이트 메시지 인코딩
- MetaShield 로 정리 후 출력 PNG 의 RGB 만으로 `ALPHA_LSB_SURVIVES_0.3.1` **100% 복원**
- 알파 0–255 스윕: 256 단계가 81 개의 서로 다른 출력색으로 남음
- 알파 248–255(전부 불투명 처리 구간)에서도 256 색 중 23 색이 알파 값을 그대로 노출

현실적 영향은 제한적입니다. 무작위 자연색 + 알파 254/255(NovelAI stealth 방식)로 시험하면
992 비트 중 12 비트(1.2%)만 흔적이 남아 실제 payload 복원은 불가능했습니다.
그러나 **공격자가 색과 알파 쌍을 고르면 1 픽셀당 1 비트가 온전히 살아남습니다.**

따라서 `AUDIT.md` 의 "알파/알파 LSB … 운반면 제거 — 통과" 와 Info.plist 서비스 설명의
"알파 채널 기반 은닉 데이터를 제거합니다" 는 적응형 공격자에 대해 사실이 아닙니다.

권고(둘 중 하나):
1. 근본 수정 — premultiplied 왕복을 없애고 vImage(`vImage_CGImageFormat` + `CGImageAlphaInfo.last`)
   로 straight RGBA 를 그대로 받아, 양자화된 알파만으로 합성합니다. 그러면 출력은
   양자화 버킷(4비트)에만 의존하고 알파 LSB 채널은 사라집니다.
2. 최소 조치 — 주장 문구를 "알파 채널 자체와 알파 기반 컨테이너 데이터를 제거하지만,
   보이는 픽셀로 옮겨 심는 적응형 은닉은 보장하지 않습니다" 로 수정.

어느 쪽이든 자체 테스트에 "알파 LSB payload 복원 불가" 회귀 시험을 추가해야 합니다.
현재 테스트(`main.swift:194`)는 알파 채널 유무만 확인합니다.

### F2. (저·설계) 확인 없는 무음 원본 파괴가 모든 로컬 프로세스에 노출

`open -a MetaShield <경로>` 한 번으로 창·확인·소리 없이 PNG 원본이 되돌릴 수 없게
교체되는 것을 실측했습니다(0.5 초 내 799 B → 275 B, 프로세스는 즉시 종료).
Services 항목도 동일합니다. 빠른 동작 헤드리스 동작을 위한 의도된 설계지만, 결과적으로
로컬에서 코드를 실행할 수 있는 임의의 프로세스가 사용자 사진을 조용히 재인코딩·손상시킬 수
있는 "무음 파일 변조 서비스"가 상시 등록됩니다. 백업본 없음.

권고: 최소한 원위치 교체 전 원본을 휴지통(`trashItem`)으로 옮기는 옵션을 기본값으로
제공하고, 설치 안내에 "PNG 원위치 교체는 되돌릴 수 없음"을 눈에 띄게 명시.

### F3. (정보) com.apple.quarantine 이 함께 제거됨

원위치 교체 시 다운로드 출처 표시인 `com.apple.quarantine` 이 사라집니다(실측).
이미지 파일이라 실행 위험은 없고 새 파일을 만드는 구조상 자연스러운 결과지만,
`PRIVACY.md` 가 보존 대상으로 언급한 것은 `com.apple.provenance`·`com.apple.macl` 뿐이므로
격리 속성 제거 사실을 문서에 명시하는 편이 정확합니다.

### F4. (저) 문서화된 자원 상한이 최악값을 2배 과소평가

`AUDIT.md` 는 40 MP 처리 시 최대 RSS 약 656 MB 로 기록했지만, 비압축성 119 MB / 40 MP
입력에서는 **1.37 GB (peak footprint 923 MB)** 를 측정했습니다. 8 GB 램 기기에서
스와핑 가능성이 있습니다. 호스트 상한을 낮추거나(예: 24 MP) 최악값을 문서에 기록하세요.

### F5. (저) 빌드 산출물에 남은 Xcode 툴체인 rpath

세 바이너리 모두 `LC_RPATH` 에
`/Applications/Xcode.app/…/usr/lib/swift-6.2/macosx` 가 남아 있습니다.
`@rpath` 로 로드하는 dylib 이 0 개이고 Hardened Runtime 의 library validation 이
켜져 있어 현재 악용 경로는 없지만, 배포본에는 불필요합니다. 링커에서 제거 권장.

### F6. (저) 출력 파일 생성 권한이 umask 에 의존

`ImageSanitizer.swift:486` 의 새 파일 생성 모드가 `0o666` 입니다. 기본 umask(022)에서는
0644 로 안전하지만 umask 0 환경에서는 전역 쓰기 가능 파일이 됩니다. `0o644` 권장.

### F7. (저) 배포 신뢰 사슬이 SHA-256 단일 채널에 의존

ad-hoc 서명이라 코드 서명으로 개발자 동일성을 확인할 수 없고, 체크섬이 DMG 와 같은
페이지에 올라가면 페이지를 장악한 공격자가 둘 다 교체할 수 있습니다. 또한 업데이트 채널이
없어 취약점 수정본을 사용자에게 밀어줄 방법이 없습니다.
권고: 체크섬을 별도 채널(예: 저장소 README, 별도 도메인)에도 게시하고, 향후 Developer ID
전환 계획과 보안 신고 주소를 함께 공지.

### F8. (배포 차단 항목) 문서 공백

- `LICENSE` 파일이 없습니다. 공개 배포 시 이용 조건이 정의되지 않습니다.
- `PRIVACY.md` 의 지원 연락처가 아직 "공개 배포 전 실제 주소를 추가해야 합니다" 플레이스홀더입니다.
- 취약점 신고 주소(security contact)가 어디에도 없습니다.

## 검증하지 못한 항목

- 깨끗한 별도 Mac / macOS 13 실기 설치 시험 (기존 AUDIT 와 동일한 한계)
- VoiceOver 등 접근성 실사용
- 사진 앱 권한 거부·변경 시나리오의 실제 UI 흐름 (헤드리스 경로만 코드로 확인)

## 배포 전 체크리스트

1. F1 처리: 코드 수정 또는 주장 문구 수정 + 회귀 시험 추가 (**필수**)
2. F8 처리: LICENSE, 지원 연락처, 보안 신고 주소 (**필수**)
3. F2·F3·F4 를 README/설치 안내에 반영 (되돌릴 수 없음 경고, 격리 속성 제거, 메모리 사용량)
4. F5·F6 는 다음 빌드에서 정리
5. 첫 공개본 베타 표시, 체크섬 이중 게시


## 0.3.2 재검증 (2026-08-22)

수정 내용:
- `ImageSanitizer` 가 vImage 로 비-premultiplied(straight) sRGB 샘플을 직접 읽고, 양자화된
  알파만으로 흰색에 합성합니다. premultiplied 왕복이 사라져 원본 알파의 하위 비트가 출력
  RGB 에 남지 않습니다. (F1)
- EXIF 방향은 합성이 끝난 불투명 이미지에서 픽셀 단위로 적용합니다.
- 새 출력 파일 생성 모드 `0o666` → `0o644`. (F6)
- 배포 바이너리에서 Xcode 툴체인 `LC_RPATH` 제거. (F5)
- 자체 테스트에 회귀 시험 `알파 하위 비트 은닉 payload 제거` 추가 (15/15).

측정 결과 (배포된 0.3.2 DMG 안의 CLI 로 재현):

| 항목 | 0.3.1 | 0.3.2 |
|---|---|---|
| 알파 8/9 로 심은 24바이트 payload | 100% 복원 | 복원 불가 (정리 후 payload 구간 픽셀값 1종) |
| 알파 0–255 스윕 출력 색 수 | 81종 (거의 모든 단계에서 변화) | 17종 (경계 8·24·…·248 에서만 변화) |
| 알파 248–255 구간에서 알파를 노출하는 색 | 256색 중 23색 | 0색 |
| 알파 240–247 구간 | 256색 중 70색 | 0색 |
| 불투명 RGB 이미지 픽셀 보존 | 원본과 동일 | 원본과 동일 (0.3.1 출력과 바이트 동일) |
| EXIF 방향 1–8 (48×24 JPEG) | 기준 | 8개 방향 모두 0.3.1 과 바이트 동일 |
| 회귀 시험 | 실패 | 통과 |
| `scripts/verify-direct-dmg.sh` | 통과 | 통과 |

최종 배포물: `outputs/MetaShield-0.3.2-direct.dmg`
SHA-256 `8cfb02104aabe4a135e1024c8a847a61e13b1dfea2f1ade90f9a2f6931379f45`
(0.3.1 배포물은 `outputs/archive-pre-0.3.2/` 로 이동)

남은 배포 차단 항목: **F8** — LICENSE 파일, `PRIVACY.md` 의 실제 지원 연락처, 보안 신고 주소.
이 세 가지는 정책 결정이 필요해 임의로 채우지 않았습니다.


## 0.3.3 새 버전 확인 기능 검토 (2026-08-22)

A안(확인 전용)으로 구현했습니다. 자동 내려받기·설치(C안)는 ad-hoc 서명 상태에서 검증
불가능한 코드 실행 경로가 되므로 채택하지 않았습니다.

설계상 차단한 공격 경로:

| 공격 | 차단 방법 |
|---|---|
| 응답으로 내려받기 주소를 바꿔치기 | 모든 URL 을 앱에 컴파일. 응답에서 읽는 값은 `tag_name` 하나 |
| 태그 문자열로 경로·명령 주입 | `v?숫자.숫자.숫자`(각 1–4자리, ASCII, 선행 0 금지)만 통과, 그 외 전부 폐기 |
| 거대 응답으로 메모리 소모 | 512 KB 상한, 10초 요청 타임아웃, 20초 자원 타임아웃 |
| 헤드리스 처리 중 네트워크 노출 | 대화형 창 표시 경로에서만 호출. 실측으로 확인 |
| 추적·프로파일링 | 기본 꺼짐, 하루 1회, ephemeral 세션(쿠키·캐시 없음) |
| 자동 설치로 인한 임의 코드 실행 | 설치 기능 자체를 넣지 않음. 버튼은 브라우저로 릴리스 페이지만 엶 |

실측 검증:

- 설정 키가 없는 초기 상태에서 실행 → 확인 안 함
- 설정을 켠 상태로 `open -a MetaShield <파일>` (헤드리스) → `lastUpdateCheck` 미기록 = 네트워크 미사용
- 설정을 켠 상태로 대화형 실행 → `lastUpdateCheck` 기록 = 1회 확인
- 설정을 끈 뒤 대화형 실행 → 확인 안 함
- 태그 파싱 회귀 시험 16종 거부 문자열 통과 (자체 테스트 16/16)

남은 위험은 GitHub 계정 탈취입니다. 계정 2FA 를 켜고, 장기적으로 Developer ID + 공증으로
전환하면 macOS 가 교체본을 스스로 검증합니다.

최종 배포물: `outputs/MetaShield-0.3.3-direct.dmg`
SHA-256 `9f1565d1ef369869ecb5d193c83cb175ec5c7606368ff8bd1a6fa97b5ebe634c`

## F8 처리 완료 (0.3.4)

- `LICENSE` — Apache-2.0 전문, 저작권자 `2026 MetaShield` (실명 미표기)
- `SECURITY.md` — GitHub 비공개 취약점 신고 창구, 지원 버전, 범위 안팎 명시
- `PRIVACY.md` — 지원 창구를 GitHub Issues 로 확정 (플레이스홀더 제거)
- `README.md` — AI 보조 개발 사실과 라이선스·신고 절차 명시
- DMG 안에 `LICENSE.txt` 사본 포함 (Apache-2.0 배포 요건)

최종 배포물: `outputs/MetaShield-0.3.4-direct.dmg`
SHA-256 `f58b477e01ef7a6ea6588f9552e0fdfe1ec14a89317c1efd6eba4111d749732b`

이로써 보고서의 배포 차단 항목은 모두 해소되었습니다.
