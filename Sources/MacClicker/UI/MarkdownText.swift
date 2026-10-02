import SwiftUI

/// Renders the light markdown the skills emit — paragraphs, bullets, inline
/// emphasis, fenced code — without pulling in a markdown dependency.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Block.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    Text(Block.inline(line))
                        .fixedSize(horizontal: false, vertical: true)

                case .bullet(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Block.inline(line))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2)

                case .code(let source):
                    Text(source)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    enum Block {
        case paragraph(String)
        case bullet(String)
        case code(String)

        static func parse(_ text: String) -> [Block] {
            var blocks: [Block] = []
            var paragraph: [String] = []
            var code: [String] = []
            var inCode = false

            func flushParagraph() {
                guard !paragraph.isEmpty else { return }
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }

            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)

                if line.hasPrefix("```") {
                    if inCode {
                        blocks.append(.code(code.joined(separator: "\n")))
                        code = []
                        inCode = false
                    } else {
                        flushParagraph()
                        inCode = true
                    }
                    continue
                }
                if inCode { code.append(rawLine); continue }

                if line.isEmpty { flushParagraph(); continue }

                if let bullet = bulletBody(of: line) {
                    flushParagraph()
                    blocks.append(.bullet(bullet))
                    continue
                }

                // Headings get folded into bold paragraphs — the panel is too
                // narrow for a real heading hierarchy to read well.
                if line.hasPrefix("#") {
                    flushParagraph()
                    let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    blocks.append(.paragraph("**\(title)**"))
                    continue
                }

                paragraph.append(line)
            }

            flushParagraph()
            if !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
            return blocks
        }

        private static func bulletBody(of line: String) -> String? {
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
            // "1. " / "12) " style lists
            let digits = line.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 2 {
                let rest = line.dropFirst(digits.count)
                if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                    return "\(digits). " + rest.dropFirst(2)
                }
            }
            return nil
        }

        /// Inline emphasis only — the block structure is already handled above.
        static func inline(_ line: String) -> AttributedString {
            (try? AttributedString(
                markdown: line,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(line)
        }
    }
}
