import Foundation
import Wire

/// 설정은 UserDefaults로 읽는다. 따라서 두 가지 방법 모두 가능하다.
///   명령줄:   Sender -host 10.0.0.1 -bitrate 80
///   영구 설정: defaults write com.waps2k.imacdisplay.sender host 10.0.0.1
struct SenderOptions {
    /// 수신기 주소. 비우면 Bonjour로 자동 검색한다.
    var host: String?
    var port: UInt16
    /// true면 Wi-Fi를 쓰지 않는다 (썬더볼트/이더넷만).
    var wiredOnly: Bool
    var codec: Codec
    /// nil이면 연결 종류에 맞춰 자동 (썬더볼트 120 / 유선 60 / Wi-Fi 25 Mbps)
    var bitrateMbps: Int?
    var fps: Int
    /// 전송 해상도의 가로 픽셀 상한 (예: 3840). 0이면 iMac 원래 해상도.
    var maxWidth: Int
    var hiDPI: Bool

    static func load() -> SenderOptions {
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
        }
        let host = d.string(forKey: "host").flatMap { $0.isEmpty ? nil : $0 }
        return SenderOptions(
            host: host,
            port: UInt16(int("port", Int(defaultPort))),
            wiredOnly: bool("wiredOnly", false),
            codec: d.string(forKey: "codec")?.lowercased() == "h264" ? .h264 : .hevc,
            bitrateMbps: d.object(forKey: "bitrate") == nil ? nil : d.integer(forKey: "bitrate"),
            fps: int("fps", 60),
            maxWidth: int("maxWidth", 0),
            hiDPI: bool("hiDPI", true)
        )
    }
}
