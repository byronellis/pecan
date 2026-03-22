#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - FUSEFilesystem protocol

protocol FUSEFilesystem: Actor {
    func lookup(parent: UInt64, name: String) async -> Result<FUSEEntryOut, FUSEErrno>
    func getattr(nodeID: UInt64) async -> Result<FUSEAttrOut, FUSEErrno>
    func setattr(nodeID: UInt64, valid: UInt32, size: UInt64?, mode: UInt32?) async -> Result<FUSEAttrOut, FUSEErrno>
    func opendir(nodeID: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno>
    func readdir(nodeID: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno>
    func releasedir(nodeID: UInt64, fh: UInt64) async
    func open(nodeID: UInt64, flags: UInt32) async -> Result<UInt64, FUSEErrno>
    func read(nodeID: UInt64, fh: UInt64, offset: UInt64, size: UInt32) async -> Result<Data, FUSEErrno>
    func write(nodeID: UInt64, fh: UInt64, offset: UInt64, data: Data, flags: UInt32) async -> Result<UInt32, FUSEErrno>
    func create(parent: UInt64, name: String, mode: UInt32, flags: UInt32) async -> Result<(FUSEEntryOut, FUSEOpenOut), FUSEErrno>
    func mkdir(parent: UInt64, name: String, mode: UInt32) async -> Result<FUSEEntryOut, FUSEErrno>
    func unlink(parent: UInt64, name: String) async -> Result<Void, FUSEErrno>
    func rmdir(parent: UInt64, name: String) async -> Result<Void, FUSEErrno>
    func rename(oldParent: UInt64, oldName: String, newParent: UInt64, newName: String) async -> Result<Void, FUSEErrno>
    func release(nodeID: UInt64, fh: UInt64) async
    func forget(nodeID: UInt64, nlookup: UInt64) async
}

// MARK: - FUSEServer actor

actor FUSEServer {
    private let fd: Int32
    private let fs: any FUSEFilesystem

    init(fd: Int32, fs: any FUSEFilesystem) {
        self.fd = fd
        self.fs = fs
    }

    func run() async {
        let bufSize = 1024 * 1024 // 1 MB
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        while true {
            let bytesRead = read(fd, buf, bufSize)
            if bytesRead <= 0 { break }

            let data = Data(bytes: buf, count: bytesRead)
            guard let hdr = readStruct(FUSEInHeader.self, from: data, offset: 0) else { continue }
            let headerSize = MemoryLayout<FUSEInHeader>.size

            guard let opcode = FUSEOpcode(rawValue: hdr.opcode) else {
                let resp = buildResponse(unique: hdr.unique, error: -ENOSYS)
                writeResponse(resp)
                continue
            }

            switch opcode {

            case .init_:
                var initOut = FUSEInitOut()
                initOut.major = 7
                initOut.minor = 26
                initOut.max_readahead = 65536
                initOut.flags = 0
                initOut.max_background = 16
                initOut.congestion_threshold = 12
                initOut.max_write = 131072
                initOut.time_gran = 1
                initOut.max_pages = 32
                initOut.padding = 0
                let resp = buildResponse(unique: hdr.unique, body: initOut)
                writeResponse(resp)

            case .forget:
                guard let forgetIn = readStruct(FUSEForgetIn.self, from: data, offset: headerSize) else { continue }
                await fs.forget(nodeID: hdr.nodeid, nlookup: forgetIn.nlookup)
                // No response for FORGET

            case .lookup:
                let nameData = data.dropFirst(headerSize)
                let name = cStringFromData(nameData)
                let result = await fs.lookup(parent: hdr.nodeid, name: name)
                switch result {
                case .success(let entryOut):
                    writeResponse(buildResponse(unique: hdr.unique, body: entryOut))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .getattr:
                let result = await fs.getattr(nodeID: hdr.nodeid)
                switch result {
                case .success(let attrOut):
                    writeResponse(buildResponse(unique: hdr.unique, body: attrOut))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .setattr:
                guard let setattrIn = readStruct(FUSESetAttrIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let size: UInt64? = (setattrIn.valid & FATTR_SIZE) != 0 ? setattrIn.size : nil
                let mode: UInt32? = (setattrIn.valid & FATTR_MODE) != 0 ? setattrIn.mode : nil
                let result = await fs.setattr(nodeID: hdr.nodeid, valid: setattrIn.valid, size: size, mode: mode)
                switch result {
                case .success(let attrOut):
                    writeResponse(buildResponse(unique: hdr.unique, body: attrOut))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .opendir:
                guard let openIn = readStruct(FUSEOpenIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let result = await fs.opendir(nodeID: hdr.nodeid, flags: openIn.flags)
                switch result {
                case .success(let fh):
                    var openOut = FUSEOpenOut()
                    openOut.fh = fh
                    openOut.open_flags = 0
                    openOut.padding = 0
                    writeResponse(buildResponse(unique: hdr.unique, body: openOut))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .readdir:
                guard let readIn = readStruct(FUSEReadIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let result = await fs.readdir(nodeID: hdr.nodeid, fh: readIn.fh, offset: readIn.offset, size: readIn.size)
                switch result {
                case .success(let dirData):
                    writeResponse(buildResponse(unique: hdr.unique, body: dirData))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .releasedir:
                guard let releaseIn = readStruct(FUSEReleaseIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: 0))
                    continue
                }
                await fs.releasedir(nodeID: hdr.nodeid, fh: releaseIn.fh)
                writeResponse(buildResponse(unique: hdr.unique, error: 0))

            case .open:
                guard let openIn = readStruct(FUSEOpenIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let result = await fs.open(nodeID: hdr.nodeid, flags: openIn.flags)
                switch result {
                case .success(let fh):
                    var openOut = FUSEOpenOut()
                    openOut.fh = fh
                    openOut.open_flags = 0
                    openOut.padding = 0
                    writeResponse(buildResponse(unique: hdr.unique, body: openOut))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .read:
                guard let readIn = readStruct(FUSEReadIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let result = await fs.read(nodeID: hdr.nodeid, fh: readIn.fh, offset: readIn.offset, size: readIn.size)
                switch result {
                case .success(let fileData):
                    writeResponse(buildResponse(unique: hdr.unique, body: fileData))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .write:
                guard let writeIn = readStruct(FUSEWriteIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let writeDataOffset = headerSize + MemoryLayout<FUSEWriteIn>.size
                let writeData = data.dropFirst(writeDataOffset)
                let result = await fs.write(nodeID: hdr.nodeid, fh: writeIn.fh, offset: writeIn.offset,
                                            data: Data(writeData), flags: writeIn.write_flags)
                switch result {
                case .success(let written):
                    var writeOut = FUSEWriteOut()
                    writeOut.size = written
                    writeOut.padding = 0
                    writeResponse(buildResponse(unique: hdr.unique, body: writeOut))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .create:
                guard let createIn = readStruct(FUSECreateIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let nameData = data.dropFirst(headerSize + MemoryLayout<FUSECreateIn>.size)
                let name = cStringFromData(nameData)
                let result = await fs.create(parent: hdr.nodeid, name: name, mode: createIn.mode, flags: createIn.flags)
                switch result {
                case .success(let (entryOut, openOut)):
                    let entrySize = MemoryLayout<FUSEEntryOut>.size
                    let openSize = MemoryLayout<FUSEOpenOut>.size
                    var bodyData = Data(count: entrySize + openSize)
                    bodyData.withUnsafeMutableBytes { ptr in
                        var e = entryOut
                        withUnsafeBytes(of: &e) { src in
                            ptr.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: entrySize)
                        }
                        var o = openOut
                        withUnsafeBytes(of: &o) { src in
                            ptr.baseAddress!.advanced(by: entrySize).copyMemory(from: src.baseAddress!, byteCount: openSize)
                        }
                    }
                    writeResponse(buildResponse(unique: hdr.unique, body: bodyData))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .mkdir:
                guard let mkdirIn = readStruct(FUSEMkdirIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                let nameData = data.dropFirst(headerSize + MemoryLayout<FUSEMkdirIn>.size)
                let name = cStringFromData(nameData)
                let result = await fs.mkdir(parent: hdr.nodeid, name: name, mode: mkdirIn.mode)
                switch result {
                case .success(let entryOut):
                    writeResponse(buildResponse(unique: hdr.unique, body: entryOut))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .unlink:
                let nameData = data.dropFirst(headerSize)
                let name = cStringFromData(nameData)
                let result = await fs.unlink(parent: hdr.nodeid, name: name)
                switch result {
                case .success:
                    writeResponse(buildResponse(unique: hdr.unique, error: 0))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .rmdir:
                let nameData = data.dropFirst(headerSize)
                let name = cStringFromData(nameData)
                let result = await fs.rmdir(parent: hdr.nodeid, name: name)
                switch result {
                case .success:
                    writeResponse(buildResponse(unique: hdr.unique, error: 0))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .rename:
                guard let renameIn = readStruct(FUSERenameIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: -EIO))
                    continue
                }
                // After the FUSERenameIn struct, there are two null-terminated strings: oldname, newname
                let namesOffset = headerSize + MemoryLayout<FUSERenameIn>.size
                let namesData = data.dropFirst(namesOffset)
                let (oldName, newName) = twoStringsFromData(namesData)
                let result = await fs.rename(oldParent: hdr.nodeid, oldName: oldName, newParent: renameIn.newdir, newName: newName)
                switch result {
                case .success:
                    writeResponse(buildResponse(unique: hdr.unique, error: 0))
                case .failure(let err):
                    writeResponse(buildResponse(unique: hdr.unique, error: err.code))
                }

            case .release:
                guard let releaseIn = readStruct(FUSEReleaseIn.self, from: data, offset: headerSize) else {
                    writeResponse(buildResponse(unique: hdr.unique, error: 0))
                    continue
                }
                await fs.release(nodeID: hdr.nodeid, fh: releaseIn.fh)
                writeResponse(buildResponse(unique: hdr.unique, error: 0))

            case .statfs:
                // Return a minimal statfs response (all zeros is acceptable)
                let statfsOut = Data(count: 80) // fuse_statfs_out size
                writeResponse(buildResponse(unique: hdr.unique, body: statfsOut))

            case .mknod:
                writeResponse(buildResponse(unique: hdr.unique, error: -ENOSYS))
            }
        }
    }

    private func writeResponse(_ data: Data) {
        data.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, data.count)
        }
    }
}

// MARK: - String parsing helpers

private func parseCString(from bytes: some Collection<UInt8>) -> String {
    var result = [UInt8]()
    for byte in bytes {
        if byte == 0 { break }
        result.append(byte)
    }
    return String(bytes: result, encoding: .utf8) ?? ""
}

private func cStringFromData(_ data: some Collection<UInt8>) -> String {
    parseCString(from: data)
}

private func twoStringsFromData(_ data: Data.SubSequence) -> (String, String) {
    let bytes = Array(data)
    var first = [UInt8]()
    var second = [UInt8]()
    var i = 0
    while i < bytes.count && bytes[i] != 0 {
        first.append(bytes[i])
        i += 1
    }
    i += 1 // skip null
    while i < bytes.count && bytes[i] != 0 {
        second.append(bytes[i])
        i += 1
    }
    let s1 = String(bytes: first, encoding: .utf8) ?? ""
    let s2 = String(bytes: second, encoding: .utf8) ?? ""
    return (s1, s2)
}

#endif // os(Linux)
