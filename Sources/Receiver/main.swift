import AppKit
import IOKit.pwr_mgt
import Wire

/// 테두리 없는 창도 키 입력(⌘Q)을 받을 수 있게 한다.
final class FullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: FullScreenWindow!
    private let renderer = VideoRenderer()
    private let statusLabel = NSTextField(labelWithString: "")
    private var server: ReceiverServer!
    private var sleepAssertion: IOPMAssertionID = 0
    private var statusText = "시작 중…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = FullScreenWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = CGColor.black
        renderer.layer.frame = content.bounds
        renderer.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        renderer.layer.contentsScale = screen.backingScaleFactor
        content.layer?.addSublayer(renderer.layer)

        statusLabel.font = .systemFont(ofSize: 22, weight: .medium)
        statusLabel.textColor = NSColor(white: 0.85, alpha: 1)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.8),
        ])

        window.contentView = content
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.setHiddenUntilMouseMoves(true)

        // 수신 중에는 화면이 꺼지지 않게 한다.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "iMac Display 수신 중" as CFString, &sleepAssertion)

        let hello = makeHello(screen: screen)
        log("화면: \(hello.pixelWidth)x\(hello.pixelHeight)px, scale \(hello.scale), \(Int(hello.widthMillimeters))x\(Int(hello.heightMillimeters))mm")

        server = ReceiverServer(hello: hello)
        server.onStatus = { [weak self] text in
            self?.statusText = text
            self?.refreshStatusLabel()
        }
        server.onConnected = { [weak self] in self?.renderer.reset() }
        server.onDisconnected = { [weak self] in
            self?.renderer.reset()
            self?.statusLabel.isHidden = false
        }
        server.onFormat = { [weak self] format in self?.renderer.setFormat(format) }
        server.onFrame = { [weak self] frame in
            self?.statusLabel.isHidden = true
            self?.renderer.enqueue(frame)
        }
        renderer.onNeedKeyframe = { [weak self] in self?.server.requestKeyframe() }

        do {
            try server.start()
        } catch {
            statusText = "서버를 시작할 수 없습니다: \(error)"
        }
        refreshStatusLabel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func refreshStatusLabel() {
        let addresses = localIPv4Addresses().map { "\($0.interface)  \($0.address)" }.joined(separator: "\n")
        statusLabel.stringValue = """
        iMac Display 수신기
        \(statusText)

        \(addresses)

        맥북에서 Sender를 실행하세요 · 종료: ⌘Q
        """
    }

    private func makeHello(screen: NSScreen) -> Hello {
        let scale = screen.backingScaleFactor
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        var mm = CGDisplayScreenSize(displayID)
        if mm.width <= 0 { mm = CGSize(width: 597, height: 336) } // 27인치 기본값
        return Hello(
            name: Host.current().localizedName ?? "iMac",
            pixelWidth: Int(screen.frame.width * scale),
            pixelHeight: Int(screen.frame.height * scale),
            scale: scale,
            widthMillimeters: mm.width,
            heightMillimeters: mm.height)
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

/// 연결 안내용 IPv4 주소 목록. 썬더볼트 브릿지는 보통 bridge0으로 보인다.
func localIPv4Addresses() -> [(interface: String, address: String)] {
    var result: [(String, String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let entry = pointer.pointee
        guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            result.append((String(cString: entry.ifa_name), String(cString: host)))
        }
    }
    return result
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
