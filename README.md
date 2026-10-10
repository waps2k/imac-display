# iMac Display

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
- Bonjour로 iMac을 자동으로 찾습니다. 주소를 직접 지정할 수도 있습니다.

> ⚠️ 0.1 버전(실험 단계)입니다. 가상 디스플레이는 애플의 **비공개 API**(`CGVirtualDisplay`)를 사용하므로 macOS 업데이트 후 동작하지 않을 수 있습니다.

## 요구 사항

| | 송신 (Sender) | 수신 (Receiver) |
|---|---|---|
| 기기 | 맥북 등 (Apple Silicon 권장) | iMac 등 아무 Mac |
| macOS | 13 이상 | 13 이상 (iMac 2017 + Ventura OK) |
| 권한 | 화면 기록, 로컬 네트워크 | 로컬 네트워크 |

빌드하려면 Xcode(또는 Command Line Tools)가 필요합니다.

## 빌드

```bash
./scripts/build-apps.sh
```

`dist/`에 Universal(Intel + Apple Silicon) 앱 두 개가 생깁니다.

- `iMacDisplay Sender.app` → 맥북
- `iMacDisplay Receiver.app` → iMac으로 복사

## 연결: 썬더볼트 브릿지 (권장)

썬더볼트 케이블(⚡ 표시)로 두 Mac을 연결하면 10Gbps 이상의 직접 네트워크가 생깁니다.
별도 설정 없이 링크 로컬 주소(169.254.x.x)가 자동으로 잡히고, Bonjour 검색도 됩니다.
고정 주소를 쓰고 싶다면 아래처럼 설정하세요.

- 시스템 설정 → 네트워크 → Thunderbolt 브리지 → 세부사항 → TCP/IP → 수동
- iMac: `10.0.0.1` / 맥북: `10.0.0.2`, 서브넷 `255.255.255.0`

## 사용법

1. **iMac**에서 `iMacDisplay Receiver`를 실행합니다. 화면이 검은 대기 화면으로 바뀌고 IP 주소가 표시됩니다. 종료는 ⌘Q입니다.
   - 다른 Mac에서 복사해 온 앱이 열리지 않으면 터미널에서 다음을 실행하세요.
     `xattr -dr com.apple.quarantine "/Applications/iMacDisplay Receiver.app"`
2. **맥북**에서 `iMacDisplay Sender`를 실행합니다. 메뉴 막대에 🖥 아이콘이 생깁니다.
   - 처음 실행하면 **화면 기록** 권한을 요청합니다. 허용한 뒤 Sender를 다시 실행하세요.
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
| `host` | (자동 검색) | 수신기 IP. Wi-Fi와 썬더볼트가 둘 다 연결돼 있다면 썬더볼트 쪽 IP 지정을 권장합니다 |
| `port` | 52020 | |
| `wiredOnly` | false | true면 Wi-Fi를 사용하지 않습니다 |
| `codec` | hevc | `hevc` 또는 `h264` (H.264는 4K 이하에서만 사용하세요) |
| `bitrate` | 40 | Mbps. 썬더볼트는 80~150, Wi-Fi는 20~40 정도가 적당합니다 |
| `fps` | 60 | |
| `maxWidth` | 0 (원본) | 전송 해상도 상한. 예: `3840`, `2560`. 5K가 버벅이면 줄여 보세요 |
| `hiDPI` | true | false면 픽셀 1:1 (글자가 작게 보임) |

## 문제 해결

- **검은 화면만 나옴**: Sender의 화면 기록 권한을 확인하세요. 빌드할 때마다 서명이 바뀌어 권한이 다시 필요할 수 있습니다.
- **끊기거나 깨짐**: `maxWidth 3840`처럼 해상도를 낮추거나 `bitrate`를 조절해 보세요. iMac 2017 디코더가 5K HEVC를 버거워할 수 있습니다.
- **iMac을 못 찾음**: `host`로 IP를 직접 지정하세요. iMac 대기 화면에 IP가 표시됩니다. 썬더볼트 브릿지는 보통 `bridge0`입니다.
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
- [ ] 메뉴에서 해상도·비트레이트 변경
- [ ] 오디오 전송
- [ ] iMac 밝기 조절
- [ ] 미러링 모드
