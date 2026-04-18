import Foundation

// MARK: - Core Protocol

/// A node in the prompt DSL tree. Renders itself to a Markdown string synchronously.
/// All async data (skills catalog, etc.) is pre-fetched into PromptContext before rendering.
public protocol PromptNode: Sendable {
    func render() -> String
}

// MARK: - Result Builder

@resultBuilder
public struct PromptBuilder {
    /// Combines multiple nodes into a group separated by blank lines.
    public static func buildBlock(_ components: any PromptNode...) -> any PromptNode {
        PromptGroup(children: Array(components))
    }

    /// Handles `if` without `else`.
    public static func buildOptional(_ component: (any PromptNode)?) -> any PromptNode {
        component ?? EmptyPrompt()
    }

    /// Handles the `true` branch of `if/else`.
    public static func buildEither(first component: any PromptNode) -> any PromptNode {
        component
    }

    /// Handles the `false` branch of `if/else`.
    public static func buildEither(second component: any PromptNode) -> any PromptNode {
        component
    }

    /// Handles `for` loops and `ForEach`.
    public static func buildArray(_ components: [any PromptNode]) -> any PromptNode {
        PromptGroup(children: components)
    }

    /// Pass-through for explicit `PromptNode` expressions.
    public static func buildExpression(_ node: any PromptNode) -> any PromptNode {
        node
    }
}

// MARK: - Structural nodes (internal)

/// Combines multiple nodes, separated by a blank line when rendered.
struct PromptGroup: PromptNode, Sendable {
    let children: [any PromptNode]

    func render() -> String {
        children
            .map { $0.render().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// Renders nothing. Used when a conditional produces no output.
public struct EmptyPrompt: PromptNode, Sendable {
    public init() {}
    public func render() -> String { "" }
}
