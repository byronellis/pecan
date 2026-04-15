//
//  ForEach.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//
public struct ForEach<Data,ID,Content> : PrimitivePrompt
where Data: RandomAccessCollection,ID:Hashable,Content:Prompt {
    let data: Data
    let id: KeyPath<Data.Element,ID>
    public let content: (Data.Element) -> Content
    
    public init(_ data: Data,id:KeyPath<Data.Element,ID>,@PromptBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.content = content
    }
    
}

public extension ForEach where Data.Element : Identifiable, ID == Data.Element.ID {
    init(_ data: Data,@PromptBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: \.id, content: content)
    }
}
