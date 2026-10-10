import CoreWLAN
import Foundation
import Network
import ScreenCaptureKit
import Wire

/// 메뉴 막대에 표시할 상태. 메인 스레드에서만 읽고 쓴다.
struct LinkStatus {
    var phase = tr("시작 중…", "Starting…")
    var connected = false
    var kind: LinkKind?
    var interfaceName: String?
    var linkSpeedBps: UInt64?
    var receiverName: String?
    var resolution: String?
    var bitrateMbps: Int?
    var throughputBps: Double = 0
    var fps: Double = 0
    var skippedPerSecond: Double = 0
    var rttMs: Double?
    /// 화면 기록 권한이 없어 전송할 수 없는 상태
    var needsScreenPermission = false
}

/// 수신기를 찾아 가장 빠른 경로(썬더볼트 → 유선 랜 → Wi-Fi)로 연결한다.
/// 연결 중에도 더 빠른 경로가 생기면 그쪽으로 옮기고, 끊기면 다시 연결한다.
final class SenderController {
    /// 연결 시도 하나에 주는 시간
    private static let attemptTimeout: TimeInterval = 3
    /// 실패한 인터페이스로 다시 업그레이드를 시도하기까지의 간격
    private static let upgradeBackoff: TimeInterval = 30
    /// 연결이 끊겨도 이 시간 동안은 가상 디스플레이(창 배치)를 유지한다
    private static let sessionGracePeriod: TimeInterval = 15

    var onUpdate: ((LinkStatus) -> Void)?
    private(set) var status = LinkStatus()

    private let options: SenderOptions
    private let queue = DispatchQueue(label: "net", qos: .userInteractive)

    // MARK: net 큐 상태
    private struct ActiveLink {
        let conn: MessageConnection
        let kind: LinkKind
        let interfaceName: String?
        var supportsPing = false
    }
    private let monitor = NWPathMonitor()
    private var browser: NWBrowser?
    private var service: NWEndpoint?
    private var serviceInterfaces: [NWInterface] = []
    private var available: [NWInterface] = []
    private var active: ActiveLink?
    private var attempt: MessageConnection?
    private var failedAt: [String: Date] = [:]
    /// 이 시각까지는 새로 연결하지 않는다 (오류 후 재시도 간격, 권한 없음이면 무기한)
    private var pausedUntil = Date.distantPast
    private var tick: DispatchSourceTimer?

    // MARK: 메인 스레드 상태
    private var session: StreamSession?
    private var sessionConn: MessageConnection?
    private var pendingStop: DispatchWorkItem?
    private var lastSample: (time: Date, conn: ObjectIdentifier, bytes: UInt64, sent: UInt64, skipped: UInt64)?

    init(options: SenderOptions) {
        self.options = options
    }

