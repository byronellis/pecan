import Foundation


@resultBuilder
public struct PromptBuilder {
    
    @_alwaysEmitIntoClient
    public static func buildExpression<Content>(_ content: Content) -> Content where Content : Prompt {
        content
    }
    
    @_alwaysEmitIntoClient
    public static func buildExpression(_ invalid: Any) -> some Prompt {
        fatalError()
    }
    
    @_alwaysEmitIntoClient
    public static func buildBlock() -> EmptyPrompt {
        EmptyPrompt()
    }
    
    public static func buildBlock<Content>(_ content: Content) -> Content where Content : Prompt {
        content
    }
    
    public static func buildBlock<each Content>(_ content: repeat each Content) -> TuplePrompt<repeat each Content> where repeat each Content : Prompt {
        TuplePrompt((repeat each content))
    }

    public static func buildIf<Content>(_ content: Content?) -> Content? where Content : Prompt {
        content
    }
    
    public static func buildEither<TrueContent, FalseContent>(first: TrueContent) -> _ConditionalPrompt<TrueContent,FalseContent> where TrueContent : Prompt, FalseContent : Prompt {
        .init(storage: .trueContent(first))
    }
    
    public static func buildEither<TrueContent, FalseContent>(second: FalseContent) -> _ConditionalPrompt<TrueContent,FalseContent> where TrueContent : Prompt, FalseContent : Prompt {
        .init(storage: .falseContent(second))
    }
}


