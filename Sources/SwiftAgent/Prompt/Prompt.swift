//
//  Prompt.swift
//  pecan
//
//  Created by Byron Ellis on 4/11/26.
//


public protocol Prompt {
    associatedtype Body:Prompt
    
    @PromptBuilder
    var body: Body { get }
    func _visitChildren<V>(_ visitor: V) where V : PromptVisitor
}



// MARK: - PrimitivePrompt

public protocol PrimitivePrompt : Prompt {}

public extension PrimitivePrompt {
    var body: Never {
        promptError()
    }

    func _visitChildren<V>(_ visitor: V) where V : PromptVisitor { }
    
}

extension Prompt {
    package func promptError() -> Never {
        preconditionFailure("body() should not be called on \(Self.self).")
    }
}

// MARK: - ParentPrompt
public protocol ParentPrompt {
    var children: [AnyPrompt] { get }
}

protocol GroupPrompt : ParentPrompt { }

// MARK: - PromptVisitor
public protocol PromptVisitor {
    func visit<P:Prompt>(_ prompt: P)
}

public extension Prompt {
    func _visitChildren<V:PromptVisitor>(_ visitor: V) {
        visitor.visit(body)
    }
}

