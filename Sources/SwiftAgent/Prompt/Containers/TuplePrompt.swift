//
//  TuplePrompt.swift
//  pecan
//
//  Created by Byron Ellis on 4/11/26.
//

public struct TuplePrompt<each P: Prompt> : PrimitivePrompt {
    let value: (repeat each P)
    let _children: [AnyPrompt]

    public init(_ value: (repeat each P)) {
        self.value = value
        var children: [AnyPrompt] = []
        for child in repeat each value {
            children.append(AnyPrompt(child))
        }
        self._children = children
        
    }

    public func _visitChildren<V>(_ visitor: V) where V : PromptVisitor {
        for child in children {
            visitor.visit(child)
        }
    }
    
}

extension TuplePrompt : GroupPrompt {
    public var children : [AnyPrompt] {
        _children
    }
}
