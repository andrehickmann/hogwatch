import Darwin
import Foundation
import IOKit

/// System-wide counters from sysctl, Mach and IOKit. All readable without root.
enum Sys {
    static func string(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func value<T>(_ name: String, _ initial: T) -> T {
        var v = initial
        var size = MemoryLayout<T>.size
        sysctlbyname(name, &v, &size, nil, 0)
        return v
    }

    static let model = string("hw.model")
    static let memTotal = Double(value("hw.memsize", UInt64(0)))
    static let pageSize = UInt64(value("hw.pagesize", Int64(16384)))

    static func load() -> [Double] {
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        return la
    }

    /// Cumulative CPU ticks: (busy, total).
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks // user, system, idle, nice
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        return (busy, busy + UInt64(t.2))
    }

    /// Memory used like Activity Monitor counts it, in bytes: app memory + wired + compressed (physical size).
    static func memory() -> (app: Double, wired: Double, compressed: Double) {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return (0, 0, 0) }
        let page = Double(pageSize)
        return ((Double(s.internal_page_count) - Double(s.purgeable_count)) * page,
                Double(s.wire_count) * page, Double(s.compressor_page_count) * page)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    // Private libsystem call Activity Monitor uses to attribute XPC services and VMs to their app.
    private static let responsibleFn: ResponsibleFn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    static func responsiblePid(_ pid: Int32) -> Int32? {
        guard let r = responsibleFn?(pid), r > 0, r != pid else { return nil }
        return r
    }

    /// 1 normal, 2 warning, 4 critical.
    static func memPressure() -> Int32 { value("kern.memorystatus_vm_pressure_level", Int32(1)) }

    static func swapUsed() -> Double { Double(value("vm.swapusage", xsw_usage()).xsu_used) }

    /// Cumulative bytes read/written and operations of the internal SSD (`disk0`).
    static func disk() -> (read: UInt64, write: UInt64, ops: UInt64)? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var fallback: (UInt64, UInt64, UInt64)?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            func n(_ k: String) -> UInt64 { (st[k] as? NSNumber)?.uint64Value ?? 0 }
            let v = (n("Bytes (Read)"), n("Bytes (Write)"), n("Operations (Read)") + n("Operations (Write)"))
            let bsd = IORegistryEntrySearchCFProperty(s, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault,
                                                      IOOptionBits(kIORegistryIterateRecursively)) as? String
            if bsd == "disk0" { return v }
            if fallback == nil { fallback = v }
        }
        return fallback
    }

    /// GPU utilisation and cumulative GPU nanoseconds per pid (from the AGX user clients).
    static func gpu() -> (util: Double?, nsByPid: [Int32: UInt64]) {
        var util: Double?
        var byPid: [Int32: UInt64] = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return (nil, [:]) }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            if let ps = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                util = (ps["Device Utilization %"] as? NSNumber)?.doubleValue ?? util
            }
            var cit: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(s, kIOServicePlane, &cit) == KERN_SUCCESS else { continue }
            while case let c = IOIteratorNext(cit), c != 0 {
                defer { IOObjectRelease(c) }
                // "pid 654, WindowServer"
                guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }),
                      let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                byPid[pid, default: 0] += usage.reduce(0) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
            }
            IOObjectRelease(cit)
        }
        return (util, byPid)
    }
}

// MARK: - SSD health (NVMe SMART through the NVMeSMARTLib IOKit plug-in, no root needed)

enum SSDHealth {
    private static func uuid(_ b: [UInt8]) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
    private static let userClientType = uuid([0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F])
    private static let smartInterface = uuid([0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6])
    private static let plugInInterface = uuid([0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F])

    // IONVMeSMARTInterface: IUnknown (4 pointers), version + revision (padded to 8 bytes), then SMARTReadData.
    private typealias ReadFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> IOReturn
    private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> UInt32

