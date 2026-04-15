//
//  PromptTests.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//
import Testing
@testable import SwiftAgent

@Suite("Prompt Tests")
struct PromptTests {
    
    private struct BasicPrompt : Prompt {
        var body: some Prompt {
            "This is an instruction."
            "So is this."
        }
    }
    
    @Test("Basic Prompt Test")
    func testBasicPrompt() {
        print(MarkdownRenderer(BasicPrompt()).render())
    }
    
}
