//
//  SoulBuilder.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

@resultBuilder
public enum SoulBuilder {
    
    @available(*, unavailable, message: "Provide at least one soul")
    public static func buildBlock() -> some Soul {
        fatalError("Unavailable")
    }
    
    public static func buildBlock<Content>(_ content: Content) -> Content where Content: Soul {
        content
    }
    
    public static func buildBlock<each Content>(_ content: repeat each Content) -> some Soul where repeat each Content: Soul {
        _TupleSoul((repeat each content))
    }
}
