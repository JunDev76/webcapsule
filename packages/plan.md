# WebCapsule 최종 기획서

> 상태: 기획 확정안  
> 대상: React Native  
> 프로젝트명: **WebCapsule**  
> GitHub 저장소 소유자: **`JunDev76` 개인 계정**  
> 예상 저장소: **`github.com/JunDev76/webcapsule`**  
> npm scope: **`@webcapsule` 확보 완료**  
> 별도 GitHub 조직과 프로젝트 도메인은 v1 범위에서 제외

---

## 1. 한 문장 정의

> WebCapsule은 React Native 앱 내부의 웹 화면을 서명된 단일 `.capsule` 파일로 패키징하여 네트워크 없이 즉시 실행하고, 안전한 업데이트·원자적 활성화·자동 롤백을 제공하는 오픈소스 WebView 런타임이다.

## 2. 해결하려는 문제

React Native 앱에서 개발 속도와 즉시 배포가 중요한 일부 화면은 원격 WebView로 구현한다. 하지만 다음 문제가 있다.

1. 첫 진입 때 HTML·JavaScript·CSS·이미지를 네트워크에서 받아 로딩이 느리다.
2. 네트워크가 없거나 불안정하면 화면이 열리지 않는다.
3. 서버 또는 CDN 장애가 앱 화면 장애로 이어진다.
4. 웹 콘텐츠와 네이티브 앱 버전의 호환성을 보장하기 어렵다.
5. 잘못 배포한 콘텐츠의 무결성 확인과 즉시 롤백이 어렵다.
6. Service Worker 캐시는 최초 방문 전에 존재하지 않으며 앱 설치 시점의 기준 버전을 보장하기 어렵다.

WebCapsule은 웹 빌드 산출물을 검증 가능한 오프라인 실행 단위로 바꾸어 이 문제를 해결한다.

## 3. 제품 경계

### WebCapsule이 배포하는 것

- HTML
- CSS
- JavaScript
- 이미지 및 폰트
- WebView 화면에 필요한 정적 자산
- manifest, 무결성 정보, 권한 선언

### WebCapsule이 배포하지 않는 것

- React Native 애플리케이션 JS 번들
- Hermes/JSC 번들
- 네이티브 코드 및 동적 라이브러리
- RN 컴포넌트와 네이티브 모듈
- 새로운 OS 권한
- 앱스토어 심사를 우회하기 위한 앱 핵심 기능

### 핵심 포지셔닝

WebCapsule은 RN OTA 솔루션이 아니다. 앱 전체를 업데이트하지 않고 **앱 내부의 독립적인 WebView 콘텐츠를 오프라인 실행·검증·복구 가능한 단위로 관리**한다.

업데이트는 핵심 정체성이 아니라 로컬 실행 단위의 생명주기를 관리하는 기능이다.

## 4. 우선 사용 사례

초기 문서와 데모는 비핵심·콘텐츠 중심 화면을 대상으로 한다.

- 앱 내 도움말과 사용자 매뉴얼
- 교육 콘텐츠와 튜토리얼
- 제품 카탈로그
- 행사·전시 안내
- 설문과 온보딩 콘텐츠
- 네트워크 취약 지역에서 사용하는 현장 업무 안내

금융 거래, 결제, 인증, 의료 판단 등 앱 핵심 기능을 원격 업데이트하는 사용 사례는 권장하지 않는다.

---

# 5. 사용자 경험

## 5.1 웹 개발자

```bash
pnpm add -D @webcapsule/cli

webcapsule keygen --out ./keys

webcapsule build ./dist \
  --id com.example.guide \
  --version 1.0.0 \
  --entry index.html \
  --private-key ./keys/private.pem \
  --out guide-1.0.0.capsule

webcapsule verify guide-1.0.0.capsule \
  --public-key ./keys/public.pem
```

웹 프레임워크는 제한하지 않는다. React, Vue, Svelte 또는 정적 HTML의 **빌드 출력 디렉터리**를 입력받는다. 원격 사이트 크롤링은 지원하지 않는다.

## 5.2 React Native 개발자

WebCapsule 패키지는 공개 npm 패키지로 배포하며, 사용자는 자신의 React Native 앱에 설치하여 사용한다.

```bash
pnpm add @webcapsule/react-native
```

