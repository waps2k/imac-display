import Foundation

/// 앱 화면 언어. 한국어 환경이면 한국어, 그 외에는 영어로 표시한다.
///
/// 우선순위:
/// 1. `language` 설정 (`-language en` 인자 또는 `defaults write <bundle id> language ko`)
/// 2. 앱 번들의 지역화 선택 (시스템 설정 → 일반 → 언어 및 지역 → 앱별 언어 설정 포함)
/// 3. 시스템 선호 언어 (번들 없이 실행 파일만 돌릴 때)
public enum AppLanguage {
    public static let isKorean: Bool = {
        if let forced = UserDefaults.standard.string(forKey: "language")?.lowercased() {
            return forced.hasPrefix("ko")
        }
        let bundle = Bundle.main
        if bundle.localizations.contains("ko") {
            return bundle.preferredLocalizations.first?.hasPrefix("ko") ?? false
        }
        return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
    }()
}

/// 한국어/영어 문자열 쌍에서 현재 언어에 맞는 쪽을 고른다.
public func tr(_ korean: String, _ english: String) -> String {
    AppLanguage.isKorean ? korean : english
}
