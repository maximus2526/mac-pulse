import Charts
import ServiceManagement
import SwiftUI

// MARK: - Menu bar glyph (rendered to a template image)

struct MenuBarGlyph: View {
    let bars: [Double]
    let top: String
    let bottom: String

    var body: some View {
        HStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<14, id: \.self) { i in
                    let v = i < 14 - bars.count ? 0 : bars[i - (14 - bars.count)]
                    RoundedRectangle(cornerRadius: 0.6)
                        .frame(width: 1.6, height: max(1.2, 15 * v / 100))
                        .opacity(0.35 + 0.65 * Double(i) / 13)
                }
            }
            .frame(height: 15, alignment: .bottom)
            VStack(alignment: .trailing, spacing: -1.5) {
                Text(top)
                Text(bottom)
            }
            .font(.system(size: 8.5, weight: .bold, design: .rounded).monospacedDigit())
            .frame(width: 24, alignment: .trailing)
        }
        .foregroundStyle(.black)
        .padding(.vertical, 1)
    }
}

// MARK: - Charts

struct AreaLine: View {
    let data: [Double]
    let color: Color
    let domain: ClosedRange<Double>
    var window = Monitor.historyLength
    var lineWidth: CGFloat = 1.6
    var fillOpacity: Double = 0.42

    var body: some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i + window - data.count),
                         yStart: .value("min", domain.lowerBound),
                         yEnd: .value("v", min(max(v, domain.lowerBound), domain.upperBound)))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(fillOpacity), color.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", i + window - data.count),
                         y: .value("v", min(max(v, domain.lowerBound), domain.upperBound)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...(window - 1))
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

extension Monitor {
    func domain(_ id: MetricID) -> ClosedRange<Double> {
        let s = series[id] ?? Series()
        let all = s.a + (s.b ?? [])
        if id.isPercent { return 0...100 }
        if id.isTemperature {
            let lo = (all.filter { $0 > 0 }.min() ?? 30) - 4
            let hi = (all.max() ?? 60) + 4
            return max(0, lo)...max(hi, lo + 12)
        }
        if id == .fans, let mx = fans.map(\.max).max(), mx > 0 { return 0...mx }
        let floor: Double = switch id {
        case .power: 10
        case .network: 64 * 1024
        case .disk: 1024 * 1024
        default: 1
        }
        return 0...max((all.max() ?? 0) * 1.15, floor)
    }
}

struct MetricChart: View {
    @EnvironmentObject var m: Monitor
    let id: MetricID
    var big = false

    var body: some View {
        let full = m.series[id] ?? Series()
        let window = big ? Monitor.historyLength : 45
        let s = Series(a: Array(full.a.suffix(window)), b: full.b.map { Array($0.suffix(window)) })
        let d = m.domain(id)
        ZStack {
            if big {
                VStack(spacing: 0) {
                    ForEach(0..<3) { i in
                        if i > 0 { Spacer() }
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                    }
                }
            }
            if let b = s.b { AreaLine(data: b, color: id.color2, domain: d, window: window, lineWidth: big ? 1.6 : 1.2, fillOpacity: 0.18) }
            AreaLine(data: s.a, color: id.color, domain: d, window: window, lineWidth: big ? 2 : 1.4)
        }
        .animation(.none, value: s.a.count)
    }
}

// MARK: - Popover

