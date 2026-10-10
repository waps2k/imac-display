import Foundation

/// Bonjour 서비스 타입. 썬더볼트 브릿지(링크 로컬)에서도 동작한다.
public let serviceType = "_imacdisplay._tcp"
public let defaultPort: UInt16 = 52_020
/// 2: ping/pong 추가 (0.2.0)
public let protocolVersion = 2

/// 프레임: [type: UInt8][length: UInt32 BE][payload]
public enum MessageType: UInt8 {
    /// 수신 → 송신: 수신 측 화면 정보 (JSON `Hello`)
    case hello = 1
    /// 송신 → 수신: 코덱과 파라미터 세트 (`VideoFormat`)
    case format = 2
    /// 송신 → 수신: 인코딩된 프레임 (`VideoFrame`)
    case frame = 3
    /// 수신 → 송신: 디코딩 실패 등으로 키프레임이 필요함
    case requestKeyframe = 4
    /// 송신 → 수신: 왕복 지연 측정 (payload 그대로 pong으로 돌려준다)
    case ping = 5
    /// 수신 → 송신
    case pong = 6
}

public struct Hello: Codable, Equatable {
    /// 0.1 수신기는 이 값을 보내지 않는다 (nil).
    public var protocolVersion: Int?
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var widthMillimeters: Double
    public var heightMillimeters: Double

    public init(name: String, pixelWidth: Int, pixelHeight: Int, scale: Double,
                widthMillimeters: Double, heightMillimeters: Double) {
        self.protocolVersion = Wire.protocolVersion
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.widthMillimeters = widthMillimeters
        self.heightMillimeters = heightMillimeters
    }
}

public enum Codec: UInt8 {
    case h264 = 0
    case hevc = 1
}

public struct VideoFormat {
    public var codec: Codec
    public var parameterSets: [Data]

    public init(codec: Codec, parameterSets: [Data]) {
        self.codec = codec
        self.parameterSets = parameterSets
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u8(codec.rawValue)
        w.u8(UInt8(parameterSets.count))
        for set in parameterSets {
            w.u32(UInt32(set.count))
            w.bytes(set)
        }
        return w.data
    }

    public init?(_ data: Data) {
        var r = ByteReader(data)
        guard let c = r.u8(), let codec = Codec(rawValue: c), let count = r.u8() else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let len = r.u32(), let set = r.bytes(Int(len)) else { return nil }
            sets.append(set)
        }
        self.init(codec: codec, parameterSets: sets)
    }
}

/// 프레임 데이터는 AVCC/HVCC 형식(4바이트 길이 + NAL 유닛)이다.
public struct VideoFrame {
    public var isKeyframe: Bool
    public var data: Data

    public init(isKeyframe: Bool, data: Data) {
        self.isKeyframe = isKeyframe
        self.data = data
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u8(isKeyframe ? 1 : 0)
        w.bytes(data)
        return w.data
    }

    public init?(_ data: Data) {
        guard let flags = data.first else { return nil }
        self.init(isKeyframe: flags & 1 != 0, data: data.dropFirst())
    }
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func u8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u32() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        return b.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, offset + n <= data.endIndex else { return nil }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }
}
