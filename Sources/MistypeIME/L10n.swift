import Foundation

/// UI string lookup. Keys are the English source text, so a missing
/// translation (or a `swift run` outside the .app bundle) shows readable
/// English instead of an identifier. Translations live in
/// `Resources/<lang>.lproj/Localizable.strings`; `tools/check_localizations.py`
/// keeps every language in step with the keys used in source.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