    /// SMART log of the first NVMe disk (the internal SSD).
    static func read() -> SMART? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, userClientType, plugInInterface, &plugin, &score) == KERN_SUCCESS,
              let plugin, let vt = plugin.pointee?.pointee else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        var iface: LPVOID?
        guard vt.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &iface) == 0, let iface else { return nil }
        let table = iface.load(as: UnsafeRawPointer.self)
        defer { _ = unsafeBitCast(table.load(fromByteOffset: 24, as: UnsafeRawPointer.self), to: ReleaseFn.self)(iface) }
        var log = [UInt8](repeating: 0, count: 512)
        let read = unsafeBitCast(table.load(fromByteOffset: 40, as: UnsafeRawPointer.self), to: ReadFn.self)
        let r = log.withUnsafeMutableBytes { read(iface, $0.baseAddress!) }
        return r == KERN_SUCCESS ? SMART(log: log) : nil
    }
}

// MARK: - Thermal pressure (libnotify)

@_silgen_name("notify_register_check") private func notify_register_check(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> UInt32
@_silgen_name("notify_get_state") private func notify_get_state(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32

enum Thermal {
    private static let token: Int32 = {
        var t: Int32 = 0
        _ = notify_register_check("com.apple.system.thermalpressurelevel", &t)
        return t
    }()

    /// 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping. From 1 on, macOS takes clock away.
    static func level() -> Int {
        var s: UInt64 = 0
        _ = notify_get_state(token, &s)
        return Int(s)
    }

    static let names = ["keine Drosselung", "leicht gedrosselt", "stark gedrosselt", "kritisch gedrosselt", "kritisch gedrosselt"]
}

// MARK: - Temperatures (private IOHIDEventSystemClient)

struct Temps {
    var soc: Double?
    var gpu: Double?
    var ssd: Double?
    var dev: [Double?] = Array(repeating: nil, count: 8)
    var cells: [Double] = []
    var battery: Double? { cells.max() }
}

/// Reads the SoC sensors through private IOKit HID calls. They need no root; if Apple removes them
/// the reader returns empty values and the rest of the app keeps working.
final class TemperatureReader {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private var client: AnyObject?
    private var copyServices: CopyServicesFn?
    private var copyProperty: CopyPropertyFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let create: CreateFn = sym("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatchingFn = sym("IOHIDEventSystemClientSetMatching") else { return }
        copyServices = sym("IOHIDEventSystemClientCopyServices")
        copyProperty = sym("IOHIDServiceClientCopyProperty")
        copyEvent = sym("IOHIDServiceClientCopyEvent")
        getFloat = sym("IOHIDEventGetFloatValue")
        client = create(kCFAllocatorDefault)?.takeRetainedValue()
        if let client { _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary) }
    }

    func read() -> Temps {
        var t = Temps()
        guard let client, let copyServices, let copyProperty, let copyEvent, let getFloat,
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return t }
        let temperatureEvent: Int64 = 15
        for s in services {
            guard let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let e = copyEvent(s, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(e, Int32(temperatureEvent << 16))
            guard v > 0, v < 150 else { continue }
            if name.hasPrefix("PMU tdie") {
                t.soc = max(t.soc ?? v, v)
            } else if name.hasPrefix("PMU TP"), name.hasSuffix("g") {
                t.gpu = max(t.gpu ?? v, v)
            } else if name.hasPrefix("PMU tdev"), let i = Int(name.dropFirst(8)), (1...8).contains(i) {
                t.dev[i - 1] = max(t.dev[i - 1] ?? v, v)
            } else if name.hasPrefix("NAND") {
                t.ssd = max(t.ssd ?? v, v)
            } else if name == "gas gauge battery" {
                t.cells.append(v)
            }
        }
        return t
    }
}

// MARK: - Clock frequencies (private IOReport)

@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?
@_silgen_name("IOReportMergeChannels")
private func IOReportMergeChannels(_ a: CFMutableDictionary, _ b: CFMutableDictionary, _ x: CFTypeRef?)
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeMutableRawPointer?, _ desired: CFMutableDictionary,
                                        _ subbed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ id: UInt64, _ x: CFTypeRef?) -> OpaquePointer?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ sub: OpaquePointer, _ subbed: CFMutableDictionary, _ x: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ x: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetCount")
