import Foundation

public struct AgentNames {
    public static let names = [
        // Tron
        "tron", "clu", "flynn", "quorra", "rinzler", "sark", "yori", "ram",
        // Famous robots
        "rosie", "bender", "walle", "r2d2", "c3po", "data", "bishop",
        "hal", "sonny", "optimus", "gort", "robbie", "ash", "johnny5",
        "baymax", "chappie", "marvin", "kryten", "dot", "gir"
    ]

    public static func randomName() -> String {
        names.randomElement()!
    }
}
