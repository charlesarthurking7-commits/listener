import AppKit
import ListenerCore
import PDFKit
import UniformTypeIdentifiers

/// Plain text from the files people drop onto the window: PDF, Word, RTF, OpenDocument,
/// HTML and plain text. A scanned PDF has no text layer, so it comes back empty.
public enum DocumentText {
    public static let kinds = "PDF, Word, RTF, HTML and text files"

    public static func canRead(_ url: URL) -> Bool {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        return richTextExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .pdf) == true
            || type?.conforms(to: .text) == true
    }

    public static func read(_ url: URL) throws -> String {
        let fileExtension = url.pathExtension.lowercased()
        if UTType(filenameExtension: fileExtension)?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
            }
            return document.string ?? ""
        }
        if ["html", "htm"].contains(fileExtension) {
            return WebPageText(html: try CallTypeLibrary.readPlainText(url)).text
        }
        if richTextExtensions.contains(fileExtension) {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        guard canRead(url) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: url])
        }
        return try CallTypeLibrary.readPlainText(url)
    }

    /// Read through NSAttributedString, which handles them without WebKit or the main thread.
    private static let richTextExtensions: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt"]
}