```tsx
import { WebCapsuleView } from "@webcapsule/react-native";

export function GuideScreen() {
  return (
    <WebCapsuleView
      capsuleId="com.example.guide"
      bundledSource={require("./capsules/guide-1.0.0.capsule")}
      publicKeys={{ "release-2027": PUBLIC_KEY }}
      updateIndexUrl="https://jundev76.github.io/webcapsule-demo/guide/stable.json"
      onReady={({ version }) => console.log(version)}
      onRollback={({ failed, restored }) => {
        console.log(`${failed} → ${restored}`);
      }}
    />
  );
}
```

## 5.3 실행 순서

1. 앱에 포함된 기본 capsule을 검증·설치한다.
2. WebView는 활성 로컬 버전을 즉시 연다.
3. 업데이트 확인은 백그라운드에서 수행한다.
4. 새 capsule을 임시 영역에 내려받는다.
5. 서명, 파일 해시, 형식, 런타임 호환성을 검증한다.
6. 검증 성공 후 staging 상태로 저장한다.
7. 다음 WebView 실행 또는 명시적 요청에서 원자적으로 활성화한다.
8. 새 콘텐츠가 준비 완료 신호를 보내면 healthy로 확정한다.
9. 실행에 실패하면 이전 healthy 버전으로 복구한다.

---

# 6. `.capsule` 포맷 v1

## 6.1 컨테이너

`.capsule`은 투명성과 구현 용이성을 위해 ZIP 컨테이너를 사용한다.

```text
guide-1.0.0.capsule
├── capsule.json
├── capsule.sig
└── files/
    ├── index.html
    └── assets/
        ├── app.js
        ├── app.css
        └── logo.webp
```

독자 압축 알고리즘을 만드는 것이 목적이 아니다. 프로젝트의 기술적 핵심은 **포맷, 신뢰 검증, 활성화 및 실패 복구 프로토콜**이다.

## 6.2 Manifest

```json
{
  "formatVersion": 1,
  "capsuleId": "com.example.guide",
  "version": "1.0.0",
  "entry": "index.html",
  "createdAt": "2027-03-01T12:00:00Z",
  "minimumRuntimeVersion": "1.0.0",
  "keyId": "release-2027",
  "files": [
    {
      "path": "index.html",
      "sha256": "4e1c...",
      "size": 1834,
      "mediaType": "text/html"
    }
  ],
  "policy": {
    "network": { "mode": "deny" },
    "navigation": { "externalOrigins": [] },
    "bridgeCapabilities": []
  }
}
```

## 6.3 서명과 무결성

- 파일별 SHA-256
- manifest에 Ed25519 서명
- 업데이트 인덱스에도 별도 Ed25519 서명
- 앱에는 공개키만 포함하며 개인키는 빌드 환경에만 보관
- manifest에 없는 파일 또는 누락된 파일은 거부
- 서명·해시 검증 완료 전에는 활성화 금지

서명 payload:

```text
UTF8("WEBCAPSULE-MANIFEST-V1\n") + canonical_json(capsule.json)
```

## 6.4 필수 보안 제한

- `..`, 절대경로, 역슬래시 및 symlink 거부
- 파일 수, 개별 파일 크기, 전체 압축 해제 크기 제한
- ZIP bomb 및 path traversal 방어
- 중복·대소문자 충돌 경로 거부
- capsule ID와 신뢰 key ID 검사
- 최소 런타임 버전 검사
- 이전 버전 재생 공격을 막기 위한 최고 확인 버전 기록

---

# 7. 업데이트 구조

## 7.1 실행 시 로컬 서버 사용 여부

v1은 휴대폰에서 localhost HTTP 서버를 띄우지 않는다.

- Android는 `WebViewAssetLoader`가 `https://webcapsule.local/...` 요청을 가로채 앱 로컬 저장소의 파일을 반환한다.
- iOS는 `WKURLSchemeHandler`가 `webcapsule://...` 요청을 가로채 앱 로컬 저장소의 파일을 반환한다.
- 두 방식 모두 실제 TCP 포트를 열거나 백그라운드 HTTP 서버를 실행하지 않는다.

겉으로는 URL로 로드되지만 요청이 네트워크 스택의 로컬 서버로 전달되는 것이 아니라 WebView의 네이티브 리소스 핸들러에서 처리된다. 이 방식을 선택하는 이유는 다음과 같다.

