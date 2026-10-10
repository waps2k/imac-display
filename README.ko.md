# iMac Display

[English](README.md) | **한국어**

구형 iMac(예: iMac 2017 27" 5K)을 맥북의 **확장 모니터**로 쓰기 위한 무료 오픈소스 앱입니다.
Target Display Mode가 없는 iMac에서도 소프트웨어 방식으로 동작합니다.

```
[맥북: Sender]                                             [iMac: Receiver]
가상 디스플레이 → ScreenCaptureKit 캡처 → HEVC 하드웨어 인코딩
                         ──── 썬더볼트 브릿지 / 이더넷 / Wi-Fi (TCP) ────▶
                                             HEVC 하드웨어 디코딩 → 전체 화면 표시
```

- 맥북에 실제 모니터처럼 보이는 **가상 디스플레이**가 생깁니다. 창을 끌어다 놓고 배치를 바꿀 수 있습니다.
- 마우스와 키보드는 맥북 것을 그대로 씁니다.
- iMac의 해상도(5K면 5120×2880, HiDPI)를 자동으로 맞춥니다.
- Bonjour로 iMac을 자동으로 찾고, **썬더볼트 → 유선 랜 → Wi-Fi** 순서로 가장 빠른 경로를 골라 연결합니다.
- 연결 중에도 더 빠른 경로가 생기면 가상 디스플레이를 유지한 채 자동으로 전환합니다.
- 메뉴 막대에 연결 종류, 링크 속도, 실제 전송 속도, fps, 지연 시간을 표시합니다.

> ⚠️ 실험 단계입니다. 가상 디스플레이는 애플의 **비공개 API**(`CGVirtualDisplay`)를 사용하므로 macOS 업데이트 후 동작하지 않을 수 있습니다.

## 설치

개발 도구 없이 바로 쓰려면 [최신 릴리즈](https://github.com/waps2k/imac-display/releases/latest)에서 두 파일을 받으세요.

- `iMacDisplay-Sender-x.y.z.zip` → **맥북**에서 압축을 풀고 응용 프로그램 폴더로 옮깁니다
- `iMacDisplay-Receiver-x.y.z.zip` → **iMac**에서 압축을 풀고 응용 프로그램 폴더로 옮깁니다

애플 공증을 받지 않은 앱이라 처음 실행할 때 "확인되지 않은 개발자" 경고가 뜰 수 있습니다. 앱을 우클릭해서 **열기**를 누르거나, 터미널에서 아래 명령을 실행하세요.

```bash
xattr -dr com.apple.quarantine "/Applications/iMacDisplay Sender.app"     # 맥북
xattr -dr com.apple.quarantine "/Applications/iMacDisplay Receiver.app"   # iMac
```

## 요구 사항

| | 송신 (Sender) | 수신 (Receiver) |
|---|---|---|
| 기기 | 맥북 등 (Apple Silicon 권장) | iMac 등 아무 Mac |
| macOS | 13 이상 | 13 이상 (iMac 2017 + Ventura OK) |
| 권한 | 화면 기록, 로컬 네트워크 | 로컬 네트워크 |

## 직접 빌드

Xcode(또는 Command Line Tools)가 필요합니다.

```bash
./scripts/build-apps.sh
```

`dist/`에 Universal(Intel + Apple Silicon) 앱 두 개가 생깁니다.

- `iMacDisplay Sender.app` → 맥북
- `iMacDisplay Receiver.app` → iMac으로 복사

새 버전은 아래 명령 하나로 빌드부터 GitHub 릴리즈 업로드(바이너리 첨부)까지 처리합니다.

```bash
./scripts/release.sh 0.2.2 "변경 내용"
```

## 연결 가이드

사용 가능한 연결 중 가장 빠른 경로를 자동으로 고릅니다. 연결할 수 있는 방법을 모두 연결해 두면 앱이 알아서 가장 좋은 경로를 씁니다.

| 순위 | 연결 | 속도 | 방법 |
|---|---|---|---|
| ① | **썬더볼트** (권장) | 10~40 Gbps | 썬더볼트 3/4 케이블(⚡)로 두 Mac을 직접 연결합니다. 설정할 필요가 없습니다 |
| ② | **유선 랜** | 1 Gbps 이상 | 두 Mac을 같은 공유기/스위치에 랜선으로 연결합니다 (맥북은 USB-C 랜 어댑터) |
| ③ | **Wi-Fi** | 환경에 따라 다름 | 같은 Wi-Fi에 연결합니다. 5GHz 대역 또는 Wi-Fi 6을 권장합니다 |

- 썬더볼트 브리지는 케이블만 꽂으면 링크 로컬 주소(169.254.x.x)가 자동으로 잡히고 Bonjour 검색도 됩니다.
- 일반 USB-C 충전 케이블은 썬더볼트 속도가 나오지 않거나 연결되지 않을 수 있습니다.
- 연결 종류에 맞춰 비트레이트를 자동으로 정합니다: 썬더볼트 120 / 유선 60 / Wi-Fi 25 Mbps.
- Wi-Fi로 연결된 상태에서 썬더볼트 케이블을 꽂으면 몇 초 안에 썬더볼트로 전환됩니다. 연결이 잠깐 끊겨도 15초 동안은 가상 디스플레이와 창 배치를 유지합니다.

### 메뉴 막대 표시

```
⚡ 87M          ← 아이콘: 연결 종류 (⚡ 썬더볼트 · 🔌 유선 · 📶 Wi-Fi), 숫자: 실제 전송 속도
───────────────
전송 중 → iMac
연결: 썬더볼트 (bridge0) · 링크 20 Gbps
전송: 87.3 Mbps · 60 fps · 지연 1.4 ms
화면: 5120×2880 HEVC · 목표 120 Mbps
```

## 사용법

1. **iMac**에서 `iMacDisplay Receiver`를 실행합니다. 화면이 검은 대기 화면으로 바뀌고 IP 주소가 표시됩니다. 종료는 ⌘Q입니다.
2. **맥북**에서 `iMacDisplay Sender`를 실행합니다. 메뉴 막대에 🖥 아이콘이 생깁니다.
   - 처음 실행하면 **화면 기록** 권한을 요청합니다. 허용한 뒤 메뉴 막대 메뉴에서 **앱 다시 시작**을 누르세요.
3. 맥북의 시스템 설정 → 디스플레이에서 iMac의 위치를 배치합니다.

### 설정 (선택)

명령줄 인자나 `defaults`로 바꿀 수 있습니다.

```bash
# 한 번만 적용
"dist/iMacDisplay Sender.app/Contents/MacOS/Sender" -host 10.0.0.1 -bitrate 80

# 영구 적용
defaults write com.waps2k.imacdisplay.sender host 10.0.0.1
defaults write com.waps2k.imacdisplay.sender bitrate -int 80
```

| 키 | 기본값 | 설명 |
|---|---|---|
| `host` | (자동 검색) | 수신기 IP. 지정하면 자동 경로 선택과 전환을 하지 않습니다 |
| `port` | 52020 | |
| `wiredOnly` | false | true면 Wi-Fi를 사용하지 않습니다 |
| `codec` | hevc | `hevc` 또는 `h264` (H.264는 4K 이하에서만 사용하세요) |
| `bitrate` | (자동) | Mbps. 지정하지 않으면 연결 종류에 맞춰 자동으로 정합니다 (썬더볼트 120 / 유선 60 / Wi-Fi 25) |
| `fps` | 60 | |
| `maxWidth` | 0 (원본) | 전송 해상도 상한. 예: `3840`, `2560`. 5K가 버벅이면 줄여 보세요 |
| `hiDPI` | true | false면 픽셀 1:1 (글자가 작게 보임) |

## 문제 해결

- **화면 기록 권한 오류 / 메뉴 막대에 ⚠️ 표시**: 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 iMacDisplay Sender를 허용하고, 메뉴의 "앱 다시 시작"을 누르세요. 목록에 켜져 있는데도 안 되면 0.2.0 이하 버전의 권한이 남아 있는 것입니다. 아래 명령으로 초기화한 뒤 다시 허용하세요(0.2.1부터는 업데이트해도 권한이 유지됩니다).
  `tccutil reset ScreenCapture com.waps2k.imacdisplay.sender`
- **끊기거나 깨짐**: `maxWidth 3840`처럼 해상도를 낮추거나 `bitrate`를 조절해 보세요. iMac 2017 디코더가 5K HEVC를 버거워할 수 있습니다.
- **iMac을 못 찾음**: `host`로 IP를 직접 지정하세요. iMac 대기 화면에 연결 종류별 IP가 표시됩니다.
- **썬더볼트로 안 바뀜**: 시스템 설정 → 네트워크에서 "Thunderbolt 브리지"가 초록색(연결됨)인지 확인하세요. 케이블이 썬더볼트 규격인지도 확인하세요.
- **지연 시간이 안 보임**: iMac의 Receiver도 0.2 이상으로 업데이트하세요.
- **로그 보기**: 앱 안의 실행 파일을 터미널에서 직접 실행하면 로그가 출력됩니다.

## 구조

```
Sources/
  Wire/                    공용 메시지 프로토콜 (길이 접두 TCP 프레이밍)
  CGVirtualDisplayPrivate/ 비공개 가상 디스플레이 API 헤더
  Sender/                  가상 디스플레이, 캡처, 인코딩, 연결 관리
  Receiver/                Bonjour 서버, 디코딩·표시 (AVSampleBufferDisplayLayer)
```

## 로드맵

- [ ] 실기기 테스트 및 5K/60Hz 튜닝
- [x] 연결 우선순위(썬더볼트 → 유선 → Wi-Fi)와 자동 전환
- [x] 메뉴 막대에 연결 종류와 속도 표시
- [ ] 메뉴에서 해상도·비트레이트 변경
- [ ] 오디오 전송
- [ ] iMac 밝기 조절
- [ ] 미러링 모드

## 라이선스

[MIT](LICENSE) © 2026 Joungyong
