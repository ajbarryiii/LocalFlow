import Darwin

/// The process footprint as jetsam counts it (`task_vm_info.phys_footprint`). Content-free.
enum ProcessMemory {
    struct Footprint: Equatable, Sendable {
        var currentMB: Double
        var peakMB: Double
    }

    static func footprint() -> Footprint? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Footprint(currentMB: Double(info.phys_footprint) / 1_048_576,
                         peakMB: Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}