- 포트 충돌 및 서버 생명주기 관리가 없다.
- 앱 백그라운드 전환·복귀 시 별도 서버 재시작이 필요 없다.
- 다른 앱이나 로컬 네트워크에 포트가 노출되지 않는다.
- Android 공식 WebView 리소스 로딩 방식과 iOS 공식 URL scheme handler를 사용할 수 있다.
- 오프라인 실행 경로가 단순해져 기능테스트와 보안 검증이 쉽다.

단, iOS custom scheme과 Android HTTPS-like origin의 Web API 동작 차이가 있으므로 Format v1 호환 프로필을 문서화하고 공통 fixture로 검증한다. 향후 실제 localhost 서버 방식은 호환성 문제가 명확히 입증될 때만 별도 어댑터로 검토하며 v1에는 포함하지 않는다.

## 7.2 Capsule 호스팅과 자체 배포

WebCapsule 프로젝트는 업데이트 파일을 중앙 서버에 독점적으로 보관하거나 중계하지 않는다. 패키지 사용자가 다음 산출물을 자신의 인프라에 직접 배포한다.

- `.capsule` 파일
- 서명된 update index JSON

배포 위치는 GitHub Pages, GitHub Releases, S3, Cloudflare R2, 사내 CDN 또는 일반 HTTPS 정적 호스팅이 될 수 있다. 별도 WebCapsule 백엔드는 필요하지 않다. 샘플은 추가 도메인을 등록하지 않고 `JunDev76` 계정의 GitHub Pages 또는 GitHub Releases를 사용한다.

```text
https://jundev76.github.io/webcapsule-demo/guide/stable.json
https://jundev76.github.io/webcapsule-demo/guide/1.0.0.capsule
https://jundev76.github.io/webcapsule-demo/guide/1.1.0.capsule
```

소유권과 신뢰 경계는 사용자에게 있다.

- 사용자가 Ed25519 개인키를 생성·보관한다.
- 사용자가 자신의 웹 콘텐츠를 빌드하고 서명한다.
- 사용자가 자신의 호스팅에 capsule과 index를 올린다.
- 앱에는 대응하는 공개키를 포함한다.
- WebCapsule 운영자가 콘텐츠, 개인키 또는 배포 인프라를 보유하지 않는다.

따라서 특정 SaaS나 WebCapsule 서비스 종료에 종속되지 않으며 완전한 self-hosting이 가능하다.

## 7.3 정적 업데이트 인덱스

WebCapsule은 자체 서버를 제공하지 않는다. GitHub Pages, GitHub Releases, S3 또는 일반 HTTPS 정적 호스팅만 있으면 된다.

```json
{
  "schemaVersion": 1,
  "capsuleId": "com.example.guide",
  "channel": "stable",
  "releases": [
    {
      "version": "1.1.0",
      "url": "https://jundev76.github.io/webcapsule-demo/guide/1.1.0.capsule",
      "sha256": "...",
      "size": 182930,
      "minimumRuntimeVersion": "1.0.0"
    }
  ],
  "keyId": "release-2027",
  "signature": "..."
}
```

## v1에서 정확히 제공하는 것

- 전체 `.capsule` 다운로드
- 파일 단위 콘텐츠 주소 저장소(CAS)
- 버전 간 동일 파일을 한 번만 저장하는 중복 제거
- active·previous·pending 버전 관리

## v1에서 제공하지 않는 것

- 네트워크 델타 다운로드
- 바이너리 diff
- CDN
- 점진 배포
- 사용자별 rollout

따라서 v1의 CAS를 “증분 다운로드”라고 표현하지 않고 **저장공간 중복 제거**라고 정확히 설명한다.

---

# 8. 활성화와 롤백

## 8.1 상태 모델

```text
ABSENT
  → DOWNLOADING
  → VERIFIED
  → STAGED
  → PENDING
  → HEALTHY

PENDING
  → FAILED
  → BLOCKED
  → ROLLED_BACK
```

## 8.2 원자적 활성화

콘텐츠 파일을 하나씩 교체하지 않는다. 검증 완료된 불변 버전을 저장한 뒤 작은 registry의 active pointer만 원자적으로 교체한다.

