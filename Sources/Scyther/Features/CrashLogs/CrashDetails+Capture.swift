//
//  CrashDetails+Capture.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation
import MachO

extension CrashDetails {
    /// Captures the details of an uncaught Objective-C exception in the process that is about to
    /// die.
    ///
    /// Runs inside the exception handler, which — unlike a signal handler — is ordinary code: the
    /// process is still whole, so `dladdr` and the Objective-C runtime are safe to use.
    ///
    /// An uncaught exception ends in `abort()`, so the crash is recorded as `EXC_CRASH (SIGABRT)`,
    /// as the system reports it. The exception's own backtrace goes in ``exceptionBacktrace``; the
    /// handler's thread, which is where the process actually stops, is the crashed thread.
    ///
    /// - Parameters:
    ///   - exception: The exception.
    ///   - crashingStack: The handler thread's return addresses. Injected for tests.
    /// - Returns: The details.
    static func capture(
        exception: NSException,
        crashingStack: [UInt] = Foundation.Thread.callStackReturnAddresses.map(\.uintValue)
    ) -> CrashDetails {
        var resolver = ProcessImageResolver()
        let backtrace = exception.callStackReturnAddresses.map { resolver.frame(for: $0.uintValue) }
        let crashing = crashingStack.map { resolver.frame(for: $0) }

        var details = CrashDetails()
        details.exceptionType = "EXC_CRASH"
        details.signal = "SIGABRT"
        details.terminationReason = "*** Terminating app due to uncaught exception '\(exception.name.rawValue)', reason: '\(exception.reason ?? "")'"
        details.hardwareModel = currentHardwareModel
        details.operatingSystem = currentOperatingSystem
        details.processID = Int(getpid())
        details.bundleIdentifier = Bundle.main.bundleIdentifier
        details.architecture = currentArchitecture
        details.threads = [Thread(crashed: true, frames: crashing)]
        details.exceptionBacktrace = backtrace
        details.images = resolver.images
        return details
    }

    /// The hardware model identifier, such as `iPhone17,1`. On the Simulator, the model being
    /// simulated rather than the Mac's.
    static var currentHardwareModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    /// The operating system as crash reports write it, such as `iPhone OS 18.0 (22A3354)`: the
    /// version and build from `ProcessInfo`, which reads them as `Version 18.0 (Build 22A3354)`.
    static var currentOperatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let description = ProcessInfo.processInfo.operatingSystemVersionString
        guard let range = description.range(of: "Build "),
              let close = description[range.upperBound...].firstIndex(of: ")") else {
            return "iPhone OS \(number)"
        }
        return "iPhone OS \(number) (\(description[range.upperBound..<close]))"
    }

    /// The architecture this process runs as.
    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// Resolves addresses in this process to binary images and offsets, collecting each image once.
struct ProcessImageResolver {
    /// The images resolved so far, in the order first seen.
    private(set) var images: [CrashDetails.BinaryImage] = []

    /// The index of each image in ``images``, by load address.
    private var indices: [UInt: Int] = [:]

    /// The frame for a return address.
    mutating func frame(for address: UInt) -> CrashDetails.Frame {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return CrashDetails.Frame() }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let base = info.dli_fbase else {
            return CrashDetails.Frame()
        }
        let loadAddress = UInt(bitPattern: base)
        let index = indices[loadAddress] ?? {
            let path = info.dli_fname.map { String(cString: $0) }
            let image = CrashDetails.BinaryImage(
                name: path.map { ($0 as NSString).lastPathComponent } ?? "???",
                uuid: LoadedImageSymbolicator.uuid(of: base.assumingMemoryBound(to: mach_header.self)),
                loadAddress: UInt64(loadAddress),
                path: path,
                architecture: CrashDetails.currentArchitecture
            )
            images.append(image)
            indices[loadAddress] = images.count - 1
            return images.count - 1
        }()
        let symbol = LoadedImageSymbolicator.symbol(at: pointer)
        return CrashDetails.Frame(imageIndex: index, offset: UInt64(address - loadAddress),
                                  symbol: symbol?.name, symbolOffset: symbol?.distance)
    }
}
#endif
