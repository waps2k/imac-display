import AppKit
import Network
import Wire

/// Bonjour로 자신을 알리고 송신기 연결을 기다린다. 한 번에 하나의 송신기만 받는다.
final class ReceiverServer {
    var onStatus: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onFormat: ((VideoFormat) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?

    private let queue = DispatchQueue(label: "net", qos: .userInteractive)
    private let hello: Hello
    private var listener: NWListener?
    private var connection: MessageConnection?

    init(hello: Hello) {
        self.hello = hello
    }

    func start() throws {
        let listener = try NWListener(using: MessageConnection.tcpParameters(),
                                      on: NWEndpoint.Port(rawValue: defaultPort)!)
        listener.service = NWListener.Service(name: hello.name, type: serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.status("대기 중")
            case .failed(let error): self?.status("서버 오류: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func requestKeyframe() {
        queue.async { self.connection?.send(.requestKeyframe) }
    }

    private func accept(_ nw: NWConnection) {
        // 새 송신기가 오면 이전 연결은 끊는다.
        connection?.cancel()
        let conn = MessageConnection(connection: nw, queue: queue)
        conn.onReady = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.status("연결됨: \(nw.endpoint)")
            if let data = try? JSONEncoder().encode(self.hello) {
                conn.send(.hello, data)
            }
            DispatchQueue.main.async { self.onConnected?() }
        }
        conn.onMessage = { [weak self] type, data in
            guard let self else { return }
            switch type {
            case .format:
                if let format = VideoFormat(data) {
                    DispatchQueue.main.async { self.onFormat?(format) }
                }
            case .frame:
                if let frame = VideoFrame(data) {
                    DispatchQueue.main.async { self.onFrame?(frame) }
                }
            case .hello, .requestKeyframe:
                break
            }
        }
        conn.onClose = { [weak self, weak conn] error in
            guard let self, let conn, self.connection === conn else { return }
            self.connection = nil
            self.status("연결 끊김\(error.map { ": \($0)" } ?? "") — 대기 중")
            DispatchQueue.main.async { self.onDisconnected?() }
        }
        connection = conn
        conn.start()
    }

    private func status(_ text: String) {
        log(text)
        DispatchQueue.main.async { self.onStatus?(text) }
    }
}