```json
{
  "capsuleId": "com.example.guide",
  "active": "1.1.0",
  "previous": "1.0.0",
  "pending": "1.1.0",
  "highestSeenVersion": "1.1.0",
  "generation": 7
}
```

WebView 세션은 시작할 때 선택한 버전에 고정한다. 실행 중 업데이트가 활성화되더라도 한 화면에 서로 다른 버전의 자원이 섞이지 않는다.

## 8.3 건강 확인

웹 콘텐츠가 초기화를 완료하면 다음 메시지를 보낸다.

```js
window.WebCapsuleBridge.postMessage(JSON.stringify({
  type: "ready",
  protocolVersion: 1,
  capsuleId: "com.example.guide",
  version: "1.1.0"
}));
```

다음 조건을 통과해야 healthy가 된다.

1. 진입 문서 로드 성공
2. capsule ID·version 일치
3. ready 메시지 수신
4. 설정된 안정화 시간 동안 치명적 오류 없음

기본값:

- ready timeout: 15초
- 안정화 시간: 3초
- pending 최대 시도: 2회

실패하면 해당 버전을 blocked 처리하고 previous healthy 버전으로 복구한다. 이전 버전도 없으면 앱에 포함된 기본 capsule로 돌아간다.

---

# 9. 플랫폼 구조

```text
@webcapsule/react-native
       │
       ├── React API 및 이벤트
       ├── Update Coordinator
       └── WebCapsuleView
                │
       Native WebCapsule Runtime
       ├── Downloader
       ├── Archive Verifier
       ├── Ed25519/SHA-256 Verifier
       ├── Content-Addressed Store
       ├── Version Registry
       ├── Atomic Activator
       ├── Recovery Manager
       └── WebView Resource Handler
```

## Android

- Kotlin
- `WebViewAssetLoader`
- 로컬 HTTPS 형태의 origin
- WebCapsule 전용 native `WebView`

예시:

```text
https://webcapsule.local/com.example.guide/1.1.0/index.html
```

## iOS

- Swift
- `WKURLSchemeHandler`
- `react-native-webview` 연동

예시:

```text
webcapsule://com.example.guide/1.1.0/index.html
```

## 공통 호환 규칙

- 상대 URL 사용 권장
- `file://` 접근 금지
- Service Worker v1 미지원
- 외부 네트워크 기본 차단
- SPA navigation 요청에 한해 선택적 `index.html` fallback
- 플랫폼별 origin 차이를 명세와 테스트 fixture로 관리

---

# 10. WebView 보안 모델

기본 설정은 제한적이어야 한다.

- 외부 네트워크: 기본 거부
- 외부 top-level navigation: 기본 거부
- 새 창: 거부
- 로컬 파일 접근: 거부
- release WebView 디버깅: 비활성화
- 임의 native module 접근: 거부
- bridge 입력: schema 및 capability 검사

네트워크가 필요한 경우 host 앱이 명시적으로 허용한다.

```tsx
networkPolicy={{
  mode: "allowlist",
  origins: ["https://api.example.com"]
}}
```

Native Bridge는 capsule 선언과 host 승인의 교집합만 허용한다.

```text
manifest가 요청한 capability ∩ host가 허용한 capability
```

v1 기본 bridge는 ready handshake와 사용자 메시지 전달만 제공한다.

---

# 11. 모노레포 구성

```text
webcapsule/
├── packages/
│   ├── format/
│   ├── cli/
│   └── react-native-webcapsule/
│       ├── src/
│       ├── android/
│       └── ios/
├── examples/
│   ├── rn-demo/
│   └── capsule-content/
├── specs/
│   ├── capsule-format-v1.md
│   ├── update-index-v1.md
│   ├── security-model.md
│   └── compatibility.md
├── fixtures/
│   ├── valid/
│   ├── invalid-signature/
│   ├── path-traversal/
│   └── rollback/
├── docs/
├── .github/
├── pnpm-workspace.yaml
├── LICENSE
├── NOTICE
├── THIRD_PARTY_LICENSES.md
├── CONTRIBUTING.md
└── SECURITY.md
```

## 공개 패키지

확보한 npm scope `@webcapsule` 아래에 다음 패키지를 배포한다.

