import CoreText
import Foundation
import SwiftUI

/// Geist and Geist Mono, which ship with the app under the SIL Open Font Licence (see
/// App/Fonts/OFL.txt).
enum Fonts {
    /// Makes the bundled fonts available to this process. The app has them in
    /// Contents/Resources/Fonts; a binary run straight from the build folder reads them
    /// from the source tree. Without them every view falls back to the system font.
    static func register() {
        guard let folder else {
            Log.ui.notice("The Geist fonts were not found, so the system font is used")
            return
        }
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "ttf" } ?? []
        CTFontManagerRegisterFontURLs(files as CFArray, .process, true, nil)
    }

    private static var folder: URL? {
        [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), sourceTreeFolder].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// App/Fonts, four folders up from this file.
    private static let sourceTreeFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("App/Fonts", isDirectory: true)

    fileprivate static func sans(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "Geist-Bold"
        case .semibold: "Geist-SemiBold"
        case .medium: "Geist-Medium"
        default: "Geist-Regular"
        }
    }

    fileprivate static func mono(_ weight: Font.Weight) -> String {
        weight == .regular || weight == .light || weight == .thin || weight == .ultraLight
            ? "GeistMono-Regular" : "GeistMono-Medium"
    }
}

extension Font {
    /// Geist at a fixed size: every word in the window but figures.
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.sans(weight), fixedSize: size)
    }

    static func geistItalic(_ size: CGFloat) -> Font {
        .custom("Geist-Italic", fixedSize: size)
    }

    /// Geist Mono, for figures that change or line up: times, costs, counts and keys.
    static func geistMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.mono(weight), fixedSize: size)
    }
}
