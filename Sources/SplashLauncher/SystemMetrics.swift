import Foundation
import IOKit
import Darwin

/// Live hardware metrics: GPU utilization, temperature, ANE load, and RAM usage.
/// GPU % uses public IOKit. GPU temp uses the private AppleSMC interface.
/// ANE % uses the private libIOReport.dylib (same library behind `powermetrics`).
/// RAM uses public Mach host_statistics64.
enum SystemMetrics {
    // MARK: - GPU Utilization (public IOKit)

    /// GPU utilization percentage (0–100) via IOKit AGXAccelerator.
    static func gpuUtilization() -> UInt32 {
        var iter: io_iterator_t = 0
        guard let matching = IOServiceMatching("AGXAccelerator") else { return 0 }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }

        let entry = IOIteratorNext(iter)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any],
              let perf = props["PerformanceStatistics"] as? [String: Any],
              let util = perf["Device Utilization %"] as? Int else { return 0 }
        return UInt32(min(max(util, 0), 100))
    }

    // MARK: - RAM (public Mach)

    /// Total physical RAM in bytes.
    static func physicalMemoryBytes() -> UInt64 {
        var totalMem: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &totalMem, &len, nil, 0) == 0, totalMem > 0 else { return 0 }
        return totalMem
    }

    /// Activity Monitor's "Memory Used": app memory (less purgeable) plus wired plus compressed.
    static func memoryUsedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) >= UInt64(stats.purgeable_count)
            ? UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count) : 0
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }
}

// MARK: - GPU Temperature (private AppleSMC)

private final class SMCGPUTemperature {
    private var conn: io_connect_t = 0
    private var keys: [UInt32] = []

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { IOObjectRelease(service) }
        guard service != 0, IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        for i in 0..<(call(Self.fourCC("#KEY"), 5, size: 4).map { UInt32(bigEndian: u32($0, 48)) } ?? 0) {
            guard let k = call(0, 8, index: i).map({ u32($0, 0) }), k >> 24 == 84, k >> 16 & 255 == 103,
                  info(k)?.1 == Self.fourCC("flt ") else { continue }
            keys.append(k)
        }
        if keys.isEmpty { IOServiceClose(conn); return nil }
    }
    deinit { IOServiceClose(conn) }

    func read() -> Double? {
        keys.compactMap { float($0) }.filter { $0 > 10 && $0 < 150 }.max().map(Double.init)
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ key: UInt32, _ cmd: UInt8, size: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80), output = input, n = 80
        for (v, at) in [(key, 0), (size, 28), (index, 44)] {
            withUnsafeBytes(of: v) { input.replaceSubrange(at..<at + 4, with: $0) }
        }
        input[42] = cmd
        guard IOConnectCallStructMethod(conn, 2, input, 80, &output, &n) == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    private func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
    }
    private func info(_ key: UInt32) -> (UInt32, UInt32)? { call(key, 9).map { (u32($0, 28), u32($0, 32)) } }
    private func float(_ key: UInt32) -> Float? { call(key, 5, size: 4).map { Float(bitPattern: u32($0, 48)) } }
}

// MARK: - ANE Load (private libIOReport.dylib)

private final class ANELoad {
    private typealias Sample = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Name = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias Residency = @convention(c) (CFDictionary, Int32) -> Int64
    private let sub: CFTypeRef, channels: CFMutableDictionary
    private let sample: Sample, delta: Delta, count: Count, residency: Residency
    private var last: CFDictionary?

    init?() {
        typealias Copy = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
        typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                              UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func fn<T>(_ s: String, _: T.Type) -> T? { dlsym(h, s).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = fn("IOReportCopyChannelsInGroup", Copy.self),
              let subscribe = fn("IOReportCreateSubscription", Subscribe.self),
              let sample = fn("IOReportCreateSamples", Sample.self),
              let delta = fn("IOReportCreateSamplesDelta", Delta.self),
              let name = fn("IOReportChannelGetChannelName", Name.self),
              let group = fn("IOReportChannelGetSubGroup", Name.self),
              let count = fn("IOReportStateGetCount", Count.self),
              let residency = fn("IOReportStateGetResidency", Residency.self)
        else { return nil }
        let wanted = ["PMP", "PMP0", "PMP1", "PMP2", "PMP3"].flatMap { g in
            (copy(g as CFString, nil, 0, 0, 0)?.takeRetainedValue() as NSDictionary?)?["IOReportChannels"] as? [NSDictionary] ?? []
        }.filter {
            (name($0)?.takeUnretainedValue() as String? ?? "").hasPrefix("ANE") &&
            (group($0)?.takeUnretainedValue() as String? ?? "").contains("Floor")
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard !wanted.isEmpty,
              let sub = subscribe(nil, NSMutableDictionary(dictionary: ["IOReportChannels": wanted]), &subscribed, 0, nil)?.takeRetainedValue(),
              let subscribed else { return nil }
        self.sub = sub
        channels = subscribed.takeRetainedValue()
        self.sample = sample; self.delta = delta; self.count = count; self.residency = residency
    }

    func read() -> Double? {
        guard let now = sample(sub, channels, nil)?.takeRetainedValue() else { return nil }
        defer { last = now }
        guard let last, let d = delta(last, now, nil)?.takeRetainedValue() as NSDictionary? else { return nil }
        var busiest = 0.0
        for c in d["IOReportChannels"] as? [NSDictionary] ?? [] {
            let r = (0..<count(c)).map { residency(c, $0) }, total = r.reduce(0, +)
            guard total > 0 else { continue }
            busiest = max(busiest, Double(total - r[0]) / Double(total) * 100)
        }
        return busiest
    }
}

// MARK: - Hardware Sensors (lazy singletons)

final class HardwareSensors {
    static let shared = HardwareSensors()
    private let gpuTemp: SMCGPUTemperature?
    private let ane: ANELoad?

    private init() {
        gpuTemp = SMCGPUTemperature()
        ane = ANELoad()
    }

    func gpuTemperature() -> Double? { gpuTemp?.read() }
    func aneLoad() -> Double? { ane?.read() }
}