struct PopoverView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        VStack(spacing: 12) {
            header
            HeroPanel(id: m.selected)
                .id(m.selected)
                .transition(.opacity)
            VStack(spacing: 8) {
                let ids = m.metrics
                ForEach(Array(stride(from: 0, to: ids.count, by: 3)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(ids[start..<min(start + 3, ids.count)]) { MetricCard(id: $0).frame(maxWidth: .infinity) }
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [MetricID.cpu.color, MetricID.gpu.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Pulse").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("\(m.chipName) · \(Fmt.bytes(m.memory.total)) · up \(Fmt.uptime())")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            ThermalPill(state: m.thermal)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            LaunchAtLoginToggle()
            Spacer()
            FooterButton(title: "Activity Monitor", icon: "chart.bar.xaxis") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                   configuration: .init())
            }
            FooterButton(title: "Quit", icon: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

struct ThermalPill: View {
    let state: ProcessInfo.ThermalState
    var body: some View {
        let (label, color): (String, Color) = switch state {
        case .nominal: ("Cool", .green)
        case .fair: ("Warm", .yellow)
        case .serious: ("Hot", .orange)
        case .critical: ("Critical", .red)
        @unknown default: ("—", .gray)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 3)
            Text(label).font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .help("System thermal state")
    }
}

struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Open at login", isOn: $on)
            .toggleStyle(PillSwitch())
            .font(.system(size: 11))
            .onChange(of: on) { _, v in
                do { v ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                catch { on = SMAppService.mainApp.status == .enabled }
            }
    }
}

// MARK: - Cards

struct MetricCard: View {
    @EnvironmentObject var m: Monitor
    let id: MetricID
    @State private var hover = false

    var body: some View {
        let selected = m.selected == id
        Button {
            withAnimation(.snappy(duration: 0.25)) { m.selected = id }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: id.icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(id.color)
                    Text(id.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(m.valueText(id))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                MetricChart(id: id).frame(height: 24)
            }
            .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? id.color.opacity(0.13) : Color.primary.opacity(hover ? 0.08 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? id.color.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Hero panel (selected metric, big chart + details)

struct HeroPanel: View {
    @EnvironmentObject var m: Monitor
    let id: MetricID

    var body: some View {
        let s = m.series[id] ?? Series()
        let d = m.domain(id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(id.title, systemImage: id.icon)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(id.color)
                Spacer()
                if s.b != nil { legend }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.valueText(id))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                if let sec = m.secondaryText(id) {
                    Text(sec).font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(s.b != nil ? id.color2 : .secondary)
                }
                Spacer()
                StatsColumn(id: id, data: s.a).fixedSize()
            }
            ZStack(alignment: .topTrailing) {
                MetricChart(id: id, big: true).frame(height: 96)
                Text(m.formatAxis(id, d.upperBound)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            HStack {
                Text("2 min ago"); Spacer(); Text("now")
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            DetailRows(id: id)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [id.color.opacity(0.14), Color.primary.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var legend: some View {
        let names: (String, String) = switch id {
        case .network: ("Download", "Upload")
        case .disk: ("Read", "Write")
        default: ("Fan 1", "Fan 2")
        }
        return HStack(spacing: 10) {
            LegendDot(color: id.color, text: names.0)
            LegendDot(color: id.color2, text: names.1)
        }
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct StatsColumn: View {
    @EnvironmentObject var m: Monitor
    let id: MetricID
    let data: [Double]
    var body: some View {
        let valid = id.isTemperature ? data.filter { $0 > 0 } : data
        let mn = valid.min() ?? 0, mx = valid.max() ?? 0
        let avg = valid.isEmpty ? 0 : valid.reduce(0, +) / Double(valid.count)
        HStack(spacing: 12) {
            stat("MIN", mn); stat("AVG", avg); stat("MAX", mx)
        }
    }
    private func stat(_ t: String, _ v: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(t).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.tertiary)
            Text(m.formatAxis(id, v)).font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
        }
    }
}

struct DetailRows: View {
    @EnvironmentObject var m: Monitor
    let id: MetricID

    var body: some View {
        switch id {
        case .cpu:
            VStack(alignment: .leading, spacing: 8) {
                rows([("User", Fmt.pct(m.cpu.user)), ("System", Fmt.pct(m.cpu.system)), ("Idle", Fmt.pct(100 - m.cpu.total))])
                CoreBars(cores: m.cpu.cores, eff: m.effCores)
            }
        case .gpu:
            rows([("Renderer", Fmt.pct(m.gpu.renderer)), ("Tiler", Fmt.pct(m.gpu.tiler)), ("Memory", Fmt.bytes(m.gpu.memory))])
        case .memory:
            rows([("App", Fmt.bytes(m.memory.app)), ("Wired", Fmt.bytes(m.memory.wired)),
                  ("Compressed", Fmt.bytes(m.memory.compressed)), ("Swap", Fmt.bytes(m.memory.swap))])
        case .cpuTemp:
            sensorRows(m.cpuTemps)
        case .gpuTemp:
            sensorRows(m.gpuTemps)
        case .power:
            rows([("System", Fmt.watts(m.systemPower)), ("Adapter in", Fmt.watts(m.adapterPower)), ("Battery", Fmt.watts(m.batteryPower))])
        case .fans:
            if m.fans.isEmpty { rows([("Fans", "None")]) } else {
                rows(m.fans.enumerated().map { i, f in
                    ("Fan \(i + 1)", "\(Fmt.rpm(f.rpm)) rpm · \(f.max > 0 ? Fmt.pct(f.rpm / f.max * 100) : "—")")
                })
            }
        case .network:
            rows([("Upload", Fmt.rate(m.net.up)), ("Total ↓", Fmt.bytes(m.net.totalDown)),
                  ("Total ↑", Fmt.bytes(m.net.totalUp)), ("Interface", m.net.interface)])
        case .disk:
            rows([("Write", Fmt.rate(m.disk.write)), ("Free", Fmt.bytes(m.disk.free)), ("Total", Fmt.bytes(m.disk.total))])
        case .battery:
            rows([("Health", Fmt.pct(m.battery.health)), ("Cycles", "\(m.battery.cycles)"),
                  ("Temp", Fmt.temp(m.battery.temperature)),
                  ("Left", m.battery.minutesLeft.map { "\($0 / 60)h \($0 % 60)m" } ?? "—")])
        }
    }

    private func sensorRows(_ t: [Double]) -> some View {
        let avg = t.isEmpty ? 0 : t.reduce(0, +) / Double(t.count)
        return rows([("Hottest", Fmt.temp(t.max() ?? 0)), ("Average", Fmt.temp(avg)),
                     ("Coolest", Fmt.temp(t.min() ?? 0)), ("Sensors", "\(t.count)")])
    }

    private func rows(_ items: [(String, String)]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { k, v in
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.uppercased()).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(v).font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit()).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}

struct CoreBars: View {
    let cores: [Double]
    let eff: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                let isE = i < eff
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [MetricID.cpu.color, isE ? .teal : MetricID.gpu.color],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(height: max(2, 30 * v / 100))
                    }
                    .frame(height: 30)
                    Text(isE ? "E" : "P").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .animation(.easeOut(duration: 0.4), value: v)
            }
        }
    }
}

/// Drawn in SwiftUI (not AppKit), so it also shows up in rendered snapshots.
struct PillSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? MetricID.network.color : Color.primary.opacity(0.15))
                    Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
                }
                .frame(width: 26, height: 15)
                .animation(.snappy(duration: 0.2), value: configuration.isOn)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
