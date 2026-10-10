import AppKit
import Wire

/// 메뉴 막대에만 아이콘을 띄우는 송신 앱.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "시작 중…", action: nil, keyEquivalent: "")
    private var controller: SenderController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "iMac Display")

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        let options = SenderOptions.load()
        log("설정: host=\(options.host ?? "자동") codec=\(options.codec) bitrate=\(options.bitrateMbps)Mbps fps=\(options.fps) maxWidth=\(options.maxWidth) wiredOnly=\(options.wiredOnly)")
        controller = SenderController(options: options)
        controller.onStatus = { [weak self] text in self?.statusLine.title = text }
        controller.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
