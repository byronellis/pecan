//
//  SubAgent.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

public struct SubAgent<Content> : Soul where Content: Soul {
    public let id: String
    public let content: Content
    public init(id: String, @SoulBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }
    
    public var body: Never {
        soulBodyError()
    }
}