- `@webcapsule/format`: manifest 타입, JSON Schema, canonicalization, 경로 및 버전 규칙
- `@webcapsule/cli`: keygen, build, inspect, verify, index
- `@webcapsule/react-native`: RN 컴포넌트와 네이티브 런타임

각 패키지는 npm public package로 배포한다. 애플리케이션 개발자는 npm에서 SDK와 CLI를 설치하고, capsule 콘텐츠는 자신의 저장소·CDN·서버에 자체 배포한다.

공식 소스 저장소는 별도 GitHub 조직을 만들지 않고 `JunDev76/webcapsule`을 사용한다. 샘플 capsule의 정적 배포가 필요하면 `JunDev76/webcapsule-demo` 또는 메인 저장소의 GitHub Pages를 사용한다. 별도 도메인은 등록하지 않는다.

---

# 12. MVP와 비범위

## MVP 필수

- [ ] Capsule Format v1 공개 명세
- [ ] 결정적(deterministic) CLI 빌드
- [ ] CLI keygen/build/inspect/verify/index
- [ ] SHA-256 파일 검증
- [ ] Ed25519 manifest 및 update index 서명
- [ ] RN Android 런타임
- [ ] RN iOS 런타임
- [ ] 앱 내 기본 capsule 포함
- [ ] 오프라인 로컬 WebView 실행
- [ ] 정적 HTTPS 업데이트
- [ ] staging 및 원자적 활성화
- [ ] pending 건강 확인
- [ ] 이전 healthy 버전 자동 롤백
- [ ] CAS 저장 중복 제거
- [ ] 샘플 앱
- [ ] 악성·손상 fixture
- [ ] 테스트, SBOM, 라이선스 문서

## 후속 로드맵

- Flutter SDK
- 실제 파일 단위 원격 델타 다운로드
- 키 폐기 및 고급 rotation
- 배포 채널과 점진 배포
- Native Bridge capability 확장
- 공통 네이티브 코어

## 구현하지 않음

- 자체 CDN 또는 관리 웹
- 사용자 계정
- 원격 사이트 크롤러
- RN JS Bundle OTA
- 네이티브 플러그인 동적 설치
- AI 기능

---

# 13. 테스트 계획

## 포맷과 CLI

- 동일 입력·키로 동일한 capsule 바이트 생성
- 정상 서명 검증
- 단일 바이트 변조 탐지
- manifest/file 불일치 거부
- path traversal·symlink·case collision 거부
- ZIP bomb 크기 제한
- 이전 버전 index 거부

## 네이티브

- 앱 첫 설치 후 비행기 모드 실행
- 정상 업데이트
- 업데이트 다운로드 중 강제 종료
- 검증 중 강제 종료
- 활성화 직전·직후 강제 종료
- ready timeout 후 자동 롤백
- 손상된 CAS에서 fallback
- 저장공간 부족 시 기존 active 보존
- 동시에 여러 업데이트 요청 시 직렬화

## 자동화 도구

- TypeScript: Vitest
- Android: JUnit
- iOS: XCTest
- 앱 E2E: Maestro
- CI: GitHub Actions
- 보안·의존성: CodeQL, Dependabot, SBOM 및 라이선스 스캔

## 핵심 불변식

1. 검증되지 않은 버전은 active가 될 수 없다.
2. active는 완전한 manifest와 모든 파일을 가져야 한다.
3. previous는 healthy 버전만 가리킨다.
4. WebView가 읽는 파일은 해당 세션 manifest에 존재해야 한다.
5. 어떤 archive 경로도 저장소 밖으로 나갈 수 없다.
6. pending 실패 후 active는 previous 또는 bundled fallback이다.

---

# 14. 성능 및 효과 측정

단순히 “빠르다”라고 주장하지 않고 반복 측정한다.

## 비교군

1. 원격 WebView cold start
2. 원격 WebView warm cache
3. WebCapsule local cold start
4. WebCapsule local warm start
5. 완전 오프라인

## 측정 지표

- p50/p95 첫 콘텐츠 표시 시간
- 화면 준비 완료 시간
- 오프라인 실행 성공률
- 10MB·50MB capsule 검증 시간
- peak memory
- 업데이트 활성화 시간
- 롤백 복구 시간
- 공통 파일 저장 중복 제거율
- 강제 종료 지점별 복구 성공률
- 변조 fixture 거부율

## 고정 조건 예시

