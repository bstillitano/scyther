//
//  CrashDetails.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Everything about a crash that is needed to debug it but is too large to keep in the crash list
/// itself: every thread, the binary images they ran in, and the exception's codes.
///
/// A ``CrashLogEntry`` carries what the crash list shows. Its details live in a file of their own,
/// written by ``CrashArtifactStore``, and are read when the crash is opened or exported. They are
/// what makes an exported crash symbolicatable: a frame is a binary's UUID plus an offset, and the
/// UUID is what ties it to the dSYM of the exact build that crashed.
public struct CrashDetails: Codable, Equatable, Sendable {
    /// One loaded binary.
    public struct BinaryImage: Codable, Equatable, Sendable {
        /// The binary's file name, such as `MyApp` or `UIKitCore`.
        public var name: String

        /// The binary's UUID, which matches the UUID of its dSYM.
        public var uuid: UUID?

        /// Where the binary's `__TEXT` segment was loaded in the crashed process, if known.
        public var loadAddress: UInt64?

        /// The binary's path on the device, if known.
        public var path: String?

        /// The CPU architecture, such as `arm64`.
        public var architecture: String?
    }

    /// One frame of a thread's stack.
    public struct Frame: Codable, Equatable, Sendable {
        /// The index of the frame's binary in ``CrashDetails/images``.
        public var imageIndex: Int?

        /// The frame's offset into its binary's `__TEXT` segment.
        public var offset: UInt64?

        /// The function the frame was in, when the capturing process could name it.
        public var symbol: String?

        /// How far into ``symbol`` the frame's address is, in bytes.
        public var symbolOffset: UInt64?
    }

    /// One thread.
    public struct Thread: Codable, Equatable, Sendable {
        /// Whether the crash happened on this thread.
        public var crashed: Bool

        /// The frames, top of the stack first.
        public var frames: [Frame]
    }

    /// The Mach exception type's name, such as `EXC_BAD_ACCESS`.
    public var exceptionType: String?

    /// The signal's name, such as `SIGSEGV`.
    public var signal: String?

    /// The Mach exception codes. For `EXC_BAD_ACCESS` the second is the faulting address.
    public var exceptionCodes: [UInt64] = []

    /// The system's description of why the process was terminated.
    public var terminationReason: String?

    /// The virtual memory region around a faulting address, as MetricKit describes it.
    public var virtualMemoryRegionInfo: String?

    /// The hardware model identifier, such as `iPhone17,1`.
    public var hardwareModel: String?

    /// The operating system, as crash reports write it, such as `iPhone OS 18.0 (22A3354)`.
    public var operatingSystem: String?

    /// The crashed process's identifier.
    public var processID: Int?

    /// The app's bundle identifier.
    public var bundleIdentifier: String?

    /// The CPU architecture, such as `arm64`.
    public var architecture: String?

    /// Every thread MetricKit captured, or the exception's own backtrace.
    public var threads: [Thread] = []

    /// The binaries the frames point into.
    public var images: [BinaryImage] = []

    /// The stack the Objective-C exception was raised from, for a crash the exception handler
    /// caught. The crashing thread's own stack ends in `abort()`; this one says where the exception
    /// came from.
    public var exceptionBacktrace: [Frame]?

    /// How the crash was tied to the session whose console output and network traffic are
    /// exported with it.
    public var sessionMatch: String?

    /// The thread the crash happened on, if any is marked.
    public var crashedThread: Thread? {
        threads.first(where: \.crashed)
    }
}
#endif

#if !os(macOS)
extension CrashDetails {
    /// These details — an exception handler's — with what MetricKit reported for the same crash.
    ///
    /// The handler sees the exception's backtrace, symbolicated in the dying process, but only
    /// the one thread it runs on. MetricKit sees every thread. The result keeps the handler's
    /// backtrace and adopts MetricKit's threads, re-pointing their frames at a single list of
    /// images, matched by UUID. Anything the handler could not know — the exception codes, the
    /// memory region — comes from MetricKit.
    ///
    /// - Parameter metricKit: MetricKit's details for the same crash.
    /// - Returns: The merged details.
    func merging(metricKit: CrashDetails) -> CrashDetails {
        var merged = self
        var indices: [Int: Int] = [:]
        for (index, image) in metricKit.images.enumerated() {
            if let uuid = image.uuid, let existing = merged.images.firstIndex(where: { $0.uuid == uuid }) {
                indices[index] = existing
            } else {
                merged.images.append(image)
                indices[index] = merged.images.count - 1
            }
        }
        if !metricKit.threads.isEmpty {
            merged.threads = metricKit.threads.map { thread in
                CrashDetails.Thread(crashed: thread.crashed, frames: thread.frames.map { frame in
                    var frame = frame
                    frame.imageIndex = frame.imageIndex.flatMap { indices[$0] }
                    return frame
                })
            }
        }
        if merged.exceptionCodes.isEmpty { merged.exceptionCodes = metricKit.exceptionCodes }
        merged.virtualMemoryRegionInfo = merged.virtualMemoryRegionInfo ?? metricKit.virtualMemoryRegionInfo
        merged.processID = merged.processID ?? metricKit.processID
        merged.bundleIdentifier = merged.bundleIdentifier ?? metricKit.bundleIdentifier
        return merged
    }
}
#endif
