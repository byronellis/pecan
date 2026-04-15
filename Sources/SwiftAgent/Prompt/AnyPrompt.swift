//
//  AnyPrompt.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

public struct AnyPrompt : PrimitivePrompt, Prompt {
    let type: Any.Type
    var prompt: Any
    let bodyClosure: (Any) -> AnyPrompt
    let bodyType: Any.Type
    
    let visitChildren: (PromptVisitor, Any) -> ()
    
    public init<P>(_ prompt: P) where P: Prompt {
        if let anyPrompt = prompt as? AnyPrompt {
           self = anyPrompt
        } else {
            self.prompt = prompt
            type = P.self
            bodyType = P.Body.self
            bodyClosure = { AnyPrompt(($0 as! P).body) }
            visitChildren = { $0.visit($1 as! P) }
        }
    }
    
    public func _visitChildren<V:PromptVisitor>(_ visitor: V) {
        visitChildren(visitor,prompt)
    }
}

extension AnyPrompt : ParentPrompt {
    public var children : [AnyPrompt] {
        (prompt as? ParentPrompt)?.children ?? []
    }
}

public func mapAnyPrompt<T,P>(_ anyPrompt: AnyPrompt,transform: (P) -> T) -> T? {
    guard let prompt = anyPrompt.prompt as? P else { return nil }
    return transform(prompt)
}
