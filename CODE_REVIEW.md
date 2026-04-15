# Pecan Code Review: Critical Architectural and Implementation Analysis

This review is a high-level critique of the current `pecan` codebase. The system, while functional, exhibits significant technical debt, poor separation of concerns, and several performance bottlenecks.

## 1. Monolithic "God Objects" and Poor Separation of Concerns

The architecture is dominated by a few massive components that handle far too many responsibilities.

*   **`SessionManager` (Server):** This actor is a classic "God Object." It manages gRPC streams, persistent database stores, project/team metadata, agent busy states, command queuing, merge states, git integration, and container spawning. This violates the Single Responsibility Principle (SRP) and makes the system extremely difficult to test, maintain, or scale.
*   **`PecanAgent/main.swift` & `PecanServer/main.swift`:** Both entry points contain massive `main` functions (400+ lines) that mix argument parsing, initialization, gRPC setup, and giant, nested switch statements for event handling. Business logic should be extracted into dedicated service or handler classes.
*   **`ToolManager` & `SkillManager`:** These managers are also doing too much: discovery, registration, execution, and integration with external scripting languages (Lua).

## 2. Technical Debt and Code Quality

The code lacks modern Swift idiomatic standards and type safety.

*   **Excessive Use of `[String: Any]`:** The codebase relies heavily on untyped dictionaries for internal data passing and JSON manipulation. This bypasses Swift's type system and leads to runtime errors that could be caught at compile time.
*   **Manual JSON Serialization:** There is a pervasive use of `JSONSerialization.jsonObject` and `data(withJSONObject:)` instead of the more modern and type-safe `Codable` protocol.
*   **Force Unwraps and Swallowed Errors:** Numerous instances of `!` (force unwrap) and `try?` (swallowing errors) were found. Critical failures are often logged but not properly handled, leading to unpredictable system states.
*   **Logic Duplication:** The `detectLuaModule` logic is literally copy-pasted between `ToolManager.swift` and `SkillManager.swift`. This is a major maintenance red flag.
*   **Hand-rolled Parsers:** The YAML frontmatter parser in `SkillManager` and the slash-command parser in `PecanServer` are fragile, hand-rolled implementations that lack the robustness of established libraries.

## 3. Performance Bottlenecks

Several components have implementation flaws that will cause significant performance degradation as the system scales or handles larger workloads.

*   **FUSE Filesystem (`COWOverlayFS`):**
    *   **Memory Inefficiency:** The `read` implementation loads the *entire* file into memory for every request, regardless of the requested size or offset. This is a catastrophic failure for a filesystem handling large files.
    *   **Inefficient Diffing:** `generateDiff()` spawns a new `/usr/bin/diff` process for *every single file* in the overlay every time the virtual `.pecan/diff` file is accessed. This will crawl on even moderately sized changesets.
    *   **Cache Invalidation:** The virtual file cache is wiped on *any* write to the filesystem, leading to frequent and expensive re-generations.
*   **Lua State Management:** `LuaPromptFragment` creates a brand new `LuaState` for every single render call. This is an expensive operation that should be pooled or reused.

## 4. Fragility and Maintainability

*   **HTML Parsing via Regex:** `WebSearchTool` uses regular expressions to parse DuckDuckGo's HTML. This is notoriously fragile and will break immediately upon any minor UI change from the provider.
*   **Hardcoded Values:** Ports, paths (e.g., `/bin/sh`, `/usr/bin/grep`), and configuration defaults are hardcoded throughout the codebase rather than being centralized or injected.
*   **Singleton Overuse:** The heavy reliance on `.shared` singletons makes unit testing nearly impossible, as components are tightly coupled to global state.

## 5. Testing Gaps

*   **Low Unit Test Coverage:** While integration tests exist, the monolithic nature of the classes makes true unit testing (testing logic in isolation) nearly non-existent.
*   **Lack of Performance Tests:** Given the issues in the FUSE and Diffing implementations, the lack of performance benchmarks is a major oversight.

## Recommendations for Immediate Action

1.  **Refactor `SessionManager`:** Break it down into specialized managers (e.g., `StreamRegistry`, `ProjectManager`, `StoreCoordinator`).
2.  **Adopt `Codable`:** Replace all manual JSON dictionary manipulation with strongly typed models.
3.  **Optimize FUSE:** Implement streaming reads and a more efficient diffing mechanism (e.g., using a library or tracking changes incrementally).
4.  **Extract Service Logic:** Move the giant switch statements in `main.swift` files into dedicated command/event handlers.
5.  **Unify Scripting Logic:** Create a shared `LuaService` to handle state and module detection instead of duplicating it.
