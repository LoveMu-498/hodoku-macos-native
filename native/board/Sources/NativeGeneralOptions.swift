// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// General settings owned by the workbench. Pointer and filter behaviour lives in NativeMouseOptions.
struct NativeGeneralOptions: Codable, Equatable {
    var useDefaultFontSize = true
    var customFontSize = 12
    var showWrongValues = true
    var showColorKu = false
    var saveWindowLayout = true
    var drawMode = 1
    var onlySmallCursors = true
    var colorValues = true
    var showSudokuSolved = false
    var deleteCursorDisplay = false
    var deleteCursorDisplayLength = 1000
    var language = ""
    var laf = ""

    init() {}

    private static let switches: [(String, WritableKeyPath<Self, Bool>)] = [
        ("useDefaultFontSize", \.useDefaultFontSize), ("showWrongValues", \.showWrongValues),
        ("showColorKu", \.showColorKu), ("saveWindowLayout", \.saveWindowLayout),
        ("onlySmallCursors", \.onlySmallCursors), ("colorValues", \.colorValues),
        ("showSudokuSolved", \.showSudokuSolved), ("deleteCursorDisplay", \.deleteCursorDisplay)
    ]
    private static let numbers: [(String, WritableKeyPath<Self, Int>)] = [
        ("customFontSize", \.customFontSize), ("drawMode", \.drawMode),
        ("deleteCursorDisplayLength", \.deleteCursorDisplayLength)
    ]
    private static let strings: [(String, WritableKeyPath<Self, String>)] = [("language", \.language), ("laf", \.laf)]

    init(_ bean: LegacyBean) throws {
        self.init()
        for (key, path) in Self.switches { self[keyPath: path] = try bean.flag(key, self[keyPath: path]) }
        for (key, path) in Self.numbers {
            if let value = try bean[key]?.int() { self[keyPath: path] = value }
        }
        for (key, path) in Self.strings {
            if let value = bean[key]?.scalar { self[keyPath: path] = value }
        }
        try validate()
    }

    func validate() throws {
        guard (0...1).contains(drawMode), (1...Int(Int32.max)).contains(customFontSize),
              (0...Int(Int32.max)).contains(deleteCursorDisplayLength) else {
            throw WorkspaceProblem("界面字号须大于零，光标停留时间须为非负数。")
        }
    }

    func changedProperties(comparedWith old: Self, append: (String, String) -> Void) throws {
        for (key, path) in Self.switches where self[keyPath: path] != old[keyPath: path] {
            append(key, "<boolean>\(self[keyPath: path])</boolean>")
        }
        for (key, path) in Self.numbers where self[keyPath: path] != old[keyPath: path] {
            append(key, "<int>\(self[keyPath: path])</int>")
        }
        for (key, path) in Self.strings where self[keyPath: path] != old[keyPath: path] {
            append(key, try NativePuzzleBeanWriter().value(LegacyBean("string", self[keyPath: path])))
        }
    }

    var locale: Locale { language.isEmpty ? .autoupdatingCurrent : Locale(identifier: language) }

    private static let languageBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]
        for language in ["zh-Hans", "en", "de"] {
            if let url = Bundle.main.url(forResource: language, withExtension: "lproj") { bundles[language] = Bundle(url: url) }
        }
        return bundles
    }()

    /// AppKit menu and toolbar labels do not inherit SwiftUI's locale environment.
    func localized(_ key: String) -> String {
        let code = language.isEmpty ? Locale.preferredLanguages.first ?? "zh" : language
        let directory = code.hasPrefix("zh") ? "zh-Hans" : code.hasPrefix("de") ? "de" : "en"
        return Self.languageBundles[directory]?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}
