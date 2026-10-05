import Foundation

/// UI string lookup. Keys are the English source text, so a missing
/// translation (or a `swift run` outside the .app bundle) shows readable
/// English instead of an identifier. Translations live in
/// `Resources/<lang>.lproj/Localizable.strings`; `tools/check_localizations.py`
/// keeps every language in step with the keys used in source.
func L(_ key: String) -> String {
    UILanguage.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// The language picked in Settings, overriding the system's (empty = follow
/// the system). Strings are looked up in that language's `.lproj` directly.
enum UILanguage {
    static let userDefaultsKey = "MisstypeUILanguage"
    /// Folder names under `Resources/`; each is shown in its own language.
    static let choices: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hant", "繁體中文"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
    ]

    private static var cache: (code: String, bundle: Bundle)?

    static var bundle: Bundle {
        let code = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        if code.isEmpty { return .main }
        if let cache, cache.code == code { return cache.bundle }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        cache = (code, bundle)
        return bundle
    }
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
