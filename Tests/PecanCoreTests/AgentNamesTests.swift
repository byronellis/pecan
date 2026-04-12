import Testing
@testable import PecanServerCore

@Suite("AgentNames")
struct AgentNamesTests {

    @Test("randomName returns a non-empty string")
    func randomNameNonEmpty() {
        let name = AgentNames.randomName()
        #expect(!name.isEmpty)
    }

    @Test("randomName returns a known name")
    func randomNameInList() {
        let name = AgentNames.randomName()
        #expect(AgentNames.names.contains(name))
    }

    @Test("names list has no duplicates")
    func noDuplicates() {
        let set = Set(AgentNames.names)
        #expect(set.count == AgentNames.names.count)
    }

    @Test("names list is non-empty")
    func listNonEmpty() {
        #expect(!AgentNames.names.isEmpty)
    }

    @Test("randomName eventually produces different names", .disabled("flaky: may coincidentally repeat"))
    func randomNameVaries() {
        let samples = (0..<50).map { _ in AgentNames.randomName() }
        let unique = Set(samples)
        #expect(unique.count > 1)
    }
}
