//
//  CrashFrameSymbolicator.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation
import MachO

/// Names the function a crash frame was in, given the binary and the offset into it.
protocol CrashFrameSymbolicating: Sendable {
    /// The symbol containing `offset` in the binary with `binaryUUID`, or `nil` if it cannot be
    /// named.
    func symbol(binaryUUID: UUID, offset: UInt64) -> String?
}

/// Best-effort symbolication against the images loaded in this process.
///
/// A MetricKit crash happened in an earlier launch, but if the same build is running now, its
/// images have the same UUIDs and the same layout. Adding the frame's offset to where the image is
/// loaded *now* gives an address `dladdr` can name. That works for any binary that still carries
/// its symbol table: the app in a debug build, and the system libraries. A stripped release build
/// gives nothing, and the frame is shown as a binary and offset alone.
///
/// Swift symbols are demangled.
struct LoadedImageSymbolicator: CrashFrameSymbolicating {
    /// Where each loaded image's Mach-O header — the start of its `__TEXT` segment — is, by UUID.
    private let headers: [UUID: UInt]

    /// Reads the UUID of every image loaded right now.
    init() {
        var headers: [UUID: UInt] = [:]
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let uuid = Self.uuid(of: header) else { continue }
            headers[uuid] = UInt(bitPattern: header)
        }
        self.headers = headers
    }

    func symbol(binaryUUID: UUID, offset: UInt64) -> String? {
        guard let base = headers[binaryUUID],
              let address = UnsafeRawPointer(bitPattern: base &+ UInt(offset)) else { return nil }

        var info = Dl_info()
        guard dladdr(address, &info) != 0, let name = info.dli_sname else { return nil }

        let symbol = Self.demangle(String(cString: name))
        let distance = UInt(bitPattern: address) &- UInt(bitPattern: info.dli_saddr)
        return "\(symbol) + \(distance)"
    }

    /// Reads `LC_UUID` from a 64-bit Mach-O header.
    static func uuid(of header: UnsafePointer<mach_header>) -> UUID? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                let uuid = command.load(as: uuid_command.self).uuid
                return UUID(uuid: uuid)
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    /// Demangles a Swift symbol, or returns anything else unchanged.
    private static func demangle(_ symbol: String) -> String {
        guard let demangled = swift_demangle(symbol, UInt(symbol.utf8.count), nil, nil, 0) else {
            return symbol
        }
        defer { free(demangled) }
        return String(cString: demangled)
    }
}

/// The Swift runtime's demangler. Exported by `libswiftCore` and stable since the Swift 5 ABI.
@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
#endif
