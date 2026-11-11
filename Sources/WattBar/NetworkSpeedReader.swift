import Foundation
import Darwin

struct InterfaceCounters {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct NetworkAccumulator {
    private var previous: (interfaces: [UInt32: InterfaceCounters], time: TimeInterval)?
    private var downloaded: UInt64 = 0
    private var uploaded: UInt64 = 0

    mutating func sample(_ interfaces: [UInt32: InterfaceCounters]?, at time: TimeInterval) -> NetworkSpeedReading? {
        guard let interfaces else {
            previous = nil
            return nil
        }
        defer { previous = (interfaces, time) }

        var receivedDelta: UInt64 = 0
        var sentDelta: UInt64 = 0
        let elapsed = previous.map { time - $0.time } ?? 0
        if let previous, elapsed > 0 {
            for (index, current) in interfaces {
                // Newly connected interfaces start a baseline; their lifetime
                // counters must never be counted as traffic in this session.
                guard let old = previous.interfaces[index] else { continue }
                if current.receivedBytes >= old.receivedBytes {
                    receivedDelta += current.receivedBytes - old.receivedBytes
                }
                if current.sentBytes >= old.sentBytes {
                    sentDelta += current.sentBytes - old.sentBytes
                }
            }
        }
        downloaded += receivedDelta
        uploaded += sentDelta
        return NetworkSpeedReading(
            downloadBytesPerSecond: elapsed > 0 ? Double(receivedDelta) / elapsed : 0,
            uploadBytesPerSecond: elapsed > 0 ? Double(sentDelta) / elapsed : 0,
            totalDownloadedBytes: downloaded,
            totalUploadedBytes: uploaded
        )
    }
}

final class NetworkSpeedReader {
    private var accumulator = NetworkAccumulator()

    func read() -> NetworkSpeedReading? {
        accumulator.sample(Self.interfaceByteCounters(), at: ProcessInfo.processInfo.systemUptime)
    }

    static func interfaceByteCounters() -> [UInt32: InterfaceCounters]? {
        // NET_RT_IFLIST2 exposes if_data64. getifaddrs' if_data truncates byte
        // counters to 32 bits, losing traffic at each 4 GiB rollover.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            guard size > 0 else { return [:] }
            var data = Data(count: size)
            let result = data.withUnsafeMutableBytes { bytes in
                sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0)
            }
            if result == 0 {
                data.count = size
                return decodeInterfaceCounters(data)
            }
            // An interface can appear between the sizing and data calls.
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    static func decodeInterfaceCounters(_ data: Data) -> [UInt32: InterfaceCounters]? {
        data.withUnsafeBytes { bytes in
            var counters: [UInt32: InterfaceCounters] = [:]
            var offset = 0
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { return nil }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= bytes.count - offset else { return nil }
                let type = bytes[offset + 3]
                if type == RTM_IFINFO2 {
                    guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if isPhysicalLink(header) {
                        counters[UInt32(header.ifm_index)] = InterfaceCounters(
                            receivedBytes: header.ifm_data.ifi_ibytes,
                            sentBytes: header.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += length
            }
            return counters
        }
    }

    /// Counts each byte once. Tunnels (utun VPNs, gif, stf, ipsec) re-carry
    /// traffic already seen on a physical link, and a bridge repeats its
    /// members' traffic, so only Ethernet-type links (Ethernet, Wi-Fi, AWDL,
    /// Thunderbolt) and cellular links are summed.
    private static func isPhysicalLink(_ header: if_msghdr2) -> Bool {
        let flags = header.ifm_flags
        guard flags & IFF_UP != 0,
              flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { return false }
        let type = Int32(header.ifm_data.ifi_type)
        return type == IFT_ETHER || type == IFT_CELLULAR
    }
}
