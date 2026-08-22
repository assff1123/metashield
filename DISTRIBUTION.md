# MetaShield 무료 직접 배포 절차

MetaShield의 기본 배포 방식은 Mac App Store, Developer ID, Apple 공증을 사용하지 않는
ad-hoc 서명 DMG입니다. 비용은 들지 않지만 사용자는 최초 실행 때 macOS의
`확인 없이 열기` 절차를 거쳐야 합니다.

## 1. 배포자 준비

1. 전체 Xcode와 최신 지원 macOS를 사용합니다.
2. 앱·공유 확장·빠른 동작의 버전과 빌드 번호를 함께 증가시킵니다.
3. `PRIVACY.md`의 지원 연락처와 배포 라이선스 또는 이용 조건을 확정합니다.

Apple Developer Program 가입과 결제는 이 배포 방식에 필요하지 않습니다.

## 2. 빌드 및 DMG 생성

```sh
./scripts/package-direct-dmg.sh
./scripts/verify-direct-dmg.sh outputs/MetaShield-<버전>-direct.dmg
```

첫 스크립트는 자체 테스트, warnings-as-errors Universal 2 빌드, 중첩 ad-hoc 서명,
DMG 무결성 검사와 SHA-256 생성을 수행합니다. 결과는 다음 두 파일입니다.

- `outputs/MetaShield-<버전>-direct.dmg`
- `outputs/MetaShield-<버전>-direct.dmg.sha256`

두 번째 스크립트는 DMG 구조, 앱·CLI·공유 확장의 서명 무결성, arm64/x86_64,
plist, 자체 테스트를 검사합니다. 격리 속성을 붙인 앱이 Gatekeeper에서 차단되는 것도
예상된 결과로 확인합니다.

## 2.1 업데이트 manifest 서명

앱의 '검증된 DMG 받기'는 서명된 manifest 없이는 동작하지 않습니다. 개인키를 꽂고
다음을 실행합니다.

```sh
swift scripts/sign-update-manifest.swift \
    outputs/MetaShield-<버전>-direct.dmg <개인키 경로> outputs
```

`outputs/metashield-update.json` 과 `.sig` 가 만들어지고, 스크립트가 자체적으로 서명을
다시 검증합니다.

개인키는 GitHub Secrets, 저장소, 평문 파일 어디에도 두지 않습니다. 보관 위치는 암호화된
스파스 번들 `~/MetaShieldKey.sparsebundle` 이며, 릴리스할 때만 마운트합니다.

```sh
open ~/MetaShieldKey.sparsebundle        # 비밀번호 입력 → /Volumes/MetaShieldKey 마운트
swift scripts/sign-update-manifest.swift \
    outputs/MetaShield-<버전>-direct.dmg /Volumes/MetaShieldKey/metashield-update.key outputs
hdiutil detach /Volumes/MetaShieldKey    # 서명이 끝나면 바로 언마운트
```

마운트하지 않은 상태에서는 디스크에 암호화된 덩어리만 남으므로, 파일을 통째로 훔쳐가도
사용할 수 없습니다. 이미지 비밀번호는 이 Mac 안에 저장하지 않습니다.

**사본을 최소 한 개 다른 장소에 두어야 합니다.** 이 Mac의 디스크가 고장 나면 키가
사라지고, 이미 설치된 앱은 이후의 manifest를 검증할 수 없습니다. 그 상태를 되돌리려면
새 공개키를 내장한 버전을 사용자가 수동으로 설치해야 합니다. 사본은 암호화된 상태
(`.sparsebundle` 통째로)로 USB나 클라우드에 두면 됩니다.

키를 교체할 때는 새 공개키를 앱의 `manifestPublicKeys` 에 **추가**한 버전을 먼저 배포하고,
사용자 대부분이 그 버전으로 올라간 뒤에 옛 키를 제거합니다.

## 2.2 릴리스에 올릴 파일 네 개

```text
MetaShield-<버전>-direct.dmg
MetaShield-<버전>-direct.dmg.sha256
metashield-update.json
metashield-update.json.sig
```

이 저장소는 immutable release가 켜져 있어 게시 뒤에는 자산을 바꿀 수 없습니다. 네 개를
한 번에 첨부해 게시하고, 잘못 올렸으면 버전을 올려 새로 배포합니다. `v*` 태그는 ruleset으로
삭제·이동이 막혀 있습니다.

## 3. 배포

DMG와 일치하는 `.sha256`만 같은 HTTPS 다운로드 페이지에 올립니다. 다운로드 페이지에
이 배포본은 Apple 공증을 받지 않았으며 최초 실행 때 아래 우회 절차가 필요하다고 명시합니다.
압축을 다시 하거나 DMG 내용을 변경하면 체크섬을 새로 만들어야 합니다.

