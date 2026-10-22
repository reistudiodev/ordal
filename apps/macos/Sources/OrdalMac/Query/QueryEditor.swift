import AppKit
import OrdalKit
import SwiftUI

/// A plain-text code editor (NSTextView) with light syntax highlighting.
struct QueryEditor: NSViewRepresentable {
    enum Language { case sql, json, redis }

    @Binding var text: String
    @Binding var selection: NSRange
    let language: Language

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = Fonts.editor
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: Space.s, height: Space.s)
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.setAccessibilityLabel("Query editor")
        tv.string = text
        context.coordinator.highlight(tv)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            context.coordinator.highlight(tv)
        }
        if tv.selectedRange() != selection, NSMaxRange(selection) <= (tv.string as NSString).length {
            tv.setSelectedRange(selection)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QueryEditor

        init(_ parent: QueryEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            let range = tv.selectedRange()
            if parent.selection != range { parent.selection = range }
        }

        private static let keyword = NSColor.adaptive(light: 0xA626A4, dark: 0xC678DD)
        private static let string = NSColor.adaptive(light: 0x1E7A3A, dark: 0x98C379)
        private static let number = DataColors.number

        private static let sqlKeywords = try! NSRegularExpression(
            pattern: "\\b(select|from|where|and|or|not|in|is|null|as|on|join|left|right|inner|outer|full|cross|group|by|order|having|limit|offset|union|all|distinct|insert|into|values|update|set|delete|create|table|view|index|alter|drop|truncate|with|case|when|then|else|end|asc|desc|returning|like|ilike|between|exists|default|primary|key|references|explain|analyze|begin|commit|rollback|true|false)\\b",
            options: [.caseInsensitive])
        private static let strings = try! NSRegularExpression(pattern: "'(?:[^']|'')*'|\"(?:[^\"\\\\]|\\\\.)*\"")
        private static let numbers = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
        private static let comments = try! NSRegularExpression(pattern: "--[^\\n]*|/\\*[\\s\\S]*?\\*/")
        private static let firstWord = try! NSRegularExpression(pattern: "^\\s*\\S+", options: [.anchorsMatchLines])

        /// Recolours the whole text. Skipped for very large scripts to stay responsive.
        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            guard storage.length < 200_000 else { return }
            storage.beginEditing()
            storage.setAttributes([.font: Fonts.editor, .foregroundColor: NSColor.labelColor], range: full)
            let s = storage.string
            func paint(_ re: NSRegularExpression, _ color: NSColor) {
                re.enumerateMatches(in: s, range: full) { m, _, _ in
                    if let r = m?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
                }
            }
            switch parent.language {
            case .sql:
                paint(Self.sqlKeywords, Self.keyword)
                paint(Self.numbers, Self.number)
            case .json:
                paint(Self.numbers, Self.number)
            case .redis:
                paint(Self.firstWord, Self.keyword)
            }
            paint(Self.strings, Self.string)
            if parent.language == .sql { paint(Self.comments, .secondaryLabelColor) }
            storage.endEditing()
        }
    }
}
