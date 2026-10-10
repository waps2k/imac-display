import Foundation
import Network
import Wire

/// 수신기를 찾아 연결하고, 연결이 끊기면 정리 후 다시 연결한다.
final class SenderController {
    var onStatus: ((String) -> Void)?

    private let options: SenderOptions
    private let queue = DispatchQueue(label: "net", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: MessageConnection?
    private var session: StreamSession?

    init(options: SenderOptions) {
        self.options = options
    }

    func start() {
        queue.async { self.connect() }
    }

    private func connect() {
        let params = MessageConnection.tcpParameters(prohibitWiFi: options.wiredOnly)
        if let host = options.host {
            open(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: options.port)!))
            return
        }
        status("iMac 찾는 중…")
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let result = results.first else { return }
            self.browser?.cancel()
            self.browser = nil
            self.open(result.endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func open(_ endpoint: NWEndpoint) {
        status("연결 중: \(endpoint)")
        let params = MessageConnection.tcpParameters(prohibitWiFi: options.wiredOnly)
        let conn = MessageConnection(connection: NWConnection(to: endpoint, using: params), queue: queue)
        var ready = false
        conn.onReady = { [weak self] in
            ready = true
            self?.status("연결됨: \(endpoint)")
        }
        conn.onMessage = { [weak self, weak conn] type, data in
            guard let self, let conn else { return }
            self.handle(type, data, from: conn)
        }
        conn.onClose = { [weak self] error in
            guard let self else { return }
            log("연결 종료\(error.map { ": \($0)" } ?? "")")
            self.connection = nil
            self.teardown()
            self.queue.asyncAfter(deadline: .now() + 2) { self.connect() }
        }
        connection = conn
        conn.start()

        // 주소가 틀렸거나 수신기가 꺼져 있으면 NWConnection이 계속 대기하므로 직접 끊고 재시도한다.
        queue.asyncAfter(deadline: .now() + 5) { [weak conn] in
            if !ready { conn?.cancel() }
        }
    }

    private func handle(_ type: MessageType, _ data: Data, from conn: MessageConnection) {
        switch type {
        case .hello:
            guard let hello = try? JSONDecoder().decode(Hello.self, from: data) else { return }
            // 가상 디스플레이는 메인 스레드에서 만든다.
            DispatchQueue.main.async {
                self.stopSession()
                do {
                    let session = try StreamSession(hello: hello, options: self.options, connection: conn)
                    self.session = session
                    Task {
                        do {
                            try await session.start()
                            self.status("전송 중 → \(hello.name)")
                        } catch {
                            self.status("오류: \(error)")
                            conn.cancel()
                        }
                    }
                } catch {
                    self.status("오류: \(error)")
                    conn.cancel()
                }
            }
        case .requestKeyframe:
            DispatchQueue.main.async { self.session?.requestKeyframe() }
        case .format, .frame:
            break
        }
    }

    private func teardown() {
        DispatchQueue.main.async { self.stopSession() }
    }

    /// 메인 스레드에서 호출. 세션이 해제되면 가상 디스플레이도 사라진다.
    private func stopSession() {
        session?.stop()
        session = nil
    }

    private func status(_ text: String) {
        log(text)
        DispatchQueue.main.async { self.onStatus?(text) }
    }
}