## 3.1 다운로드 페이지에 반드시 넣을 경고

- PNG는 **원본이 되돌릴 수 없게 교체**됩니다. 중요한 파일은 미리 백업하도록 안내합니다.
- 정리된 PNG에는 `com.apple.quarantine` 등 원본의 확장 속성이 승계되지 않습니다.
- 색상 프로파일·Finder 태그·설명·사용자 확장 속성은 보존하지 않습니다.
- 큰 이미지(40 MP 상한)는 처리 중 1 GB 이상의 메모리를 쓸 수 있습니다.
- `open -a MetaShield <파일>` 또는 서비스 메뉴로 호출하면 창 없이 즉시 처리됩니다.
  Finder 빠른 동작을 위한 의도된 동작이지만, 실행 즉시 원본이 바뀐다는 점을 명시합니다.

## 3.2 릴리스 태그 규칙

앱의 새 버전 확인은 GitHub 릴리스의 `tag_name` 만 읽고, `v0.4.0` 처럼 `v` + 숫자 세 자리
형식이 아니면 무시합니다. 태그를 다른 형식으로 만들면 사용자에게 알림이 가지 않습니다.
릴리스는 초안이 아닌 정식 상태여야 `releases/latest` 에 노출됩니다.

## 4. 사용자 설치 안내

1. DMG를 열고 `MetaShield.app`을 `Applications` 바로가기로 드래그합니다.
2. 응용 프로그램 폴더에서 MetaShield를 한 번 실행합니다.
3. 실행이 차단되면 `시스템 설정 > 개인정보 보호 및 보안`의 보안 영역에서
   `확인 없이 열기`를 선택하고 macOS 인증 후 다시 엽니다.
4. 앱의 `Finder 빠른 동작 설치/복구`를 한 번 누릅니다. Finder가 다시 시작될 수 있습니다.
5. 사진 앱에서 처음 사용할 때 사진 추가 권한을 허용합니다. Developer ID가 없는 새 빌드는
   코드 요구사항이 달라져 업데이트 뒤 권한을 다시 요청할 수 있습니다.

DMG 안에도 `처음 설치 방법.txt`가 포함됩니다. 사용자가 터미널에서 `xattr`을 삭제하도록
안내하지 않습니다. 시스템 설정의 공식 예외 절차가 실패와 악성 파일 오인을 줄입니다.

## 5. 공개 전 설치 시험

별도 Mac이 없으므로 이 Mac에서 브라우저 다운로드와 같은 quarantine 속성을 붙인 새 앱 복사본으로
Gatekeeper 차단을 재현하고, DMG 구조와 실행 파일을 자동 검사합니다. 이는 깨끗한 별도 Mac 시험과
완전히 같지는 않으므로 첫 공개본은 베타로 표시하고 최초 외부 사용자의 설치 결과를 확인합니다.

추가로 다음을 확인합니다.

- 표준 사용자 계정의 최초 실행 및 `확인 없이 열기`
- 구버전 교체 업그레이드와 빠른 동작 재설치
- Finder 빠른 동작 단일·다중 선택, 한글·공백·따옴표 파일명
- 사진 권한 허용·거부·나중에 변경
- 인터넷을 끈 상태의 이미지 처리
- VoiceOver, 키보드만 사용, 화면 확대, 대비 증가와 동작 줄이기

기업·학교 관리형 Mac은 보안 정책으로 미공증 앱을 완전히 차단할 수 있습니다. 이 환경은
무료 직접 배포의 지원 대상에서 제외한다고 안내해야 합니다. 최소 지원 버전 macOS 13의 실기 시험도
별도 장비나 테스터를 구할 때까지 미확인으로 기록합니다.

## 6. 업데이트와 제거

업데이트는 새 DMG의 앱을 `/Applications/MetaShield.app` 위에 교체한 뒤 빠른 동작
설치/복구를 다시 누릅니다. 새 빌드는 다시 `확인 없이 열기`와 사진 추가 권한이 필요할 수
있습니다.

제거할 때는 `/Applications/MetaShield.app`과
`~/Library/Services/MetaShield 메타데이터 완전 제거.workflow`를 휴지통으로 옮깁니다.
이미 만든 PNG와 사진 보관함 항목은 자동 삭제되지 않습니다.

## 7. 선택 사항: 향후 Developer ID 배포

나중에 최초 실행 경고를 줄이고 싶다면 Apple Developer Program 가입 후 다음 기존 경로를
사용할 수 있습니다.

```sh
METASHIELD_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
METASHIELD_NOTARY_PROFILE="metashield-notary" \
./scripts/sign-and-notarize.sh

./scripts/verify-release.sh outputs/MetaShield-<버전>.dmg
```

이 경로는 Developer ID 서명, Apple 공증, ticket stapling과 Gatekeeper 승인을 검사합니다.
