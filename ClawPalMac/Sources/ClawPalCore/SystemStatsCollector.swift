import Darwin
import Foundation

/// Native macOS system metrics collector using Mach + BSD APIs (no subprocesses).
public final class SystemStatsCollector {
    private var prevUser: UInt64 = 0
    private var prevSystem: UInt64 = 0
    private var prevIdle: UInt64 = 0
    private var prevNice: UInt64 = 0
    private var hasCpuBaseline = false

    private var prevRxBytes: UInt64 = 0
    private var prevTxBytes: UInt64 = 0
    private var prevNetAt: CFAbsoluteTime = 0

    public let hostname: String
    public let cpuName: String
    public let gpuName: String
    private let totalMemoryBytes: UInt64

    public init() {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let shortHost = host.split(separator: ".").first.map(String.init) ?? "Mac"
        self.hostname = clawpalDisplayText(shortHost, maxBufferBytes: 64)
        let brand = Self.sysctlString("machdep.cpu.brand_string") ?? "Mac"
        self.cpuName = clawpalDisplayText(brand, maxBufferBytes: 96)
        self.gpuName = brand.hasPrefix("Apple") ? clawpalDisplayText(brand + " GPU", maxBufferBytes: 96) : ""
        self.totalMemoryBytes = ProcessInfo.processInfo.physicalMemory

        _ = sampleCpuUsage()
        let (rx, tx) = Self.readNetworkBytes()
        self.prevRxBytes = rx
        self.prevTxBytes = tx
        self.prevNetAt = CFAbsoluteTimeGetCurrent()
    }

    public func sample() -> (hostname: String, uptimeS: Int, cpu: CpuStats, gpu: GpuStats, memory: MemoryStats, network: NetworkStats) {
        let cpuPct = sampleCpuUsage()
        let mem = sampleMemory()
        let disk = sampleDisk()
        let net = sampleNetwork()
        let uptime = Int(max(ProcessInfo.processInfo.systemUptime, 0))
        return (
            hostname: hostname,
            uptimeS: uptime,
            cpu: CpuStats(usage: cpuPct, temperature: nil, name: cpuName),
            // On macOS we repurpose the GPU slot for root volume Disk Space (usage %, used/total MB, volume name).
            gpu: disk,
            memory: mem,
            network: net
        )
    }

    private func sampleDisk() -> GpuStats {
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeNameKey]
        guard let vals = try? root.resourceValues(forKeys: keys),
              let total = vals.volumeTotalCapacity, total > 0 else {
            return GpuStats(usage: nil, temperature: nil, vramUsedMb: nil, vramTotalMb: nil, name: "Macintosh HD")
        }
        let avail = vals.volumeAvailableCapacityForImportantUsage ?? Int64(vals.volumeAvailableCapacity ?? 0)
        let totalD = Double(total)
        let usedD = max(totalD - Double(avail), 0)
        let totalMb = (totalD / 1_048_576.0).rounded()
        let usedMb = (usedD / 1_048_576.0).rounded()
        let pct = (min(max(usedD / totalD * 100.0, 0), 100) * 10).rounded() / 10
        let name = clawpalDisplayText(vals.volumeName ?? "Macintosh HD", maxBufferBytes: 96)
        return GpuStats(usage: pct, temperature: nil, vramUsedMb: usedMb, vramTotalMb: totalMb, name: name)
    }

    private func sampleCpuUsage() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }

        defer {
            prevUser = user; prevSystem = system; prevIdle = idle; prevNice = nice
            hasCpuBaseline = true
        }
        guard hasCpuBaseline, user >= prevUser, system >= prevSystem, idle >= prevIdle, nice >= prevNice else {
            return 0
        }
        let dUser = Double(user - prevUser)
        let dSys = Double(system - prevSystem)
        let dIdle = Double(idle - prevIdle)
        let dNice = Double(nice - prevNice)
        let total = dUser + dSys + dIdle + dNice
        guard total > 0 else { return 0 }
        let busy = ((dUser + dSys + dNice) / total) * 100.0
        return (min(max(busy, 0), 100) * 10).rounded() / 10
    }

    private func sampleMemory() -> MemoryStats {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let totalMb = Int((Double(totalMemoryBytes) / 1_048_576.0).rounded())
        guard kr == KERN_SUCCESS, totalMemoryBytes > 0 else {
            return MemoryStats(usedMb: 0, totalMb: totalMb, usage: 0)
        }
        // Match Activity Monitor / psutil: active + wired + compressed (excluding purgeable/inactive file cache).
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let usedBytes = min(usedPages * UInt64(pageSize), totalMemoryBytes)
        let usedMb = Int((Double(usedBytes) / 1_048_576.0).rounded())
        let pct = min(max(Double(usedBytes) / Double(totalMemoryBytes) * 100.0, 0), 100)
        return MemoryStats(usedMb: usedMb, totalMb: totalMb, usage: (pct * 10).rounded() / 10)
    }

    private func sampleNetwork() -> NetworkStats {
        let now = CFAbsoluteTimeGetCurrent()
        let (rx, tx) = Self.readNetworkBytes()
        let elapsed = max(now - prevNetAt, 0.001)
        let rxBps = rx >= prevRxBytes ? Int64((Double(rx - prevRxBytes) * 8.0 / elapsed).rounded()) : 0
        let txBps = tx >= prevTxBytes ? Int64((Double(tx - prevTxBytes) * 8.0 / elapsed).rounded()) : 0
        prevRxBytes = rx
        prevTxBytes = tx
        prevNetAt = now
        return NetworkStats(rxBps: max(rxBps, 0), txBps: max(txBps, 0))
    }

    private static func readNetworkBytes() -> (UInt64, UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(first) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               (flags & IFF_LOOPBACK) == 0, (flags & IFF_UP) != 0,
               let dataPtr = cur.pointee.ifa_data {
                let ifData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(ifData.ifi_ibytes)
                tx += UInt64(ifData.ifi_obytes)
            }
            ptr = cur.pointee.ifa_next
        }
        return (rx, tx)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
