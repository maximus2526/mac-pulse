import AppKit
import SwiftUI

enum MetricID: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, cpuTemp, gpuTemp, power, fans, network, disk, battery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .cpuTemp: "CPU temp"
        case .gpuTemp: "GPU temp"
        case .power: "Power"
        case .fans: "Fans"
        case .network: "Network"
        case .disk: "Disk"
        case .battery: "Battery"
        }
    }

    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up.fill"
        case .memory: "memorychip"
        case .cpuTemp: "thermometer.medium"
        case .gpuTemp: "thermometer.high"
        case .power: "bolt.fill"
        case .fans: "fan.fill"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive.fill"
        case .battery: "battery.75percent"
        }
    }

    var color: Color {
        switch self {
        case .cpu: Color(red: 0.36, green: 0.62, blue: 1.00)
        case .gpu: Color(red: 0.69, green: 0.45, blue: 1.00)
        case .memory: Color(red: 0.20, green: 0.84, blue: 0.78)
        case .cpuTemp: Color(red: 1.00, green: 0.58, blue: 0.25)
        case .gpuTemp: Color(red: 1.00, green: 0.38, blue: 0.45)
        case .power: Color(red: 1.00, green: 0.82, blue: 0.25)
        case .fans: Color(red: 0.35, green: 0.85, blue: 1.00)
        case .network: Color(red: 0.30, green: 0.88, blue: 0.48)
        case .disk: Color(red: 0.55, green: 0.58, blue: 1.00)
        case .battery: Color(red: 0.55, green: 0.92, blue: 0.35)
        }
    }

    /// Second series color (upload, write, fan 2).
    var color2: Color {
        switch self {
        case .network: Color(red: 1.00, green: 0.45, blue: 0.75)
        case .disk: Color(red: 1.00, green: 0.62, blue: 0.35)
        case .fans: Color(red: 0.62, green: 0.70, blue: 1.00)
        default: color
        }
    }

    var isPercent: Bool { [.cpu, .gpu, .memory, .battery].contains(self) }
    var isTemperature: Bool { [.cpuTemp, .gpuTemp].contains(self) }
}

struct Series {
    var a: [Double] = []
    var b: [Double]? = nil
}

@MainActor
final class Monitor: ObservableObject {
    static let historyLength = 120 // seconds
    static let shared = Monitor()

    @Published var series: [MetricID: Series] = [:]
    @Published var selected: MetricID = .cpu
    @Published var menuImage = NSImage(size: NSSize(width: 60, height: 18))

    @Published private(set) var cpu = CPUReading()
    @Published private(set) var gpu = GPUReading()
    @Published private(set) var memory = MemoryReading()
    @Published private(set) var net = NetReading()
    @Published private(set) var disk = DiskReading()
    @Published private(set) var battery = BatteryReading()
    @Published private(set) var cpuTemps: [Double] = []
    @Published private(set) var gpuTemps: [Double] = []
    @Published private(set) var fans: [(rpm: Double, min: Double, max: Double)] = []
    @Published private(set) var systemPower = 0.0
    @Published private(set) var adapterPower = 0.0
    @Published private(set) var batteryPower = 0.0
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState

    let chipName: String
    let perfCores: Int
    let effCores: Int

    private let smc = SMC()
    private let cpuSampler = CPUSampler()
    private let netSampler = NetSampler()
    private let diskSampler = DiskSampler()
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var fanCount = 0
    private var timer: Timer?

    var metrics: [MetricID] { MetricID.allCases.filter { $0 != .battery || battery.present } }

