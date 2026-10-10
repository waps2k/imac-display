// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iMacDisplay",
    platforms: [.macOS(.v13)],
    targets: [
        // 송신/수신이 공유하는 메시지 프레이밍
        .target(name: "Wire", path: "Sources/Wire"),
        // CoreGraphics 비공개 가상 디스플레이 API 선언
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // 맥북에서 실행: 가상 디스플레이 생성 → 캡처 → 인코딩 → 전송
        .executableTarget(
            name: "Sender",
            dependencies: ["Wire", "CGVirtualDisplayPrivate"],
            path: "Sources/Sender",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        // iMac에서 실행: 수신 → 디코딩 → 전체 화면 표시
        .executableTarget(
            name: "Receiver",
            dependencies: ["Wire"],
            path: "Sources/Receiver"
        ),
    ]
)