- 기기: 보급형 Android 1대, iPhone 1대
- 웹 자원: 10MB 및 50MB
- 네트워크: Wi-Fi, 제한된 네트워크, Offline
- 반복: 조건별 최소 30회
- 동일 앱·동일 웹 콘텐츠 사용

---

# 15. 데모 시나리오

5분 이내 데모를 다음 순서로 고정한다.

1. 동일 화면을 원격 WebView와 WebCapsule로 나란히 실행한다.
2. 비행기 모드에서 원격 WebView는 실패하고 capsule은 즉시 열린다.
3. 네트워크를 연결해 정적 호스팅의 v2를 발견한다.
4. 다운로드·서명 검증·활성화 상태를 보여준다.
5. 앱 재배포 없이 다음 화면 실행에서 v2가 열린다.
6. 일부러 초기화에 실패하는 서명된 v3를 설치한다.
7. ready timeout 이후 v2로 자동 롤백되는 것을 보여준다.
8. 한 바이트 변조한 capsule이 검증 단계에서 거부되는 것을 보여준다.

외부 네트워크 장애에 대비해 모든 서버 응답과 capsule을 로컬 데모 환경에서도 재현할 수 있게 준비한다.

---

# 16. 프로젝트 품질 목표

## 코드·문서·구조

| 영역 | 목표 |
|---|---|
| 코드 완성도 | 작은 패키지 경계, 타입 안전 API, 네이티브 단위 테스트, 오류 코드 |
| 발전 가능성 | 공개 포맷, RN SDK, Flutter·델타 업데이트 로드맵 |
| 문서 구체성 | 포맷·보안·호환성 명세, Quick Start, 예제 앱 |
| 혁신성 | 서명된 WebView 실행 단위 + 원자적 활성화 + 건강 확인 롤백 |
| 관리체계 | Issue→branch→PR→self-review, ADR, roadmap, 외부 피드백 |

## 활용·검증

| 영역 | 목표 |
|---|---|
| 활용성 | 도움말·교육·현장 안내 사례, 5분 설치, 서버 불필요 |
| 안정성 | 오프라인, 업데이트, 변조 거부, 자동 롤백을 실제 기기에서 확인 |
| 커뮤니티 | 공개 명세, CONTRIBUTING, good first issue, 외부 테스트 |
| 오픈소스 적절성 | RN WebView·표준 암호·ZIP 생태계를 투명하게 활용하고 고지 |
| 기능 검증 | kill-point 복구, 악성 archive, 저장공간 및 네트워크 실패 테스트 |
| 라이선스 | OSI 라이선스, SBOM, NOTICE, THIRD_PARTY_LICENSES 관리 |

---

# 17. 1인 개발 운영 원칙

1인 프로젝트라도 관리 이력을 의도적으로 만든다.

1. 모든 기능과 버그를 Issue로 등록한다.
2. 한 Issue에 한 브랜치를 사용한다.
3. 작은 PR을 생성하고 체크리스트로 self-review한다.
4. ADR로 중요한 기술 선택을 기록한다.
5. 주 단위 roadmap과 milestone을 공개한다.
6. 첫 MVP 후 외부 RN 개발자에게 설치 테스트를 요청한다.
7. 외부 피드백은 Issue로 기록하고 처리 과정을 남긴다.
8. 기능 확장보다 테스트와 문서를 우선한다.

혼자라는 사실을 숨기기보다, **혼자서도 재현 가능한 오픈소스 관리체계를 구축했다**는 증거를 만든다.

---

# 18. 14주 개발 일정

| 주차 | 목표 | 완료 기준 |
|---:|---|---|
| 1 | 범위·포맷·위협 모델 | Format v1과 상태 머신 초안 공개 |
| 2~3 | format 및 CLI | 결정적 build, inspect, verify와 악성 fixture |
| 4 | signed update index | 정적 호스팅에서 새 버전 탐지 |
| 5~6 | Android 런타임 | 오프라인 실행·검증·업데이트 |
| 7~8 | iOS 런타임 | 동일 capsule과 테스트 벡터 통과 |
| 9 | 원자적 활성화·복구 | 중단 시 구/신 버전 중 하나로만 복구 |
| 10 | 건강 확인·롤백 | 깨진 버전에서 자동 복귀 |
| 11 | 공개 RN API·샘플 앱 | 처음 보는 사용자가 5분 안에 실행 |
| 12 | 보안·성능 시험 | fault injection 및 벤치마크 결과 확보 |
| 13 | 문서·오픈소스 품질 | SBOM, 라이선스, SECURITY, 외부 테스트 |
| 14 | v1.0.0 안정화 | v1.0.0 태그, 데모와 Q&A 확정 |

