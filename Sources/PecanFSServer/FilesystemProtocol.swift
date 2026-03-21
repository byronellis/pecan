import Foundation
import CPecanFuse

#if canImport(Darwin)
import Darwin
#endif

/// Protocol that both MemoryFilesystem and SkillsFilesystem conform to,
/// allowing the FUSE callback trampolines in main.swift to be shared.
protocol PecanFuseFS: AnyObject {
    func getattr(_ path: String, _ stbuf: UnsafeMutablePointer<stat>) -> Int32
    func readdir(_ path: String, buf: UnsafeMutableRawPointer?, filler: UnsafeMutableRawPointer?, offset: off_t) -> Int32
    func read(_ path: String, buf: UnsafeMutablePointer<CChar>?, size: Int, offset: off_t) -> Int32
    func write(_ path: String, buf: UnsafePointer<CChar>?, size: Int, offset: off_t) -> Int32
    func create(_ path: String, mode: mode_t) -> Int32
    func truncate(_ path: String, size: off_t) -> Int32
    func unlink(_ path: String) -> Int32
    func rename(from: String, to: String) -> Int32
    func release(_ path: String) -> Int32
}

extension PecanFuseFS {
    func write(_ path: String, buf: UnsafePointer<CChar>?, size: Int, offset: off_t) -> Int32 { -EROFS }
    func create(_ path: String, mode: mode_t) -> Int32 { -EROFS }
    func truncate(_ path: String, size: off_t) -> Int32 { -EROFS }
    func unlink(_ path: String) -> Int32 { -EROFS }
    func rename(from: String, to: String) -> Int32 { -EROFS }
    func release(_ path: String) -> Int32 { 0 }
}
