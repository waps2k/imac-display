# iMac Display

**English** | [한국어](README.ko.md)

A free, open-source app that turns an older iMac (e.g. iMac 2017 27" 5K) into an **extended display** for your MacBook.
It works in software, so it runs on iMacs that don't support Target Display Mode.

```
[MacBook: Sender]                                          [iMac: Receiver]
Virtual display → ScreenCaptureKit capture → HEVC hardware encode
                     ──── Thunderbolt Bridge / Ethernet / Wi-Fi (TCP) ────▶
                                          HEVC hardware decode → full-screen view
```

- Adds a **virtual display** to your MacBook that behaves like a real monitor. You can drag windows onto it and arrange it in System Settings.
- You keep using the MacBook's own keyboard and mouse.
- Matches the iMac's native resolution automatically (5120×2880 HiDPI on a 5K iMac).
- Finds the iMac via Bonjour and picks the fastest path in this order: **Thunderbolt → Ethernet → Wi-Fi**.
- If a faster path becomes available while connected, it switches over automatically and keeps the virtual display in place.
- The menu bar shows the connection type, link speed, actual throughput, fps, and latency.

> ⚠️ This project is experimental. The virtual display uses Apple's **private API** (`CGVirtualDisplay`), so it may break after a macOS update.
>
> The app's own interface (menu bar and iMac waiting screen) is currently in Korean.

## Install

To use it without developer tools, download two files from the [latest release](https://github.com/waps2k/imac-display/releases/latest).

- `iMacDisplay-Sender-x.y.z.zip` → unzip on your **MacBook** and move it to Applications
- `iMacDisplay-Receiver-x.y.z.zip` → unzip on your **iMac** and move it to Applications

The apps are not notarized by Apple, so macOS may warn about an "unidentified developer" the first time. Right-click the app and choose **Open**, or run the following in Terminal.

```bash
xattr -dr com.apple.quarantine "/Applications/iMacDisplay Sender.app"     # MacBook
xattr -dr com.apple.quarantine "/Applications/iMacDisplay Receiver.app"   # iMac
```

## Requirements

| | Sender | Receiver |
|---|---|---|
| Device | MacBook or other Mac (Apple Silicon recommended) | iMac or any Mac |
| macOS | 13 or later | 13 or later (iMac 2017 on Ventura works) |
| Permissions | Screen Recording, Local Network | Local Network |

## Build from source

Requires Xcode (or the Command Line Tools).

```bash
./scripts/build-apps.sh
```

This creates two Universal (Intel + Apple Silicon) apps in `dist/`.

- `iMacDisplay Sender.app` → MacBook
- `iMacDisplay Receiver.app` → copy to the iMac

A single command builds a new version and publishes it as a GitHub release with the binaries attached.

```bash
./scripts/release.sh 0.2.2 "Release notes"
```

## Connection guide

The app automatically uses the fastest available path. Connect every option you can, and the app picks the best one.

| Priority | Connection | Speed | How |
|---|---|---|---|
| ① | **Thunderbolt** (recommended) | 10–40 Gbps | Connect the two Macs directly with a Thunderbolt 3/4 cable (⚡). No setup needed |
| ② | **Ethernet** | 1 Gbps or more | Plug both Macs into the same router/switch with a LAN cable (use a USB-C Ethernet adapter on the MacBook) |
| ③ | **Wi-Fi** | Varies | Join the same Wi-Fi network. 5 GHz or Wi-Fi 6 is recommended |

- Thunderbolt Bridge assigns a link-local address (169.254.x.x) automatically as soon as the cable is plugged in, and Bonjour discovery works over it.
- A regular USB-C charging cable may not reach Thunderbolt speeds, or may not connect at all.
- The bitrate is chosen automatically by connection type: Thunderbolt 120 / Ethernet 60 / Wi-Fi 25 Mbps.
- If you plug in a Thunderbolt cable while connected over Wi-Fi, the app switches to Thunderbolt within a few seconds. After a brief disconnect, the virtual display and window layout are kept for 15 seconds.

### Menu bar

```
⚡ 87M          ← icon: connection type (⚡ Thunderbolt · 🔌 Ethernet · 📶 Wi-Fi), number: actual throughput
───────────────
Streaming → iMac
Link: Thunderbolt (bridge0) · 20 Gbps
Sending: 87.3 Mbps · 60 fps · latency 1.4 ms
Display: 5120×2880 HEVC · target 120 Mbps
```

(The menu text in the app is in Korean. The lines above are translated.)

## Usage

1. On the **iMac**, launch `iMacDisplay Receiver`. The screen turns into a black waiting screen that shows the iMac's IP addresses. Press ⌘Q to quit.
2. On the **MacBook**, launch `iMacDisplay Sender`. An icon appears in the menu bar.
   - On first launch it asks for **Screen Recording** permission. Grant it, then choose **Restart app** (앱 다시 시작) from the menu bar menu.
3. On the MacBook, arrange the iMac display in System Settings → Displays.

### Options

Settings can be passed as command-line arguments or stored with `defaults`.

```bash
# One-time
"dist/iMacDisplay Sender.app/Contents/MacOS/Sender" -host 10.0.0.1 -bitrate 80

# Persistent
defaults write com.waps2k.imacdisplay.sender host 10.0.0.1
defaults write com.waps2k.imacdisplay.sender bitrate -int 80
```

| Key | Default | Description |
|---|---|---|
| `host` | (auto-discover) | Receiver IP. When set, automatic path selection and switching are turned off |
| `port` | 52020 | |
| `wiredOnly` | false | When true, Wi-Fi is never used |
| `codec` | hevc | `hevc` or `h264` (use H.264 only at 4K or below) |
| `bitrate` | (auto) | Mbps. If not set, it follows the connection type (Thunderbolt 120 / Ethernet 60 / Wi-Fi 25) |
| `fps` | 60 | |
| `maxWidth` | 0 (native) | Upper limit for the streamed width, e.g. `3840` or `2560`. Lower it if 5K stutters |
| `hiDPI` | true | When false, pixels map 1:1 (text looks small) |

## Troubleshooting

- **Screen Recording error / ⚠️ in the menu bar**: Allow iMacDisplay Sender in System Settings → Privacy & Security → Screen & System Audio Recording, then choose **Restart app** from the menu. If it still fails while the toggle is on, a permission record from version 0.2.0 or earlier is left over. Reset it with the command below and allow it again (from 0.2.1 on, the permission survives updates).
  `tccutil reset ScreenCapture com.waps2k.imacdisplay.sender`
- **Stuttering or artifacts**: Lower the resolution (for example `maxWidth 3840`) or adjust `bitrate`. The iMac 2017 decoder may struggle with 5K HEVC.
- **The iMac isn't found**: Set its IP with `host`. The iMac's waiting screen lists its IP for each connection type.
- **It doesn't switch to Thunderbolt**: In System Settings → Network, check that "Thunderbolt Bridge" is green (connected), and that the cable is a Thunderbolt cable.
- **Latency isn't shown**: Update the iMac's Receiver to 0.2 or later as well.
- **Viewing logs**: Run the executable inside the app bundle from Terminal to see its log output.

## Project layout

```
Sources/
  Wire/                    Shared message protocol (length-prefixed TCP framing)
  CGVirtualDisplayPrivate/ Header for the private virtual display API
  Sender/                  Virtual display, capture, encoding, connection management
  Receiver/                Bonjour server, decoding and display (AVSampleBufferDisplayLayer)
```

## Roadmap

- [ ] Real-device testing and 5K/60 Hz tuning
- [x] Connection priority (Thunderbolt → Ethernet → Wi-Fi) with automatic switching
- [x] Connection type and speed in the menu bar
- [ ] Change resolution and bitrate from the menu
- [ ] Audio streaming
- [ ] iMac brightness control
- [ ] Mirroring mode
- [ ] English app interface

## License

[MIT](LICENSE) © 2026 Joungyong
