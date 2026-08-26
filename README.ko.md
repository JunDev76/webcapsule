# WebCapsule

> React Native 앱 안의 웹 화면을 서명된 단일 `.capsule` 파일로 패키징하여 오프라인에서 즉시 실행하고, 안전한 업데이트·원자적 활성화·자동 롤백을 제공하는 오픈소스 WebView 런타임.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-green.svg)](#플랫폼-지원)
[![Status](https://img.shields.io/badge/status-pre--release-orange.svg)](#상태)

[English](README.md) · **한국어**

---

## 왜 WebCapsule인가

React Native 앱에서는 개발 속도를 높이고 바로 배포하려고 일부 화면을 원격 WebView로 만드는 경우가 많습니다. 하지만 이런 문제가 따라옵니다:

1. 처음 들어갈 때 HTML·JS·CSS·이미지를 네트워크로 받아와야 해서 **로딩이 느립니다.**
2. 네트워크가 없거나 불안정하면 **화면이 아예 열리지 않습니다.**
3. 서버나 CDN에 장애가 나면 그대로 **앱 화면 장애가 됩니다.**
4. 웹 콘텐츠와 앱 버전 사이의 **호환성을 보장하기 어렵습니다.**
5. 잘못 배포된 콘텐츠는 **무결성을 확인하고 되돌리기가 어렵습니다.**
6. Service Worker 캐시는 **처음 방문하기 전에는 존재하지 않아서**, 앱을 설치하는 시점의 기준 버전을 보장해주지 못합니다.

WebCapsule은 웹 빌드 결과물을 **검증 가능한 오프라인 실행 단위**로 바꿔서 이 문제를 해결합니다.

### WebCapsule이 배포하는 것

HTML, CSS, JavaScript, 이미지·폰트, WebView 화면에 필요한 정적 자산, manifest, 무결성 정보, 권한 선언.

### WebCapsule이 배포하지 않는 것

React Native 애플리케이션 JS 번들, Hermes/JSC 번들, 네이티브 코드 및 동적 라이브러리, RN 컴포넌트·네이티브 모듈, 새로운 OS 권한. **WebCapsule은 RN OTA 솔루션이 아닙니다.** 앱 전체를 업데이트하는 게 아니라, 앱 안에 있는 독립적인 WebView 콘텐츠를 오프라인으로 실행·검증·복구할 수 있는 단위로 관리합니다.

---

## 핵심 특징

- **서명된 오프라인 실행 단위** — `.capsule`은 ZIP 컨테이너로, 파일별 SHA-256과 manifest의 Ed25519 서명으로 모든 바이트를 검증합니다.
- **오프라인 우선** — 앱에 내장된 capsule을 검증·설치하면 네트워크 없이 즉시 실행됩니다. localhost HTTP 서버나 `file://` 접근을 사용하지 않습니다.
- **정적 호스팅 업데이트** — 자체 백엔드 없이 GitHub Pages·S3·Cloudflare R2 등 정적 HTTPS만으로 업데이트를 배포합니다.
- **원자적 활성화** — 콘텐츠 파일을 하나씩 교체하지 않고, 작은 registry의 active pointer만 원자적으로 교체합니다.
- **자동 롤백** — 새 버전은 `ready` handshake를 통과하기 전까지 pending 상태이며, 실패하면 이전 정상 버전으로 자동 복구합니다.
- **저장공간 중복 제거(CAS)** — 버전 간 동일 파일을 한 번만 저장합니다. (네트워크 델타 다운로드가 아닌 디스크 절감입니다.)
- **투명한 신뢰 모델** — 개인키는 빌드 환경에만 두고, 앱에는 공개키만 넣습니다. 검증 로직은 네이티브 코드에 독자적으로 구현되어 있어 JS 검증 결과를 신뢰하지 않습니다.
- **공개 포맷** — 특정 구현에 종속되지 않는 Format v1 명세를 `specs/`에 별도로 관리합니다.

---

## 빠른 시작

### 1. CLI로 키 생성 및 capsule 빌드

```bash
pnpm add -D @webcapsule/cli

# Ed25519 서명 키 쌍 생성
webcapsule keygen --out ./keys

# 웹 빌드 출력 디렉터리 → 서명된 capsule
webcapsule build ./dist \
  --id com.example.guide \
  --version 1.0.0 \
  --entry index.html \
  --minimum-runtime-version 1.0.0 \
  --key-id release-2027 \
  --private-key ./keys/private.pem \
  --out guide-1.0.0.capsule

# 서명·해시·형식 검증
webcapsule verify guide-1.0.0.capsule \
  --public-key ./keys/public.pem \
  --expected-id com.example.guide \
  --expected-key-id release-2027 \
  --runtime-version 1.0.0

# 메타데이터 조회(신뢰 미설정)
webcapsule inspect guide-1.0.0.capsule

# 서명된 업데이트 인덱스 생성
webcapsule index \
  --id com.example.guide \
  --channel stable \
  --key-id release-2027 \
  --private-key ./keys/private.pem \
  --release release-1.1.0.json \
  --out stable.json
```

웹 프레임워크에 제한을 두지 않습니다. React, Vue, Svelte든 정적 HTML이든 **빌드 결과물 디렉터리**만 있으면 됩니다. 원격 사이트를 크롤링하는 기능은 지원하지 않습니다.

### 2. React Native 앱에 통합

```bash
pnpm add @webcapsule/react-native
```

```tsx
import { WebCapsuleView } from "@webcapsule/react-native";

export function GuideScreen() {
  return (
    <WebCapsuleView
      style={{ flex: 1 }}
      capsuleId="com.example.guide"
      bundledAssetPath="WebCapsule/guide-1.0.0.capsule"
      publicKeys={{ "release-2027": PUBLIC_KEY }}
      runtimeVersion="1.0.0"
      onLoad={({ nativeEvent }) => console.log("loaded", nativeEvent.version)}
      onError={({ nativeEvent }) =>
        console.error(nativeEvent.code, nativeEvent.message)
      }
      onRollback={({ nativeEvent }) =>
        console.log(
          `rollback ${nativeEvent.failedVersion} -> ${nativeEvent.restoredVersion ?? "bundled"}`,
        )
      }
    />
  );
}
```

### 3. 업데이트 적용

```ts
import {
  installWebCapsuleUpdate,
  getWebCapsuleRuntimeState,
} from "@webcapsule/react-native";

// 정적 호스팅된 서명 인덱스에서 새 capsule을 백그라운드로 검증·설치
const result = await installWebCapsuleUpdate({
  capsuleId: "com.example.guide",
  bundledAssetPath: "WebCapsule/guide-1.0.0.capsule",
  publicKeys: { "release-2027": PUBLIC_KEY },
  runtimeVersion: "1.0.0",
  indexUrl: "https://example.com/guide/stable.json",
  channel: "stable",
});

if (result.status === "installed") {
  console.log(`${result.previousVersion} -> ${result.currentVersion}`);
}

// 런타임 상태 조회 (active / previous / pending / blocked)
const state = await getWebCapsuleRuntimeState({
  capsuleId: "com.example.guide",
  bundledAssetPath: "WebCapsule/guide-1.0.0.capsule",
  publicKeys: { "release-2027": PUBLIC_KEY },
  runtimeVersion: "1.0.0",
});
```

---

## 실행 흐름

1. 앱에 포함된 기본 capsule을 검증·설치합니다.
2. WebView는 활성 로컬 버전을 즉시 엽니다.
3. 업데이트 확인은 백그라운드에서 수행합니다.
4. 새 capsule을 임시 영역에 내려받습니다.
5. 서명, 파일 해시, 형식, 런타임 호환성을 검증합니다.
6. 검증 성공 후 staging 상태로 저장합니다.
7. 다음 WebView 실행 또는 명시적 요청에서 원자적으로 활성화합니다.
8. 새 콘텐츠가 `ready` 신호를 보내면 healthy로 확정합니다.
9. 실행에 실패하면 이전 healthy 버전으로 복구합니다.

```
ABSENT → DOWNLOADING → VERIFIED → STAGED → PENDING → HEALTHY
                                                       ↓ 실패
                                            FAILED / BLOCKED → ROLLED_BACK
```

---

## `.capsule` 포맷 v1

```
guide-1.0.0.capsule (ZIP)
├── capsule.json     # manifest (Ed25519 서명 대상)
├── capsule.sig      # 64-byte Ed25519 서명 (Base64 + LF)
└── files/
    ├── index.html
    └── assets/
        ├── app.js
        ├── app.css
        └── logo.webp
```

- manifest는 파일별 `sha256`·`size`·`mediaType`과 `policy`(network·navigation·bridge)를 선언합니다.
- 서명 payload: `UTF8("WEBCAPSULE-MANIFEST-V1\n") + canonical_json(capsule.json)` (RFC 8785 JCS)
- 업데이트 인덱스도 별도 Ed25519 서명 (`WEBCAPSULE-UPDATE-INDEX-V1\n` payload)
- 빌드는 결정적(deterministic)입니다 — 동일 입력과 키로 동일한 capsule 바이트가 생성됩니다.

### 보안 제한

- 경로: `..`, 절대경로, 역슬래시, symlink, NUL, Unicode NFC 충돌, 대소문자 충돌을 모두 거부합니다
- 크기 제한: capsule 100MB · 압축 해제 250MB · 단일 파일 50MB · 파일 수 10,000개
- ZIP bomb, path traversal, 중복·누락 파일, manifest 불일치는 거부합니다
- 이전 버전 재생 공격을 막기 위해 `highestSeenVersion`을 기록합니다
- 서명과 해시 검증이 끝나기 전에는 활성화하지 않습니다

전체 명세는 [`specs/`](specs/)를 참고하세요.

---

## 아키텍처

```
@webcapsule/react-native
       │
       ├── React API (WebCapsuleView, installWebCapsuleUpdate, getWebCapsuleRuntimeState)
       └── Native WebCapsule Runtime
            ├── Downloader
            ├── Archive Verifier (StrictZipReader)
            ├── Ed25519 / SHA-256 Verifier
            ├── Content-Addressed Store (CAS)
            ├── Version Registry (active / previous / pending)
            ├── Atomic Activator
            ├── Recovery Manager
            └── WebView Resource Handler
```

- **Android** — Kotlin, `WebViewAssetLoader` (`https://webcapsule.local/...`)
- **iOS** — Swift, `WKURLSchemeHandler` (`webcapsule://...`)

플랫폼 공통 호환 규칙: 상대 URL 사용을 권장하고, `file://` 접근은 금지하며, Service Worker는 v1에서 지원하지 않고, 외부 네트워크는 기본으로 막습니다.

---

## 모노레포 구조

```
webcapsule/
├── packages/
│   ├── format/                     # @webcapsule/format — manifest 타입, JSON Schema, canonicalization
│   ├── cli/                         # @webcapsule/cli — keygen, build, inspect, verify, index
│   └── react-native-webcapsule/     # @webcapsule/react-native — RN 컴포넌트 + 네이티브 런타임
│       ├── src/                     # TypeScript API
│       ├── android/                 # Kotlin 런타임
│       └── ios/Sources/WebCapsuleCore/  # Swift 런타임
├── examples/
│   ├── rn-demo/                     # RN 데모 앱
│   └── capsule-content/             # 샘플 웹 콘텐츠 (bundled-v1, updated-v2, broken-v3)
├── specs/                           # 공개 명세 (capsule-format-v1, update-index-v1, security-model, ...)
├── fixtures/                        # 정상·악성 테스트 벡터 (플랫폼 공통)
├── docs/adr/                        # Architecture Decision Records (0001~0006)
└── scripts/
```

---

## 개발

요구사항: Node.js 22 LTS, pnpm 10.

```bash
pnpm install
pnpm format:check
pnpm lint
pnpm typecheck
pnpm test          # 모든 패키지 테스트
pnpm build

# Android
pnpm android:compile
pnpm android:test
pnpm android:assemble

# iOS
pnpm ios:test

# 데모
pnpm demo:build-content   # 샘플 capsule 빌드
pnpm demo:start           # Metro 시작
pnpm demo:ios             # iOS 데모 실행
```

기여 가이드는 [CONTRIBUTING.md](CONTRIBUTING.md), 보안 정책은 [SECURITY.md](SECURITY.md)를 참고하세요.

---

## 상태

**Pre-release.** API는 안정화 전까지 변경될 수 있습니다. v1.0.0 성공 기준은 `packages/plan.md` §20을 참고하세요.

### 플랫폼 지원

| 플랫폼  | 상태                                |
| ------- | ----------------------------------- |
| Android | 구현됨 (Kotlin, WebViewAssetLoader) |
| iOS     | 구현됨 (Swift, WKURLSchemeHandler)  |

### 후속 로드맵 (v1 범위 외)

Flutter SDK, 파일 단위 원격 델타 다운로드, 키 폐기 및 고급 rotation, 배포 채널·점진 배포, Native Bridge capability 확장, 공통 네이티브 코어. 자체 CDN, 관리용 웹 대시보드, 사용자 계정, AI 기능은 계획에 없습니다.

---

## 문서

- 기획서: [`packages/plan.md`](packages/plan.md)
- 포맷 명세: [`specs/capsule-format-v1.md`](specs/capsule-format-v1.md), [`specs/update-index-v1.md`](specs/update-index-v1.md)
- 보안 모델: [`specs/security-model.md`](specs/security-model.md)
- 호환성: [`specs/compatibility.md`](specs/compatibility.md)
- 기술 결정: [`docs/adr/`](docs/adr/)
- CLI 문서: [`docs/cli.md`](docs/cli.md)

---

## 라이선스

[MIT License](LICENSE) · Copyright (c) 2026 JunDev76

서드파티 의존성 라이선스는 [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)에 기록되어 있으며, 모두 OSI 인증 라이선스를 사용합니다.
