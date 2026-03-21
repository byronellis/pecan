import Foundation
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

/// Read-only FUSE filesystem exposing ~/.pecan/skills/ to the agent container.
///
/// Path structure:
///   /                           → list of skill names
///   /<skill>/                   → SKILL.md + scripts/
///   /<skill>/SKILL.md           → skill instructions
///   /<skill>/scripts/           → executable scripts (Lua wrappers + shell scripts)
///   /<skill>/scripts/<name>     → script content
///
/// Lua modules (scripts/*.lua) are not exposed directly — a virtual wrapper
/// script is generated that calls `pecan-agent invoke <name> "$@"`.
final class SkillsFilesystem: PecanFuseFS {

    struct ScriptEntry {
        let content: Data
    }

    struct SkillEntry {
        let skillMD: Data
        let scripts: [String: ScriptEntry]   // name (no .lua) → entry
    }

    private let skills: [String: SkillEntry]

    init(skillsDir: String) {
        var built: [String: SkillEntry] = [:]
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: skillsDir) else {
            skills = built
            return
        }
        for entry in entries.sorted() {
            let skillDir = "\(skillsDir)/\(entry)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: skillDir, isDirectory: &isDir), isDir.boolValue else { continue }

            let skillMDPath = "\(skillDir)/SKILL.md"
            guard let mdData = try? Data(contentsOf: URL(fileURLWithPath: skillMDPath)) else { continue }

            var scripts: [String: ScriptEntry] = [:]
            let scriptsDir = "\(skillDir)/scripts"
            if let scriptFiles = try? fm.contentsOfDirectory(atPath: scriptsDir) {
                for file in scriptFiles.sorted() {
                    if file.hasSuffix(".lua") {
                        // Generate wrapper script
                        let baseName = (file as NSString).deletingPathExtension
                        let wrapper = "#!/bin/sh\npecan-agent invoke \(baseName) \"$@\"\n"
                        scripts[baseName] = ScriptEntry(content: Data(wrapper.utf8))
                    } else if !file.hasPrefix(".") {
                        let filePath = "\(scriptsDir)/\(file)"
                        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                            scripts[file] = ScriptEntry(content: data)
                        }
                    }
                }
            }

            built[entry] = SkillEntry(skillMD: mdData, scripts: scripts)
        }
        skills = built
    }

    // MARK: - PecanFuseFS

    func getattr(_ path: String, _ stbuf: UnsafeMutablePointer<stat>) -> Int32 {
        stbuf.pointee = stat()
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch components.count {
        case 0:
            // Root directory
            stbuf.pointee.st_mode = S_IFDIR | 0o555
            stbuf.pointee.st_nlink = 2
            return 0
        case 1:
            // /<skill>
            guard skills[components[0]] != nil else { return -ENOENT }
            stbuf.pointee.st_mode = S_IFDIR | 0o555
            stbuf.pointee.st_nlink = 2
            return 0
        case 2:
            let skillName = components[0]
            let name = components[1]
            guard let skill = skills[skillName] else { return -ENOENT }
            if name == "SKILL.md" {
                stbuf.pointee.st_mode = S_IFREG | 0o444
                stbuf.pointee.st_nlink = 1
                stbuf.pointee.st_size = off_t(skill.skillMD.count)
                return 0
            } else if name == "scripts" {
                stbuf.pointee.st_mode = S_IFDIR | 0o555
                stbuf.pointee.st_nlink = 2
                return 0
            }
            return -ENOENT
        case 3:
            let skillName = components[0]
            guard components[1] == "scripts",
                  let skill = skills[skillName],
                  let script = skill.scripts[components[2]] else { return -ENOENT }
            stbuf.pointee.st_mode = S_IFREG | 0o555   // executable
            stbuf.pointee.st_nlink = 1
            stbuf.pointee.st_size = off_t(script.content.count)
            return 0
        default:
            return -ENOENT
        }
    }

    func readdir(_ path: String, buf: UnsafeMutableRawPointer?, filler: UnsafeMutableRawPointer?, offset: off_t) -> Int32 {
        pecan_fuse_fill(filler, buf, ".")
        pecan_fuse_fill(filler, buf, "..")

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch components.count {
        case 0:
            for name in skills.keys.sorted() {
                pecan_fuse_fill(filler, buf, name)
            }
        case 1:
            guard skills[components[0]] != nil else { return -ENOENT }
            pecan_fuse_fill(filler, buf, "SKILL.md")
            pecan_fuse_fill(filler, buf, "scripts")
        case 2:
            let skillName = components[0]
            guard components[1] == "scripts",
                  let skill = skills[skillName] else { return -ENOENT }
            for name in skill.scripts.keys.sorted() {
                pecan_fuse_fill(filler, buf, name)
            }
        default:
            return -ENOENT
        }
        return 0
    }

    func read(_ path: String, buf: UnsafeMutablePointer<CChar>?, size: Int, offset: off_t) -> Int32 {
        guard let buf else { return -EIO }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        let data: Data
        switch components.count {
        case 2 where components[1] == "SKILL.md":
            guard let skill = skills[components[0]] else { return -ENOENT }
            data = skill.skillMD
        case 3 where components[1] == "scripts":
            guard let skill = skills[components[0]],
                  let script = skill.scripts[components[2]] else { return -ENOENT }
            data = script.content
        default:
            return -ENOENT
        }

        let fileSize = data.count
        guard offset < off_t(fileSize) else { return 0 }
        let available = fileSize - Int(offset)
        let toRead = min(size, available)
        data.withUnsafeBytes { ptr in
            buf.withMemoryRebound(to: UInt8.self, capacity: toRead) { dst in
                let src = ptr.baseAddress!.advanced(by: Int(offset)).assumingMemoryBound(to: UInt8.self)
                dst.update(from: src, count: toRead)
            }
        }
        return Int32(toRead)
    }
}
