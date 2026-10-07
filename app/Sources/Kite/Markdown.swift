import SwiftUI

// Just enough Markdown for agent results: headings, paragraphs, lists, tables, code blocks.
// Bold, italics, code and links inside a line come from AttributedString, and links open.
struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullets([String])
        case table([[String]])
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(block) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .paragraph(let s):
            inline(s)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(item) }
                }
            }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).fontWeight(i == 0 ? .semibold : .regular)
                        }
                    }
                    if i == 0 { Divider() }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .code(let s):
            Text(s).font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: options)) ?? AttributedString(s))
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = [], bullets: [String] = [], table: [[String]] = []
        var code: [String]? = nil
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("|") {
                if !para.isEmpty || !bullets.isEmpty { let t = table; table = []; flush(); table = t }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }  // the |---| row
                table.append(cells)
            } else if let item = Self.bullet(line) {
                if !para.isEmpty || !table.isEmpty { let b = bullets; bullets = []; flush(); bullets = b }
                bullets.append(item)
            } else {
                if !bullets.isEmpty || !table.isEmpty { flush() }
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    private static func bullet(_ line: String) -> String? {
        for mark in ["- ", "* ", "+ "] where line.hasPrefix(mark) { return String(line.dropFirst(2)) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return String(line[line.index(dot, offsetBy: 2)...])
        }
        return nil
    }
}
