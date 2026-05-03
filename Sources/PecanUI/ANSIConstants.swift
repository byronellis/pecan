// ANSI escape code constants shared across PecanUI
let ansiReset       = "\u{001B}[0m"
let ansiBold        = "\u{001B}[1m"
let ansiDim         = "\u{001B}[2m"
let ansiItalic      = "\u{001B}[3m"
let ansiCyan        = "\u{001B}[36m"
let ansiGreen       = "\u{001B}[32m"
let ansiBoldOff     = "\u{001B}[22m"
let ansiItalicOff   = "\u{001B}[23m"
let ansiDimOff      = "\u{001B}[22m"
let ansiUserInputBg = "\u{001B}[48;5;236m"

/// A snapshot of one agent for status-bar and picker rendering.
struct AgentTabInfo: Sendable {
    let id: String
    let name: String
    let teamKey: String   // "" = no team / default team
    let isActive: Bool
    let hasUnread: Bool
    let agentNumber: Int32
}
