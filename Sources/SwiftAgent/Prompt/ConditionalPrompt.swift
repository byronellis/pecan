//
//  ConditionalPrompt.swift
//  pecan
//
//  Created by Byron Ellis on 4/11/26.
//

public struct _ConditionalPrompt<TrueContent,FalseContent> {
    public enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }
    public let storage: Storage
}


extension _ConditionalPrompt : Prompt, PrimitivePrompt where TrueContent:Prompt, FalseContent:Prompt {
    init(storage:Storage) {
        self.storage = storage
    }
}
