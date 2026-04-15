//
//  Instruction.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//
extension Instruction : AnyMarkdown {
    public func innerMarkdown() -> String? {
        let markdown:String
        switch storage {
        case .verbatim(let value):
            markdown = value
        }
        return markdown
    }
    
}
