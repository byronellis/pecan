//
//  Group.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//
public struct Group<Content> {
    let content: Content
    public init(@PromptBuilder content: () -> Content) {
        self.content = content()
    }
}

extension Group: PrimitivePrompt, Prompt where Content: Prompt {
    public func _visitChildren<V>(_ visitor: V) where V : PromptVisitor {
        visitor.visit(content)
    }
}

extension Group: ParentPrompt where Content: Prompt {
    public var children: [AnyPrompt] {
        (content as? ParentPrompt)?.children ?? [AnyPrompt(content)]
    }
}

extension Group: GroupPrompt where Content: Prompt {}