    func start() {
        // 화면 기록 권한이 없으면 연결하지 않는다. 연결부터 하면 가상 디스플레이만 생겼다 사라지기를 반복한다.
        guard CGPreflightScreenCaptureAccess() else {
            log(tr("화면 기록 권한이 없습니다. 시스템 설정에서 허용한 뒤 앱을 다시 시작하세요", "Screen Recording permission is missing. Allow it in System Settings, then restart the app"))
            CGRequestScreenCaptureAccess()
            status.needsScreenPermission = true
            status.phase = tr("화면 기록 권한이 필요합니다", "Screen Recording permission required")
            onUpdate?(status)
            return
        }

        monitor.pathUpdateHandler = { [weak self] path in
            self?.available = path.availableInterfaces
            self?.evaluate()
        }
        monitor.start(queue: queue)

        queue.async {
            if self.options.host == nil { self.startBrowser() }
            self.evaluate()
        }

        // 1초마다: 지연 측정, 재연결/업그레이드 판단
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
            self?.evaluate()
        }
        timer.resume()
        tick = timer

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStats() }
        publish { $0.phase = self.options.host == nil ? tr("iMac 찾는 중…", "Looking for the iMac…") : tr("연결 중", "Connecting") + ": \(self.options.host!)" }
    }

    // MARK: - 검색과 연결 (net 큐)

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: NWParameters.tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let chosen = results.first { $0.endpoint == self.service } ?? results.first
            self.service = chosen?.endpoint
            self.serviceInterfaces = chosen?.interfaces ?? []
            if let chosen {
                log(tr("수신기 발견", "Receiver found") + ": \(chosen.endpoint) (" + tr("인터페이스", "interfaces") + ": \(chosen.interfaces.map(\.name).joined(separator: ", ")))")
            }
            self.evaluate()
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// 지금 무엇을 해야 하는지 판단한다: 첫 연결, 재연결, 더 빠른 경로로 업그레이드.
    private func evaluate() {
        guard attempt == nil, Date() >= pausedUntil else { return }

        if let host = options.host {
            guard active == nil else { return }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: options.port)!)
            tryConnect(endpoint, candidates: [nil], index: 0, upgrade: false)
            return
        }

        guard let service else { return }
        let names = NetworkInterfaces.displayNames()
        let candidates = rankedCandidates(names: names)

        if let active {
            guard let best = candidates.first,
                  NetworkInterfaces.kind(of: best, displayNames: names) < active.kind,
                  Date().timeIntervalSince(failedAt[best.name] ?? .distantPast) > Self.upgradeBackoff
            else { return }
            log(tr("더 빠른 경로 발견", "Faster path found") + ": \(NetworkInterfaces.kind(of: best, displayNames: names)) (\(best.name)) — " + tr("전환 시도", "switching"))
            tryConnect(service, candidates: [best], index: 0, upgrade: true)
        } else {
            // 우선순위대로 시도하고, 마지막으로 시스템 기본 경로도 시도한다.
            tryConnect(service, candidates: candidates.map { Optional($0) } + [nil], index: 0, upgrade: false)
        }
    }

    /// 수신기가 보이는 인터페이스를 우선순위 순으로 정렬한다.
    private func rankedCandidates(names: [String: String]) -> [NWInterface] {
        let pool = serviceInterfaces.isEmpty ? available : serviceInterfaces
        var seen = Set<String>()
        return pool
            .filter { $0.type != .loopback && seen.insert($0.name).inserted }
            .filter { !(options.wiredOnly && NetworkInterfaces.kind(of: $0, displayNames: names) == .wifi) }
            .sorted { NetworkInterfaces.kind(of: $0, displayNames: names) < NetworkInterfaces.kind(of: $1, displayNames: names) }
    }

    private func tryConnect(_ endpoint: NWEndpoint, candidates: [NWInterface?], index: Int, upgrade: Bool) {
        guard index < candidates.count else {
            if active == nil { publish { $0.phase = tr("수신기에 연결할 수 없음 — 재시도 중", "Can't reach the receiver — retrying") } }
            return
        }
        let interface = candidates[index]
        let params = MessageConnection.tcpParameters(prohibitWiFi: options.wiredOnly, interface: interface)
        let conn = MessageConnection(connection: NWConnection(to: endpoint, using: params), queue: queue)
        attempt = conn

        let label = interface.map { "\(NetworkInterfaces.kind(of: $0)) (\($0.name))" } ?? tr("기본 경로", "default route")
        log(tr("연결 시도", "Trying") + ": \(label)")
        if !upgrade {
            publish { $0.phase = tr("연결 시도", "Trying") + ": \(label)" }
        }

        var ready = false
        conn.onReady = { [weak self, weak conn] in
            guard let self, let conn else { return }
            ready = true
            self.attempt = nil
            self.promote(conn)
        }
        conn.onMessage = { [weak self, weak conn] type, data in
            guard let self, let conn, self.active?.conn === conn else { return }
            self.handle(type, data, from: conn)
        }
        conn.onClose = { [weak self, weak conn] error in
            guard let self, let conn else { return }
            if self.attempt === conn {
                // 이 경로로는 연결되지 않음 → 다음 후보
                self.attempt = nil
                if let interface { self.failedAt[interface.name] = Date() }
                self.tryConnect(endpoint, candidates: candidates, index: index + 1, upgrade: upgrade)
            } else if self.active?.conn === conn {
                log(tr("연결 끊김", "Disconnected") + "\(error.map { ": \($0)" } ?? "")")
                self.active = nil
                self.connectionLost()
                self.evaluate()
            }
        }
        conn.start()

        queue.asyncAfter(deadline: .now() + Self.attemptTimeout) { [weak self, weak conn] in
            guard let self, let conn, !ready, self.attempt === conn else { return }
            conn.cancel()
        }
    }

    /// 연결 성공. 기존 연결이 있었다면(업그레이드) 끊는다.
    private func promote(_ conn: MessageConnection) {
        let interface = conn.currentInterface
        let kind = interface.map { NetworkInterfaces.kind(of: $0) } ?? .other
        let previous = active
        active = ActiveLink(conn: conn, kind: kind, interfaceName: interface?.name)
        previous?.conn.cancel()
        log(tr("연결됨", "Connected") + ": \(kind) (\(interface?.name ?? "?"))\(previous.map { " — " + tr("\($0.kind)에서 전환", "switched from \($0.kind)") } ?? "")")

        let speed = linkSpeed(kind: kind, interfaceName: interface?.name)
        publish {
            $0.kind = kind
            $0.interfaceName = interface?.name
            $0.linkSpeedBps = speed
            $0.rttMs = nil
            $0.phase = tr("연결됨 — 화면 정보 대기", "Connected — waiting for display info")
        }
    }

    private func handle(_ type: MessageType, _ data: Data, from conn: MessageConnection) {
        switch type {
        case .hello:
            guard let hello = try? JSONDecoder().decode(Hello.self, from: data), let kind = active?.kind else { return }
            active?.supportsPing = (hello.protocolVersion ?? 1) >= 2
            if hello.protocolVersion == nil {
                log(tr("수신기가 0.1 버전입니다. 지연 시간 표시를 쓰려면 iMac의 Receiver도 업데이트하세요", "The receiver is version 0.1. Update the Receiver on the iMac to see latency"))
            }
            DispatchQueue.main.async { self.startOrAttach(hello: hello, conn: conn, kind: kind) }
        case .requestKeyframe:
            DispatchQueue.main.async { self.session?.requestKeyframe() }
        case .pong:
            guard data.count == 8 else { return }
            let sentAt = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let rtt = Double(DispatchTime.now().uptimeNanoseconds &- sentAt) / 1e6
            publish { $0.rttMs = rtt }
        case .format, .frame, .ping:
            break
        }
    }

    private func sendPing() {
        guard let active, active.supportsPing else { return }
        withUnsafeBytes(of: DispatchTime.now().uptimeNanoseconds.bigEndian) {
            active.conn.send(.ping, Data($0))
        }
    }

    private func connectionLost() {
        DispatchQueue.main.async {
            self.session?.detach()
            self.sessionConn = nil
            self.status.connected = false
            self.status.phase = tr("연결 끊김 — 다시 연결하는 중", "Disconnected — reconnecting")
            self.status.throughputBps = 0
            self.status.fps = 0
            self.status.rttMs = nil
            self.onUpdate?(self.status)

            // 잠깐 끊긴 거라면 가상 디스플레이를 유지해서 창이 맥북으로 몰려오지 않게 한다.
            let work = DispatchWorkItem {
                log(tr("재연결되지 않아 가상 디스플레이를 제거합니다", "No reconnection; removing the virtual display"))
                self.stopSession()
            }
            self.pendingStop?.cancel()
            self.pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sessionGracePeriod, execute: work)
        }
    }

    // MARK: - 세션 (메인 스레드)

    private func startOrAttach(hello: Hello, conn: MessageConnection, kind: LinkKind) {
        pendingStop?.cancel()
        pendingStop = nil
        let bitrate = options.bitrateMbps ?? kind.defaultBitrateMbps

        if let session, session.hello == hello {
            // 같은 iMac에 경로만 바뀐 경우: 가상 디스플레이를 그대로 두고 연결만 교체
            session.attach(conn, bitrateMbps: bitrate)
            sessionConn = conn
            didStartStreaming(session, bitrate: bitrate)
            return
        }

        stopSession()
        do {
            let session = try StreamSession(hello: hello, options: options, bitrateMbps: bitrate)
            session.attach(conn, bitrateMbps: bitrate)
            self.session = session
            sessionConn = conn
            Task { @MainActor in
                do {
                    try await session.start()
                    self.didStartStreaming(session, bitrate: bitrate)
                } catch {
                    self.sessionFailed(error, conn: conn)
                }
            }
        } catch {
            sessionFailed(error, conn: conn)
        }
    }

    /// 세션을 시작하지 못했을 때: 정리하고, 원인에 따라 재시도를 미룬다.
    private func sessionFailed(_ error: Error, conn: MessageConnection) {
        log(tr("오류", "Error") + ": \(error)")
        stopSession()
        let nsError = error as NSError
        let permissionDenied = nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.userDeclined.rawValue
        if permissionDenied {
            status.needsScreenPermission = true
            status.phase = tr("화면 기록 권한이 필요합니다", "Screen Recording permission required")
        } else {
            status.phase = tr("오류", "Error") + ": \(error.localizedDescription) — " + tr("10초 후 재시도", "retrying in 10 s")
        }
        status.connected = false
        onUpdate?(status)
        queue.async {
            self.pausedUntil = permissionDenied ? .distantFuture : Date().addingTimeInterval(10)
            conn.cancel()
        }
    }

    private func didStartStreaming(_ session: StreamSession, bitrate: Int) {
        status.connected = true
        status.receiverName = session.hello.name
        status.resolution = "\(session.width)×\(session.height) \(session.codec == .hevc ? "HEVC" : "H.264")"
        status.bitrateMbps = bitrate
        status.phase = tr("전송 중", "Streaming") + " → \(session.hello.name)"
        log("\(status.phase) (\(status.kind?.description ?? "?"), " + tr("비트레이트", "bitrate") + " \(bitrate) Mbps)")
        onUpdate?(status)
    }

    private func stopSession() {
        session?.stop()
        session = nil
        sessionConn = nil
        lastSample = nil
    }

    /// 1초마다 실제 전송 속도와 fps를 계산한다.
    private func updateStats() {
        guard let session, let conn = sessionConn else { return }
        let now = Date()
        let stats = session.stats
        let id = ObjectIdentifier(conn)
        let bytes = conn.bytesSent
        if let last = lastSample, last.conn == id {
            let dt = now.timeIntervalSince(last.time)
            if dt > 0 {
                status.throughputBps = Double(bytes - last.bytes) * 8 / dt
                status.fps = Double(stats.framesSent - last.sent) / dt
                status.skippedPerSecond = Double(stats.framesSkipped - last.skipped) / dt
            }
        }
        lastSample = (now, id, bytes, stats.framesSent, stats.framesSkipped)
        if status.kind == .wifi {
            status.linkSpeedBps = linkSpeed(kind: .wifi, interfaceName: status.interfaceName)
        }
        onUpdate?(status)
    }

    // MARK: - 유틸

    private func linkSpeed(kind: LinkKind, interfaceName: String?) -> UInt64? {
        guard let interfaceName else { return nil }
        if kind == .wifi {
            // Wi-Fi는 현재 전송 속도(협상된 PHY 속도)를 CoreWLAN에서 읽는다.
            let rate = CWWiFiClient.shared().interface(withName: interfaceName)?.transmitRate() ?? 0
            return rate > 0 ? UInt64(rate * 1_000_000) : nil
        }
        return NetworkInterfaces.linkSpeed(of: interfaceName)
    }

    /// net 큐에서도 안전하게 메뉴 상태를 바꾼다.
    private func publish(_ change: @escaping (inout LinkStatus) -> Void) {
        DispatchQueue.main.async {
            change(&self.status)
            self.onUpdate?(self.status)
        }
    }
}
