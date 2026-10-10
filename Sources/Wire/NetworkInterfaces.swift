import Foundation
import Network
import SystemConfiguration

/// 연결 종류. 값이 작을수록 우선순위가 높다.
public enum LinkKind: Int, Comparable, CustomStringConvertible {
    case thunderbolt = 0
    case ethernet = 1
    case wifi = 2
    case other = 3

    public static func < (a: LinkKind, b: LinkKind) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .thunderbolt: return tr("썬더볼트", "Thunderbolt")
        case .ethernet: return tr("유선 랜", "Ethernet")
        case .wifi: return "Wi-Fi"
        case .other: return tr("기타 네트워크", "Other network")
        }
    }

    /// 메뉴 막대 아이콘 (SF Symbols)
    public var symbolName: String {
        switch self {
        case .thunderbolt: return "bolt.horizontal.circle.fill"
        case .ethernet: return "cable.connector"
        case .wifi: return "wifi"
        case .other: return "network"
        }
    }

    /// 종류별 기본 비트레이트 (Mbps). 사용자가 bitrate를 지정하면 그 값을 쓴다.
    public var defaultBitrateMbps: Int {
        switch self {
        case .thunderbolt: return 120
        case .ethernet: return 60
        case .wifi, .other: return 25
        }
    }
}

public enum NetworkInterfaces {
    /// BSD 이름(en0, bridge0 …) → 시스템 표시 이름("Wi-Fi", "Thunderbolt Bridge" …)
    public static func displayNames() -> [String: String] {
        var map: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
                map[bsd] = name
            }
        }
        return map
    }

    public static func kind(of interface: NWInterface, displayNames: [String: String]? = nil) -> LinkKind {
        kind(name: interface.name, type: interface.type, displayNames: displayNames ?? self.displayNames())
    }

    public static func kind(name: String, type: NWInterface.InterfaceType?, displayNames: [String: String]) -> LinkKind {
        let display = displayNames[name] ?? ""
        // 썬더볼트 브리지는 보통 bridge0, 멤버는 "Thunderbolt 1/2" (en1, en2 …)
        if name == "bridge0" || display.localizedCaseInsensitiveContains("thunderbolt") { return .thunderbolt }
        if type == .wifi || display.localizedCaseInsensitiveContains("wi-fi") { return .wifi }
        if type == .wiredEthernet || display.localizedCaseInsensitiveContains("ethernet")
            || display.localizedCaseInsensitiveContains("lan") { return .ethernet }
        return .other
    }

    /// 인터페이스의 링크 속도(bps). 모르면 nil.
    /// 브리지처럼 자체 속도가 없으면 멤버 인터페이스 중 가장 빠른 값을 쓴다.
    public static func linkSpeed(of name: String) -> UInt64? {
        let speeds = allBaudRates()
        if let speed = speeds[name], speed > 0 { return speed }
        if name.hasPrefix("bridge") {
            let names = displayNames()
            let members = speeds.filter { names[$0.key]?.localizedCaseInsensitiveContains("thunderbolt") == true }
            return members.values.max().flatMap { $0 > 0 ? $0 : nil }
        }
        return nil
    }

    /// sysctl(NET_RT_IFLIST2)로 64비트 링크 속도를 읽는다. (getifaddrs의 값은 32비트라 10Gbps를 표현하지 못한다)
    private static func allBaudRates() -> [String: UInt64] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: UInt64] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        result[String(cString: nameBuffer)] = info.ifm_data.ifi_baudrate
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    /// 대기 화면 안내용: IPv4 주소가 있는 인터페이스 목록 (우선순위 순).
    public static func ipv4Addresses() -> [(name: String, kind: LinkKind, address: String)] {
        let names = displayNames()
        var result: [(String, LinkKind, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            result.append((name, kind(name: name, type: nil, displayNames: names), String(cString: host)))
        }
        return result.sorted { $0.1 < $1.1 }
    }
}

/// 1_000_000_000 → "1 Gbps", 866_000_000 → "866 Mbps"
public func formatBitRate(_ bitsPerSecond: Double) -> String {
    if bitsPerSecond >= 1e9 {
        let g = bitsPerSecond / 1e9
        return g >= 10 || g == g.rounded() ? "\(Int(g.rounded())) Gbps" : String(format: "%.1f Gbps", g)
    }
    if bitsPerSecond >= 1e6 {
        let m = bitsPerSecond / 1e6
        return m >= 100 ? "\(Int(m.rounded())) Mbps" : String(format: "%.1f Mbps", m)
    }
    return String(format: "%.0f kbps", bitsPerSecond / 1e3)
}