    init() {
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? "Mac"
        perfCores = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        effCores = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        discoverSensors()
        _ = cpuSampler.sample()
        _ = netSampler.sample()
        _ = diskSampler.sample()
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func discoverSensors() {
        guard let smc else { return }
        let keys = smc.allKeys()
        func valid(_ k: String) -> Bool { (smc.read(k)).map { $0 > 5 && $0 < 130 } ?? false }
        cpuKeys = keys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }.filter(valid)
        gpuKeys = keys.filter { $0.hasPrefix("Tg") }.filter(valid)
        if cpuKeys.isEmpty { cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"].filter(valid) }
        if gpuKeys.isEmpty { gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"].filter(valid) }
        fanCount = Int(smc.read("FNum") ?? 0)
    }

    private func push(_ id: MetricID, _ a: Double, _ b: Double? = nil) {
        var s = series[id] ?? Series()
        s.a.append(a)
        if s.a.count > Self.historyLength { s.a.removeFirst(s.a.count - Self.historyLength) }
        if let b {
            var bb = s.b ?? []
            bb.append(b)
            if bb.count > Self.historyLength { bb.removeFirst(bb.count - Self.historyLength) }
            s.b = bb
        }
        series[id] = s
    }

    func tick() {
        cpu = cpuSampler.sample()
        gpu = GPUSampler.sample()
        memory = MemorySampler.sample()
        net = netSampler.sample()
        disk = diskSampler.sample()
        battery = BatterySampler.sample()
        thermal = ProcessInfo.processInfo.thermalState

        if let smc {
            cpuTemps = cpuKeys.compactMap { smc.read($0) }.filter { $0 > 5 && $0 < 130 }
            gpuTemps = gpuKeys.compactMap { smc.read($0) }.filter { $0 > 5 && $0 < 130 }
            fans = (0..<fanCount).map { i in
                (smc.read("F\(i)Ac") ?? 0, smc.read("F\(i)Mn") ?? 0, smc.read("F\(i)Mx") ?? 0)
            }
            systemPower = smc.read("PSTR") ?? 0
            adapterPower = smc.read("PDTR") ?? 0
            batteryPower = smc.read("PPBR") ?? 0
        }

        push(.cpu, cpu.total)
        push(.gpu, gpu.device)
        push(.memory, memory.total > 0 ? memory.used / memory.total * 100 : 0)
        push(.cpuTemp, cpuTempValue)
        push(.gpuTemp, gpuTempValue)
        push(.power, systemPower)
        push(.fans, fans.first?.rpm ?? 0, fans.count > 1 ? fans[1].rpm : nil)
        push(.network, net.down, net.up)
        push(.disk, disk.read, disk.write)
        if battery.present { push(.battery, battery.percent) }

        renderMenuImage()
    }

    var cpuTempValue: Double { cpuTemps.isEmpty ? 0 : cpuTemps.reduce(0, +) / Double(cpuTemps.count) }
    var gpuTempValue: Double { gpuTemps.isEmpty ? 0 : gpuTemps.reduce(0, +) / Double(gpuTemps.count) }

    // MARK: Formatting

    func valueText(_ id: MetricID) -> String {
        switch id {
        case .cpu: Fmt.pct(cpu.total)
        case .gpu: Fmt.pct(gpu.device)
        case .memory: Fmt.pct(memory.total > 0 ? memory.used / memory.total * 100 : 0)
        case .cpuTemp: Fmt.temp(cpuTempValue)
        case .gpuTemp: Fmt.temp(gpuTempValue)
        case .power: Fmt.watts(systemPower)
        case .fans: fans.isEmpty ? "—" : Fmt.rpm(fans.map(\.rpm).max() ?? 0)
        case .network: "↓" + Fmt.rate(net.down)
        case .disk: "R " + Fmt.rate(disk.read)
        case .battery: Fmt.pct(battery.percent)
        }
    }

    func secondaryText(_ id: MetricID) -> String? {
        switch id {
        case .network: "↑" + Fmt.rate(net.up)
        case .disk: "W " + Fmt.rate(disk.write)
        case .memory: Fmt.bytes(memory.used) + " / " + Fmt.bytes(memory.total)
        case .battery: battery.charging ? "Charging" : (battery.plugged ? "Plugged in" : "On battery")
        default: nil
        }
    }

    func formatAxis(_ id: MetricID, _ v: Double) -> String {
        switch id {
        case .cpu, .gpu, .memory, .battery: Fmt.pct(v)
        case .cpuTemp, .gpuTemp: Fmt.temp(v)
        case .power: Fmt.watts(v)
        case .fans: Fmt.rpm(v)
        case .network, .disk: Fmt.rate(v)
        }
    }

    // MARK: Menu bar image

    private func renderMenuImage() {
        let bars = Array((series[.cpu]?.a ?? []).suffix(14))
        let view = MenuBarGlyph(bars: bars, top: Fmt.pct(cpu.total), bottom: cpuTemps.isEmpty ? Fmt.pct(gpu.device) : Fmt.temp(cpuTempValue))
        let r = ImageRenderer(content: view)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let img = r.nsImage {
            img.isTemplate = true
            menuImage = img
        }
    }

    // MARK: sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }
}

enum Fmt {
    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    static func temp(_ v: Double) -> String { v > 0 ? "\(Int(v.rounded()))°" : "—" }
    static func watts(_ v: Double) -> String { v >= 10 ? String(format: "%.0f W", v) : String(format: "%.1f W", v) }
    static func rpm(_ v: Double) -> String { v < 1 ? "Off" : "\(Int(v.rounded()))" }

    static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = v, i = 0
        while x >= 1000, i < units.count - 1 { x /= 1024; i += 1 }
        return x >= 100 || i == 0 ? String(format: "%.0f %@", x, units[i]) : String(format: "%.1f %@", x, units[i])
    }

    static func rate(_ v: Double) -> String { bytes(v) + "/s" }

    static func uptime() -> String {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
    }
}
