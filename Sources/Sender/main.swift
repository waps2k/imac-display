import AppKit
import Wire

/// 메뉴 막대에만 아이콘을 띄우는 송신 앱.
/// 아이콘은 연결 종류(썬더볼트/유선/Wi-Fi)를, 옆 숫자는 실제 전송 속도를 나타낸다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let phaseLine = NSMenuItem(title: tr("시작 중…", "Starting…"), action: nil, keyEquivalent: "")
    private let linkLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let speedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let videoLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let tipLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let openPrivacyItem = NSMenuItem(title: tr("화면 기록 설정 열기…", "Open Screen Recording Settings…"), action: #selector(openScreenRecordingSettings), keyEquivalent: "")
    private let relaunchItem = NSMenuItem(title: tr("허용했으면 앱 다시 시작", "Restart App After Allowing"), action: #selector(relaunch), keyEquivalent: "")
    private var controller: SenderController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let menu = NSMenu()
        for line in [phaseLine, linkLine, speedLine, videoLine, tipLine] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(openPrivacyItem)
        menu.addItem(relaunchItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("연결 가이드…", "Connection Guide…"), action: #selector(showGuide), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("종료", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let ownActions = [#selector(showGuide), #selector(openScreenRecordingSettings), #selector(relaunch)]
        menu.items.forEach { if let action = $0.action, ownActions.contains(action) { $0.target = self } }
        statusItem.menu = menu

        let options = SenderOptions.load()
        log(tr("설정", "Settings") + ": host=\(options.host ?? "auto") codec=\(options.codec) bitrate=\(options.bitrateMbps.map { "\($0)Mbps" } ?? "auto") fps=\(options.fps) maxWidth=\(options.maxWidth) wiredOnly=\(options.wiredOnly)")
        controller = SenderController(options: options)
        controller.onUpdate = { [weak self] status in self?.render(status) }
        render(controller.status)
        controller.start()
    }

    private func render(_ s: LinkStatus) {
        openPrivacyItem.isHidden = !s.needsScreenPermission
        relaunchItem.isHidden = !s.needsScreenPermission
        let symbol = s.needsScreenPermission ? "exclamationmark.triangle"
            : s.connected ? (s.kind ?? .other).symbolName : "display.2"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "iMac Display")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = s.connected ? " " + compactRate(s.throughputBps) : ""
        statusItem.button?.appearsDisabled = !s.connected

        phaseLine.title = s.phase

        if let kind = s.kind {
            var link = tr("연결", "Link") + ": \(kind)"
            if let name = s.interfaceName { link += " (\(name))" }
            if let speed = s.linkSpeedBps { link += " · " + tr("링크", "link") + " \(formatBitRate(Double(speed)))" }
            linkLine.title = link
        }
        linkLine.isHidden = s.kind == nil

        var speed = tr("전송", "Sending") + ": \(formatBitRate(s.throughputBps)) · \(Int(s.fps.rounded())) fps"
        if let rtt = s.rttMs { speed += " · " + tr("지연", "latency") + " \(String(format: "%.1f", rtt)) ms" }
        if s.skippedPerSecond >= 1 { speed += " · " + tr("건너뜀", "skipped") + " \(Int(s.skippedPerSecond))/s" }
        speedLine.title = speed
        speedLine.isHidden = !s.connected

        if let resolution = s.resolution {
            videoLine.title = tr("화면", "Display") + ": \(resolution)" + (s.bitrateMbps.map { " · " + tr("목표", "target") + " \($0) Mbps" } ?? "")
        }
        videoLine.isHidden = !s.connected || s.resolution == nil

        switch s.kind {
        case .wifi?:
            tipLine.title = tr("💡 썬더볼트 케이블로 연결하면 더 빠르고 안정적입니다", "💡 A Thunderbolt cable is faster and more stable")
        case .ethernet?:
            tipLine.title = tr("💡 썬더볼트로 연결하면 더 빠릅니다 (자동 전환)", "💡 Thunderbolt is faster (switches automatically)")
        default:
            tipLine.title = ""
        }
        tipLine.isHidden = !s.connected || tipLine.title.isEmpty
    }

    /// 메뉴 막대용 짧은 표기: "48M", "1.2G"
    private func compactRate(_ bps: Double) -> String {
        if bps >= 1e9 { return String(format: "%.1fG", bps / 1e9) }
        return "\(Int((bps / 1e6).rounded()))M"
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// 화면 기록 권한은 앱을 다시 시작해야 적용된다.
    @objc private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func showGuide() {
        let alert = NSAlert()
        alert.messageText = tr("iMac Display 연결 가이드", "iMac Display Connection Guide")
        alert.informativeText = tr("""
        사용 가능한 연결 중 가장 빠른 경로를 자동으로 고릅니다. 연결된 뒤에도 더 빠른 경로가 생기면 화면이 끊기지 않게 자동으로 전환합니다.

        ① 썬더볼트 (권장, 최대 10~40 Gbps)
        썬더볼트 3/4 케이블(⚡ 표시)로 맥북과 iMac을 직접 연결하세요. 따로 설정할 필요가 없습니다(썬더볼트 브리지가 자동으로 잡힘). 일반 USB-C 충전 케이블은 느리거나 동작하지 않습니다.

        ② 유선 랜 (1 Gbps 이상)
        두 Mac을 같은 공유기/스위치에 랜선으로 연결하세요. 맥북은 USB-C 랜 어댑터를 쓰면 됩니다.

        ③ Wi-Fi
        같은 Wi-Fi에 연결하면 동작하지만 화질과 반응 속도가 떨어집니다. 5GHz 대역이나 Wi-Fi 6을 권장합니다.

        메뉴 막대 아이콘: ⚡ 썬더볼트 · 🔌 유선 · 📶 Wi-Fi, 옆 숫자는 실제 전송 속도입니다.

        문의 및 버그 제보: \(developerEmail)
        """, """
        The app automatically uses the fastest available path. If a faster path appears after connecting, it switches over without dropping the display.

        ① Thunderbolt (recommended, up to 10–40 Gbps)
        Connect the MacBook and the iMac directly with a Thunderbolt 3/4 cable (marked ⚡). No setup is needed — Thunderbolt Bridge is configured automatically. A regular USB-C charging cable is slow or won't work.

        ② Ethernet (1 Gbps or more)
        Plug both Macs into the same router/switch with a LAN cable. On the MacBook, use a USB-C Ethernet adapter.

        ③ Wi-Fi
        Works on the same Wi-Fi network, but with lower quality and higher latency. 5 GHz or Wi-Fi 6 is recommended.

        Menu bar icon: ⚡ Thunderbolt · 🔌 Ethernet · 📶 Wi-Fi. The number next to it is the actual throughput.

        Questions and bug reports: \(developerEmail)
        """)
        alert.addButton(withTitle: tr("확인", "OK"))
        alert.addButton(withTitle: tr("개발자에게 메일 보내기", "Email the Developer"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "mailto:\(developerEmail)?subject=iMac%20Display")!)
        }
    }
}

/// 연결 가이드에 표시하는 개발자 연락처
let developerEmail = "waps99@gmail.com"

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
