import Foundation

enum IncreasedMemoryStatus: String {
    case enabled = "Activado en la firma"
    case disabled = "Desactivado en la firma"
    case unknown = "Firma no verificable"

    static let current: Self = {
        #if targetEnvironment(simulator)
        return .unknown
        #else
        guard let executable = Bundle.main.executableURL,
              let binary = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return .unknown }
        return read(binary)
        #endif
    }()

    static func read(_ binary: Data) -> Self {
        func word(_ offset: Int, bigEndian: Bool = false) -> Int? {
            guard offset >= 0, offset <= binary.count - 4 else { return nil }
            return (0..<4).reduce(0) { value, index in
                value | Int(binary[binary.startIndex + offset + index]) << (8 * (bigEndian ? 3 - index : index))
            }
        }

        // Device builds contain a thin, little-endian 64-bit Mach-O.
        guard word(0) == 0xfeedfacf, let count = word(16), let commandBytes = word(20),
              commandBytes <= binary.count - 32, count <= commandBytes / 8 else { return .unknown }
        var command = 32
        let end = 32 + commandBytes
        for _ in 0..<count {
            guard command <= end - 8, let size = word(command + 4), size >= 8,
                  size <= end - command else { return .unknown }
            defer { command += size }
            guard word(command) == 0x1d else { continue } // LC_CODE_SIGNATURE
            guard size >= 16, let start = word(command + 8), let bytes = word(command + 12),
                  bytes >= 12, start <= binary.count - bytes,
                  word(start, bigEndian: true) == 0xfade0cc0,
                  let length = word(start + 4, bigEndian: true), length >= 12, length <= bytes,
                  let slots = word(start + 8, bigEndian: true), slots <= (length - 12) / 8 else {
                return .unknown
            }
            var hasDER = false
            for slot in 0..<slots {
                let index = start + 12 + slot * 8
                let type = word(index, bigEndian: true)
                if type == 7 { hasDER = true }
                guard type == 5 else { continue } // XML entitlements
                guard let offset = word(index + 4, bigEndian: true), offset <= length - 8,
                      word(start + offset, bigEndian: true) == 0xfade7171,
                      let blob = word(start + offset + 4, bigEndian: true), blob >= 8,
                      blob <= length - offset else { return .unknown }
                let payload = (start + offset + 8)..<(start + offset + blob)
                guard let plist = try? PropertyListSerialization.propertyList(from: binary.dropFirst(payload.lowerBound).prefix(payload.count), format: nil),
                      let values = plist as? [String: Any] else { return .unknown }
                return values["com.apple.developer.kernel.increased-memory-limit"] as? Bool == true ? .enabled : .disabled
            }
            return hasDER ? .unknown : .disabled
        }
        return .unknown
    }
}

#if os(iOS)
import Darwin
import Metal
import os

struct RuntimeMemorySample {
    private static let device = MTLCreateSystemDefaultDevice()
    let available = UInt64(os_proc_available_memory())
    let physical = ProcessInfo.processInfo.physicalMemory
    let metalAllocated: UInt64? = Self.device.map { UInt64($0.currentAllocatedSize) }
    let metalBudget: UInt64? = Self.device?.recommendedMaxWorkingSetSize
    let footprint: UInt64? = Self.processFootprint()

    static func gib(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(2))) + " GiB"
    }

    private static func processFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

final class KVAllocation {
    private let lock = NSLock()
    private var allocations: [String: UInt64] = [:]

    func record(_ line: String) {
        guard let marker = line.range(of: " KV buffer size ="),
              let amount = line[marker.upperBound...].split(whereSeparator: \.isWhitespace).first,
              let mib = Double(amount), mib.isFinite, mib >= 0, mib < 1_000_000 else { return }
        let device = line[..<marker.lowerBound].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "?"
        lock.withLock { allocations[device] = UInt64(mib * 1_048_576) }
    }

    var bytes: UInt64? {
        lock.withLock { allocations.isEmpty ? nil : allocations.values.reduce(0, +) }
    }
}
#endif
