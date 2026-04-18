import Foundation
import Markdown

// MARK: - Raw

/// Pre-formatted Markdown content inserted verbatim.
/// Useful for multi-line content or text that already contains Markdown syntax.
public struct Raw: PromptNode, Sendable {
    public let markdown: String

    public init(_ markdown: String) { self.markdown = markdown }

    public func render() -> String { markdown }
}

// MARK: - Paragraph

/// A plain text paragraph. For rich inline content (bold, code, links), use `Raw` instead.
public struct Paragraph: PromptNode, Sendable {
    public let text: String

    public init(_ text: String) { self.text = text }

    public func render() -> String {
        Markdown.Paragraph(Markdown.Text(text))
            .format()
            .trimmingCharacters(in: .newlines)
    }
}

// MARK: - BulletList

/// An unordered bullet list. Each item is treated as plain text.
/// For items with rich inline markup, use `Raw` with a manually formatted list.
public struct BulletList: PromptNode, Sendable {
    public let items: [String]

    public init(_ items: [String]) { self.items = items }
    public init(_ items: String...) { self.items = items }

    public func render() -> String {
        let listItems = items.map { item in
            Markdown.ListItem(Markdown.Paragraph(Markdown.Text(item)))
        }
        return Markdown.UnorderedList(listItems)
            .format()
            .trimmingCharacters(in: .newlines)
    }
}

// MARK: - Section

/// A headed section: a `Markdown.Heading` followed by body content built with `@PromptBuilder`.
/// The body is separated from the heading by a blank line.
public struct Section: PromptNode, Sendable {
    let heading: String
    let level: Int
    let body: any PromptNode

    public init(_ heading: String, level: Int = 2, @PromptBuilder body: () -> any PromptNode) {
        self.heading = heading
        self.level = max(1, min(6, level))
        self.body = body()
    }

    public func render() -> String {
        // Use swift-markdown's Heading type for canonical heading formatting.
        let headingStr = Heading(level: level, Text(heading))
            .format()
            .trimmingCharacters(in: .newlines)
        let bodyStr = body.render()
        guard !bodyStr.isEmpty else { return headingStr }
        return headingStr + "\n\n" + bodyStr
    }
}

// MARK: - ForEach

/// Iterates over a collection and renders each element using a builder closure.
/// Elements are separated by blank lines, consistent with `PromptGroup`.
public struct ForEach<C: Collection & Sendable>: PromptNode, Sendable where C.Element: Sendable {
    let data: C
    let content: @Sendable (C.Element) -> any PromptNode

    public init(_ data: C, @PromptBuilder content: @escaping @Sendable (C.Element) -> any PromptNode) {
        self.data = data
        self.content = content
    }

    public func render() -> String {
        data
            .map { content($0).render().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
