import Darwin

enum ProcessMemoryUsageReader {
    /// Reads physical footprint including compressed memory, or nil if task_info fails.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { buffer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), buffer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Physical footprint includes compressed memory and excludes shared clean pages.
        return info.phys_footprint
    }
}