시간이 부족하면 iOS를 완전히 제거하기보다 Android를 우선 완성한 뒤 iOS는 최소 동작까지 구현한다. 단, “React Native 지원”을 주장하려면 플랫폼 지원 범위를 README에 정확히 표시한다.

---

# 19. 주요 위험과 대응

## 기존 OTA 솔루션과 유사해 보일 위험

- RN 앱 번들을 수정하지 않는다는 경계를 반복한다.
- 업데이트보다 오프라인 실행 단위와 복구 프로토콜을 강조한다.
- 비교표와 기술적 비범위를 문서에 포함한다.

## “Service Worker면 충분하지 않나?”라는 질문

- 최초 방문 전에는 캐시가 없다.
- 앱 설치 시 기준 버전을 내장하기 어렵다.
- 전체 콘텐츠 버전의 원자적 전환과 자동 롤백이 기본 모델이 아니다.
- 네이티브 런타임 호환성과 공개키 신뢰 모델이 없다.

## 앱스토어 정책 위험

- 앱 정책을 우회하는 도구로 홍보하지 않는다.
- 네이티브 코드·권한·RN 번들을 변경하지 않는다.
- 문서에서 콘텐츠 중심·비핵심 사용 사례를 권장한다.
- 실제 배포자는 Apple·Google 정책과 앱 심사 조건을 별도로 검토해야 함을 명시한다.

## iOS와 Android origin 차이

- 상대 URL 중심의 호환 프로필을 정의한다.
- 플랫폼 공통 fixture를 운영한다.
- Service Worker와 고급 브라우저 기능은 v1에서 제외한다.

## 범위 과다

- crawler, CDN, 관리 웹, Flutter, AI, binary diff를 추가하지 않는다.
- 포맷·CLI·런타임·실패 복구·테스트에 집중한다.

---

# 20. 성공 기준

다음을 모두 달성하면 v1.0.0이 완성된 것으로 본다.

- [ ] 동일한 입력과 키로 동일한 `.capsule`이 생성된다.
- [ ] 구현과 독립된 공개 Format v1 명세가 있다.
- [ ] 파일 한 바이트 변조를 검출한다.
- [ ] 신뢰하지 않는 키로 서명한 capsule을 활성화하지 않는다.
- [ ] 앱 첫 설치 직후 네트워크 없이 화면을 실행한다.
- [ ] Android와 iOS의 지원 상태가 테스트로 증명된다.
- [ ] 정적 HTTPS 파일만으로 업데이트할 수 있다.
- [ ] 업데이트 중 주요 단계에서 앱이 종료돼도 기존 healthy 버전이 보존된다.
- [ ] 새 버전은 ready 확인 전까지 pending 상태다.
- [ ] pending 버전이 반복 실패하면 이전 버전으로 자동 복구한다.
- [ ] 동일한 파일은 CAS에 한 번만 저장된다.
- [ ] WebView 콘텐츠가 RN 앱 번들이나 네이티브 코드를 바꿀 수 없다.
- [ ] 전체 핵심 흐름을 실제 기기에서 5분 이내 재현한다.
- [ ] 자동 테스트, SBOM, 라이선스 및 보안 문서가 공개되어 있다.

---

# 21. 핵심 소개 문구

> 원격 WebView는 개발하기 쉽지만 네트워크에 종속되고, 단순 캐시는 처음부터 믿을 수 있는 버전을 보장하지 못합니다. WebCapsule은 웹 콘텐츠를 서명된 오프라인 실행 단위로 패키징합니다. 앱은 로컬 버전을 즉시 실행하고, 새 버전을 백그라운드에서 검증한 뒤 원자적으로 교체하며, 실패하면 이전 정상 버전으로 자동 복구합니다.

## 핵심 키워드

- Offline-first WebView
- Signed web content package
- Atomic activation
- Automatic rollback
- Static hosting
- Open format
- React Native
