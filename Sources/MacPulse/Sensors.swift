import Darwin
import Foundation
import IOKit

// MARK: - SMC (fans, power, temperatures)

final class SMC {
    private struct KeyData {
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var pLimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var pad = (UInt8(0), UInt8(0), UInt8(0)) // C struct padding
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }

    private func call(_ input: inout KeyData) -> Bool {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        input = output
        return r == KERN_SUCCESS && output.result == 0
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let c = infoCache[key] { return c }
        var d = KeyData(); d.key = key; d.data8 = 9
        guard call(&d) else { return nil }
        infoCache[key] = (d.dataSize, d.dataType)
        return (d.dataSize, d.dataType)
    }

    func read(_ name: String) -> Double? {
        let key = Self.code(name)
        guard let i = info(key) else { return nil }
        var d = KeyData(); d.key = key; d.dataSize = i.size; d.data8 = 5
        guard call(&d) else { return nil }
        let b = withUnsafeBytes(of: d.bytes) { Array($0.prefix(Int(i.size))) }
        switch Self.string(i.type) {
        case "flt " where b.count >= 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "fpe2" where b.count >= 2: return Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
        case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "ui8 " where b.count >= 1: return Double(b[0])
        case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4: return Double(b.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default: return nil
        }
    }

    /// All SMC key names (used once at start to discover temperature sensors).
    func allKeys() -> [String] {
        guard let count = read("#KEY"), count > 0 else { return [] }
        var keys: [String] = []
        for i in 0..<Int(count) {
            var d = KeyData(); d.data8 = 8; d.data32 = UInt32(i)
            if call(&d) { keys.append(Self.string(d.key)) }
        }
        return keys
    }
}

// MARK: - CPU

struct CPUReading { var total = 0.0, user = 0.0, system = 0.0, cores: [Double] = [] }

final class CPUSampler {
    private var previous: [[UInt32]] = []

    func sample() -> CPUReading {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUReading() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var now: [[UInt32]] = []
        for c in 0..<Int(count) {
            let base = c * Int(CPU_STATE_MAX)
            now.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previous = now }
        guard previous.count == now.count else { return CPUReading(cores: Array(repeating: 0, count: now.count)) }

        var r = CPUReading()
        var tUser = 0.0, tSys = 0.0, tAll = 0.0
        for (a, b) in zip(now, previous) {
            let user = Double(a[Int(CPU_STATE_USER)] &- b[Int(CPU_STATE_USER)]) + Double(a[Int(CPU_STATE_NICE)] &- b[Int(CPU_STATE_NICE)])
            let sys = Double(a[Int(CPU_STATE_SYSTEM)] &- b[Int(CPU_STATE_SYSTEM)])
            let idle = Double(a[Int(CPU_STATE_IDLE)] &- b[Int(CPU_STATE_IDLE)])
            let all = user + sys + idle
            r.cores.append(all > 0 ? (user + sys) / all * 100 : 0)
            tUser += user; tSys += sys; tAll += all
        }
        if tAll > 0 { r.user = tUser / tAll * 100; r.system = tSys / tAll * 100; r.total = r.user + r.system }
        return r
    }
}

// MARK: - Memory

struct MemoryReading { var used = 0.0, total = 0.0, wired = 0.0, compressed = 0.0, swap = 0.0, app = 0.0 }

enum MemorySampler {
    static func sample() -> MemoryReading {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var r = MemoryReading(total: Double(ProcessInfo.processInfo.physicalMemory))
        guard ok == KERN_SUCCESS else { return r }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let p = Double(pageSize)
        r.app = Double(Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * p
        r.wired = Double(stats.wire_count) * p
        r.compressed = Double(stats.compressor_page_count) * p
        r.used = r.app + r.wired + r.compressed

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { r.swap = Double(swap.xsu_used) }
        return r
    }
}

// MARK: - GPU

struct GPUReading { var device = 0.0, renderer = 0.0, tiler = 0.0, memory = 0.0 }

enum GPUSampler {
    static func sample() -> GPUReading {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return GPUReading() }
        defer { IOObjectRelease(it) }
        var r = GPUReading()
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let ps = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            r.device = max(r.device, (ps["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            r.renderer = max(r.renderer, (ps["Renderer Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            r.tiler = max(r.tiler, (ps["Tiler Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            r.memory = max(r.memory, (ps["In use system memory"] as? NSNumber)?.doubleValue ?? 0)
        }
        return r
    }
}

// MARK: - Network

struct NetReading { var down = 0.0, up = 0.0, totalDown = 0.0, totalUp = 0.0, interface = "" }

final class NetSampler {
    private var last: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var totalRx = 0.0, totalTx = 0.0

    func sample() -> NetReading {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var busiest = ("", UInt64(0))
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return NetReading() }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes); tx += UInt64(d.ifi_obytes)
            if UInt64(d.ifi_ibytes) > busiest.1 { busiest = (name, UInt64(d.ifi_ibytes)) }
        }
        let now = Date().timeIntervalSince1970
        defer { last = (rx, tx, now) }
        var r = NetReading(interface: busiest.0)
        if let last, now > last.time {
            let dt = now - last.time
            // 32-bit counters can wrap; ignore negative deltas.
            let dRx = rx >= last.rx ? Double(rx - last.rx) : 0
            let dTx = tx >= last.tx ? Double(tx - last.tx) : 0
            totalRx += dRx; totalTx += dTx
            r.down = dRx / dt; r.up = dTx / dt
        }
        r.totalDown = totalRx; r.totalUp = totalTx
        return r
    }
}

// MARK: - Disk

struct DiskReading { var read = 0.0, write = 0.0, free = 0.0, total = 0.0 }

final class DiskSampler {
    private var last: (r: Double, w: Double, time: TimeInterval)?

    func sample() -> DiskReading {
        var rd = 0.0, wr = 0.0
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS {
            while case let svc = IOIteratorNext(it), svc != 0 {
                defer { IOObjectRelease(svc) }
                guard let s = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
                rd += (s["Bytes (Read)"] as? NSNumber)?.doubleValue ?? 0
                wr += (s["Bytes (Write)"] as? NSNumber)?.doubleValue ?? 0
            }
            IOObjectRelease(it)
        }
        let now = Date().timeIntervalSince1970
        defer { last = (rd, wr, now) }
        var r = DiskReading()
        if let last, now > last.time {
            r.read = max(0, rd - last.r) / (now - last.time)
            r.write = max(0, wr - last.w) / (now - last.time)
        }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            r.free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            r.total = Double(v.volumeTotalCapacity ?? 0)
        }
        return r
    }
}

// MARK: - Battery

struct BatteryReading {
    var present = false, percent = 0.0, charging = false, plugged = false
    var cycles = 0, health = 0.0, temperature = 0.0, minutesLeft: Int? = nil
}

enum BatterySampler {
    static func sample() -> BatteryReading {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return BatteryReading() }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return BatteryReading() }
        func n(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        var r = BatteryReading(present: true)
        r.percent = n("CurrentCapacity") ?? 0
        r.charging = (d["IsCharging"] as? Bool) ?? false
        r.plugged = (d["ExternalConnected"] as? Bool) ?? false
        r.cycles = Int(n("CycleCount") ?? 0)
        if let raw = n("AppleRawMaxCapacity"), let design = n("DesignCapacity"), design > 0 { r.health = raw / design * 100 }
        r.temperature = (n("Temperature") ?? 0) / 100
        if let t = n("TimeRemaining"), t > 0, t < 6000 { r.minutesLeft = Int(t) }
        return r
    }
}
