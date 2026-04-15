//
//  Markdown.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//

public protocol AnyMarkdown {
    func innerMarkdown() -> String?
}

public extension AnyMarkdown {
    func outerMarkdown(children: [MarkdownTarget]) -> String {
        return """
            \(innerMarkdown() ?? "")
            \(children.map { $0.outerMarkdown()}.joined(separator: "\n"))
            """
    }
}

public struct Markdown<Content> : Prompt, AnyMarkdown {
    let content: Content
    let visitContent: (PromptVisitor) -> ()
    fileprivate let cachedInnerMarkdown : String?
    
    public func innerMarkdown() -> String? {
        cachedInnerMarkdown
    }
    
    public var body: Never {
        fatalError("Markdown<\(Content.self)>")
    }
    
    public func _visitChildren<V>(_ visitor: V) where V : PromptVisitor {
        visitContent(visitor)
    }
}

public extension Markdown where Content: StringProtocol {
    init(content: Content) {
        self.content = content
        cachedInnerMarkdown = String(content)
        visitContent = { _ in }
    }
}

extension Markdown : ParentPrompt where Content: Prompt {
    public init(@PromptBuilder content: @escaping () -> Content) {
        self.content = content()
        cachedInnerMarkdown = nil
        visitContent = { $0.visit(content()) }
    }
    
    public var children: [AnyPrompt] {
        [AnyPrompt(content)]
    }
}

public extension Markdown where Content == EmptyPrompt {
    init() {
        self = Markdown() {
            EmptyPrompt()
        }
    }
}
