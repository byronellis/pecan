//
//  Instruction.swift
//  pecan
//
//  Created by Byron Ellis on 4/11/26.
//

public struct Instruction : PrimitivePrompt {
    package enum Storage {
        case verbatim(String)
    }
    
    package var storage : Storage
    
    public init(verbatim content: String) {
        storage = .verbatim(content)
    }
    
    public init<S>(_ content: S) where S: StringProtocol {
        storage = .verbatim(String(content))
    }
}

extension PromptBuilder {
    @_alwaysEmitIntoClient
    public static func buildExpression<Content>(_ content: Content) -> Instruction where Content : StringProtocol {
        Instruction(content)
    }
}