private func IOReportStateGetCount(_ ch: CFDictionary) -> Int32
@_silgen_name("IOReportStateGetNameForIndex")
private func IOReportStateGetNameForIndex(_ ch: CFDictionary, _ i: Int32) -> Unmanaged<CFString>?
@_silgen_name("IOReportStateGetResidency")
private func IOReportStateGetResidency(_ ch: CFDictionary, _ i: Int32) -> Int64

/// Average clock while active, from IOReport performance-state residencies between two calls.
final class FrequencyReader {
    // ponytail: pmgr keys as on M1-family chips; other chips show "–" until their keys are added.
    private let eTable = FrequencyReader.table("voltage-states1-sram")
    private let pTable = FrequencyReader.table("voltage-states5-sram")
    private let gTable = Array(FrequencyReader.table("voltage-states9").drop { $0 == 0 })
    private var sub: OpaquePointer?
    private var subbed: CFMutableDictionary?
    private var last: CFDictionary?

    init() {
        guard let cpu = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let gpu = IOReportCopyChannelsInGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() else { return }
        IOReportMergeChannels(cpu, gpu, nil)
        var s: Unmanaged<CFMutableDictionary>?
        sub = IOReportCreateSubscription(nil, cpu, &s, 0, nil)
        subbed = s?.takeRetainedValue()
    }

    /// MHz of the efficiency cores, performance cores and GPU since the previous call.
    func read() -> (e: Double?, p: Double?, gpu: Double?) {
        guard let sub, let subbed, let now = IOReportCreateSamples(sub, subbed, nil)?.takeRetainedValue() else { return (nil, nil, nil) }
        defer { last = now }
        guard let last, let delta = IOReportCreateSamplesDelta(last, now, nil)?.takeRetainedValue() as? [String: Any],
              let channels = delta["IOReportChannels"] as? [NSDictionary] else { return (nil, nil, nil) }
        var acc: [String: (active: Int64, weighted: Double)] = [:]
        for ch in channels {
            let c = ch as CFDictionary
            guard let name = IOReportChannelGetChannelName(c)?.takeUnretainedValue() as String? else { continue }
            let key: String, table: [Double]
            switch name {
            case "ECPU": (key, table) = ("e", eTable)
            case "PCPU", "PCPU1": (key, table) = ("p", pTable)
            case "GPUPH": (key, table) = ("g", gTable)
            default: continue
            }
            let states = (0..<IOReportStateGetCount(c)).map {
                (name: IOReportStateGetNameForIndex(c, $0)?.takeUnretainedValue() as String? ?? "", residency: IOReportStateGetResidency(c, $0))
            }
            let r = Freq.accumulate(states, table: table)
            acc[key, default: (0, 0)].active += r.active
            acc[key, default: (0, 0)].weighted += r.weighted
        }
        func mhz(_ k: String) -> Double? { acc[k].flatMap { $0.active > 0 ? $0.weighted / Double($0.active) : nil } }
        return (mhz("e"), mhz("p"), mhz("g"))
    }

    var maxMHz: (e: Double?, p: Double?, gpu: Double?) { (eTable.last, pTable.last, gTable.last) }

    /// Frequency table from the `pmgr` device: pairs of (frequency, voltage) as UInt32.
    private static func table(_ key: String) -> [Double] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(s, &name)
            guard String(cString: name) == "pmgr",
                  let d = IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { continue }
            let raw = stride(from: 0, to: d.count - 7, by: 8).map { i in
                Double(d[i..<i + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            }
            let divisor = (raw.max() ?? 0) > 100_000_000 ? 1e6 : 1e3 // Hz on M1–M3, kHz on later chips
            return raw.map { $0 / divisor }
        }
        return []
    }
}
