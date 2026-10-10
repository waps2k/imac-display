import Foundation
import Network
import os

/// NWConnection 위에 길이 접두 메시지를 주고받는 얇은 래퍼.
/// 모든 콜백은 생성 시 넘긴 큐에서 호출된다.
public final class MessageConnection {
    public let connection: NWConnection
    public let queue: DispatchQueue

    public var onReady: (() -> Void)?
    public var onMessage: ((MessageType, Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private let sent = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var closed = false

    /// 아직 커널로 넘어가지 않은 전송 수. 송신 측 백프레셔에 사용한다.
    public var pendingSends: Int { pending.withLock { $0 } }

    /// 지금까지 보낸 바이트 수 (헤더 포함). 전송 속도 표시에 사용한다.
    public var bytesSent: UInt64 { sent.withLock { $0 } }

    /// 연결이 실제로 사용 중인 네트워크 인터페이스.
    public var currentInterface: NWInterface? {
        connection.currentPath?.availableInterfaces.first
    }

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public static func tcpParameters(prohibitWiFi: Bool = false, interface: NWInterface? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        if prohibitWiFi {
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
        }
        if let interface {
            params.requiredInterface = interface
        }
        return params
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveHeader()
            case .waiting(let error):
                log("연결 대기 중: \(error)")
            case .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    public func send(_ type: MessageType, _ payload: Data = Data()) {
        var header = Data([type.rawValue])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { header.append(contentsOf: $0) }
        pending.withLock { $0 += 1 }
        let total = UInt64(header.count + payload.count)
        sent.withLock { $0 += total }
        connection.batch {
            connection.send(content: header, completion: .idempotent)
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                self?.pending.withLock { $0 -= 1 }
                if let error { self?.finish(error) }
            })
        }
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            guard let data, data.count == 5 else {
                return self.finish(isComplete ? nil : ConnectionError.malformed)
            }
            let typeRaw = data[data.startIndex]
            let length = data.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            guard let type = MessageType(rawValue: typeRaw), length <= 64 << 20 else {
                return self.finish(ConnectionError.malformed)
            }
            if length == 0 {
                self.onMessage?(type, Data())
                self.receiveHeader()
            } else {
                self.receivePayload(type, length)
            }
        }
    }

    private func receivePayload(_ type: MessageType, _ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            guard let data, data.count == length else { return self.finish(ConnectionError.malformed) }
            self.onMessage?(type, data)
            self.receiveHeader()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }
}

public enum ConnectionError: Error {
    case malformed
}

public func log(_ message: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(message)")
    fflush(stdout)
}
