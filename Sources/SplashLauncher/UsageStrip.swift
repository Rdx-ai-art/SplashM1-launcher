import SwiftUI
import Combine

/// One snapshot of hardware load for the metrics strip.
struct SystemLoad: Equatable {
    var gpu: Int
    var gpuTemperature: Double?
    var ane: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64

    var memoryPercent: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0 }
    var memoryLabel: String { "\(memoryUsed >> 30)/\(memoryTotal >> 30)G" }

    enum Level { case normal, busy, saturated }
    static func level(_ percent: Double) -> Level { percent >= 85 ? .saturated : percent >= 60 ? .busy : .normal }
    static func fraction(_ percent: Double) -> Double { min(max(percent / 100, 0), 1) }
}

/// Samples hardware metrics every 2 seconds on a utility queue.
@MainActor
final class SystemLoadSampler: ObservableObject {
    @Published private(set) var load: SystemLoad?
    private static let queue = DispatchQueue(label: "splash-launcher.system-load", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let sensors = HardwareSensors.shared
        let source = DispatchSource.makeTimerSource(queue: Self.queue)
        source.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in
            let load = SystemLoad(
                gpu: Int(SystemMetrics.gpuUtilization()),
                gpuTemperature: sensors.gpuTemperature(),
                ane: sensors.aneLoad(),
                memoryUsed: SystemMetrics.memoryUsedBytes(),
                memoryTotal: SystemMetrics.physicalMemoryBytes()
            )
            Task { @MainActor in self?.load = load }
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Views

/// The metrics strip: GPU, ANE, MEM bars + Decode/Prefill speeds.
struct UsageStrip: View {
    @ObservedObject var controller: SplashProcessController
    @StateObject private var system = SystemLoadSampler()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                gauges
                Divider().padding(.vertical, 3)
                speeds
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .onAppear { system.start() }
        .onDisappear { system.stop() }
    }

    @ViewBuilder private var gauges: some View {
        if let load = system.load {
            LoadRow(label: "GPU", percent: Double(load.gpu), value: Self.gpuValue(load))
            if let ane = load.ane {
                LoadRow(label: "ANE", percent: ane, value: "\(Int(ane))%")
            }
            LoadRow(label: "MEM", percent: load.memoryPercent, value: load.memoryLabel)
        }
    }

    static func gpuValue(_ load: SystemLoad) -> String {
        load.gpuTemperature.map { "\(load.gpu)% · \(Int($0))°" } ?? "\(load.gpu)%"
    }

    private var speeds: some View {
        HStack(spacing: 4) {
            SpeedRate(label: "Decode", value: controller.lastRequest?.decodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? nil)
            Spacer(minLength: 8)
            SpeedRate(label: "Prefill", value: controller.lastRequest?.prefillTokensPerSecond.map { String(format: "%.1f", $0) } ?? nil)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.3)))
    }
}

/// One gauge row: label, bar, trailing value.
private struct LoadRow: View {
    let label: String
    let percent: Double
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            LoadBar(fraction: SystemLoad.fraction(percent), tint: Self.tint(SystemLoad.level(percent)), height: 5)
            Text(verbatim: value)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .font(.caption)
    }

    private static func tint(_ level: SystemLoad.Level) -> Color {
        switch level {
        case .normal: return .green
        case .busy: return .yellow
        case .saturated: return .red
        }
    }
}

/// Token speed indicator.
private struct SpeedRate: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value ?? "—")
                .monospacedDigit()
                .foregroundStyle(value != nil ? .primary : .tertiary)
        }
        .font(.caption)
    }
}

/// A thin capsule bar: quiet track + colored fill.
struct LoadBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: height)
    }
}

/// Compact metrics for the sidebar: GPU, ANE, MEM bars + Decode/Prefill.
struct SidebarMetrics: View {
    let load: SystemLoad?
    let decode: Double?
    let prefill: Double?

    /// Only show speeds when the GPU is actively working (indicating live inference).
    private var isActive: Bool { (load?.gpu ?? 0) > 5 }

    var body: some View {
        if let load {
            VStack(alignment: .leading, spacing: 5) {
                Text("Live activity")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Divider()
                SidebarRow(label: "GPU", percent: Double(load.gpu), value: Self.gpuValue(load))
                if let ane = load.ane {
                    SidebarRow(label: "ANE", percent: ane, value: "\(Int(ane))%")
                }
                SidebarRow(label: "MEM", percent: load.memoryPercent, value: load.memoryLabel)
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    Text("Decode").font(.caption2).foregroundStyle(.secondary)
                    Text(isActive ? (decode.map { String(format: "%.1f", $0) } ?? "—") : "—")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(isActive && decode != nil ? .primary : .tertiary)
                    Spacer()
                    Text("Prefill").font(.caption2).foregroundStyle(.secondary)
                    Text(isActive ? (prefill.map { String(format: "%.1f", $0) } ?? "—") : "—")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(isActive && prefill != nil ? .primary : .tertiary)
                }
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 8)
        }
    }

    static func gpuValue(_ load: SystemLoad) -> String {
        load.gpuTemperature.map { "\(load.gpu)% · \(Int($0))°" } ?? "\(load.gpu)%"
    }
}

private struct SidebarRow: View {
    let label: String
    let percent: Double
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            LoadBar(fraction: SystemLoad.fraction(percent), tint: Self.tint(SystemLoad.level(percent)), height: 4)
            Text(verbatim: value)
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 62, alignment: .trailing)
        }
    }

    private static func tint(_ level: SystemLoad.Level) -> Color {
        switch level {
        case .normal: return .green
        case .busy: return .yellow
        case .saturated: return .red
        }
    }
}
