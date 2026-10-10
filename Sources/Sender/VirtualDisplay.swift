import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation
import Wire

/// macOS에 "모니터가 하나 더 연결됐다"고 알리는 가상 디스플레이.
/// 객체가 해제되면 디스플레이도 사라진다.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int

    init(name: String, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool,
         sizeInMillimeters: CGSize, refreshRate: Double) throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.vendorID = 0x1D1D
        descriptor.productID = 0x5E01
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in log(tr("가상 디스플레이가 시스템에 의해 종료됨", "Virtual display was terminated by the system")) }

        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else { throw SenderError.virtualDisplayFailed }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // HiDPI 모드는 포인트 크기(픽셀/2)로, 일반 모드는 픽셀 크기로 등록한다.
        var modes = [CGVirtualDisplayMode(width: UInt(pixelWidth), height: UInt(pixelHeight), refreshRate: refreshRate)]
        if hiDPI {
            modes.insert(CGVirtualDisplayMode(width: UInt(pixelWidth / 2), height: UInt(pixelHeight / 2), refreshRate: refreshRate), at: 0)
        }
        settings.modes = modes
        guard display.apply(settings) else { throw SenderError.virtualDisplayFailed }

        self.display = display
        self.displayID = display.displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight

        selectBestMode(hiDPI: hiDPI)
    }

    /// 목표 픽셀 크기와 일치하는 모드(가능하면 HiDPI)를 선택한다.
    private func selectBestMode(hiDPI: Bool) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        for mode in modes {
            log("  " + tr("모드", "Mode") + ": \(mode.width)x\(mode.height)pt, \(mode.pixelWidth)x\(mode.pixelHeight)px @\(mode.refreshRate)Hz")
        }
        let matching = modes.filter { $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight }
        let preferred = matching.first { hiDPI ? $0.width * 2 == $0.pixelWidth : $0.width == $0.pixelWidth }
        guard let mode = preferred ?? matching.first else {
            log(tr("일치하는 디스플레이 모드가 없어 기본 모드를 사용합니다", "No matching display mode; using the default mode"))
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        if CGCompleteDisplayConfiguration(config, .forSession) == .success {
            log(tr("디스플레이 모드 선택", "Display mode selected") + ": \(mode.width)x\(mode.height)pt (\(mode.pixelWidth)x\(mode.pixelHeight)px)")
        }
    }

    /// 현재 모드의 실제 픽셀 크기 (사용자가 시스템 설정에서 바꿀 수 있다).
    var currentPixelSize: (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return (pixelWidth, pixelHeight) }
        return (mode.pixelWidth, mode.pixelHeight)
    }
}

enum SenderError: Error, CustomStringConvertible {
    case virtualDisplayFailed
    case displayNotFound
    case encoderFailed(OSStatus)

    var description: String {
        switch self {
        case .virtualDisplayFailed: return tr("가상 디스플레이를 만들 수 없습니다", "Couldn't create the virtual display")
        case .displayNotFound: return tr("ScreenCaptureKit에서 가상 디스플레이를 찾을 수 없습니다 (화면 기록 권한을 확인하세요)", "ScreenCaptureKit can't find the virtual display (check the Screen Recording permission)")
        case .encoderFailed(let s): return tr("비디오 인코더 생성 실패", "Couldn't create the video encoder") + " (OSStatus \(s))"
        }
    }
}
