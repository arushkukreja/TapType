import Foundation
import UIKit
import MetricKit
import os.signpost

@MainActor
final class DictationPerformance: NSObject, MXMetricManagerSubscriber {
    static let shared = DictationPerformance()
    private let log = OSLog(subsystem: "com.arushkukreja.TapTypeDev", category: "Dictation")
    private var started = 0.0, lastSample = 0.0, cpuStart = 0.0, peakMB = 0.0
    private var events: [String: Double] = [:]
    private var thermal: Set<Int> = []
    private var batteryStart: Float = -1
    private var active = false
    private(set) var latest: [String: Any] = [:]
    override init() { super.init(); MXMetricManager.shared.add(self) }
    func begin() {
        active = true; started = ProcessInfo.processInfo.systemUptime; lastSample = 0; events = [:]; peakMB = 0
        cpuStart = cpu(); thermal = []; UIDevice.current.isBatteryMonitoringEnabled = true
        batteryStart = UIDevice.current.batteryLevel
        os_signpost(.begin, log: log, name: "Dictation")
        sample()
    }
    func mark(_ event: String) {
        guard active, events[event] == nil else { return }
        events[event] = ProcessInfo.processInfo.systemUptime - started
        os_signpost(.event, log: log, name: "Pipeline stage", "%{public}s", event)
    }
    func sample() {
        guard active, ProcessInfo.processInfo.systemUptime - lastSample >= 1 else { return }
        lastSample = ProcessInfo.processInfo.systemUptime
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        if status == KERN_SUCCESS { peakMB = max(peakMB, Double(info.phys_footprint) / 1_048_576) }
        thermal.insert(ProcessInfo.processInfo.thermalState.rawValue)
    }
    func end(outcome: String) {
        guard active else { return }
        sample(); let elapsed = ProcessInfo.processInfo.systemUptime - started, usedCPU = max(0, cpu() - cpuStart)
        latest = ["seconds": elapsed, "cpuSeconds": usedCPU, "meanCPUPercentOfOneCore": elapsed > 0 ? usedCPU / elapsed * 100 : 0,
                  "peakAppFootprintMB": peakMB, "thermalStates": thermal.sorted(), "events": events,
                  "batteryStart": batteryStart, "batteryEnd": UIDevice.current.batteryLevel, "outcome": outcome,
                  "energyNote": "Battery is coarse and includes system activity; not a joule measurement. Speech/model services may run outside this process."]
        if let stop = events["stop"], let done = events["cleanText"] { latest["stopToCleanSeconds"] = max(0, done - stop) }
        save(latest, name: "latest.json")
        active = false
        os_signpost(.end, log: log, name: "Dictation")
    }
    private func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    private func save(_ value: [String: Any], name: String) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Performance")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // MetricKit aggregates OS CPU/GPU/memory metrics asynchronously, often the next day.
        for payload in payloads {
            let data = payload.jsonRepresentation()
            Task { @MainActor in
                if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.save(value, name: "metrickit.json") }
            }
        }
    }
}
