//
//  MarkdownTarget.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//

public final class MarkdownTarget : Target {
    var markdown: AnyMarkdown
    var children: [MarkdownTarget] = []
    
    public var prompt : AnyPrompt
    
    init<P:Prompt>(_ prompt: P, _ markdown: AnyMarkdown) {
        self.prompt = AnyPrompt(prompt)
        self.markdown = markdown
    }
    
    init(_ markdown: AnyMarkdown) {
        self.prompt = AnyPrompt(EmptyPrompt())
        self.markdown = markdown
    }
}

extension MarkdownTarget {
    func outerMarkdown() -> String {
        markdown.outerMarkdown(children: children)
    }
}

struct MarkdownBody : AnyMarkdown {
    func innerMarkdown() -> String? {
        nil
    }
}

public final class MarkdownRenderer : Renderer {
    private var reconciler: Reconciler<MarkdownRenderer>?
    
    var rootTarget: MarkdownTarget
    
    public func render() -> String {
        """
        \(rootTarget.outerMarkdown())
        """
    }
    
    public func mountTarget(before _: MarkdownTarget?, to parent: MarkdownTarget, with host: MountedHost) -> MarkdownTarget? {
        
        guard let markdown = mapAnyPrompt(host.prompt,transform: { (markdown:AnyMarkdown) in markdown }) else {
            if mapAnyPrompt(host.prompt, transform: { (prompt:ParentPrompt) in prompt }) != nil {
                return parent
            }
            return nil
        }
        
        let node = MarkdownTarget(host.prompt, markdown)
        parent.children.append(node)
        return node
    }
    
    public func primitiveBody(for prompt: Any) -> AnyPrompt? {
        (prompt as? _MarkdownPrimitive)?.renderedBody
    }
    
    public func isPrimitivePrompt(_ type: any Any.Type) -> Bool {
        type is _MarkdownPrimitive.Type
    }

    
    public init<P:Prompt>(_ prompt: P) {
        rootTarget = MarkdownTarget(prompt,MarkdownBody())
        reconciler = Reconciler(prompt: prompt, target: rootTarget, renderer: self)
    }
}

public protocol _MarkdownPrimitive {
    var renderedBody: AnyPrompt { get }
}
