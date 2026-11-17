import Darwin
import Foundation

public struct InterfaceAddress: Codable, Hashable, Sendable {
    public var address: String
    public var netmask: String?
    public var peer: String?
    public var prefix: Int? { netmask.flatMap(IPv4.prefix(fromMask:)) }
}

/// Live state of one network interface, read with getifaddrs (no privileges needed).
public struct InterfaceSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var index: Int
    public var flags: UInt32
    public var mtu: Int
    public var mac: String?
    public var ipv4: [InterfaceAddress]
    public var ipv6: [InterfaceAddress]
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var txPackets: UInt64
    public var rxErrors: UInt64
    public var txErrors: UInt64

    public init(name: String, index: Int = 0, flags: UInt32 = 0, mtu: Int = 0, mac: String? = nil,
                ipv4: [InterfaceAddress] = [], ipv6: [InterfaceAddress] = [], rxBytes: UInt64 = 0, txBytes: UInt64 = 0,
                rxPackets: UInt64 = 0, txPackets: UInt64 = 0, rxErrors: UInt64 = 0, txErrors: UInt64 = 0) {
        self.name = name
        self.index = index
        self.flags = flags
        self.mtu = mtu
        self.mac = mac
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.txPackets = txPackets
        self.rxErrors = rxErrors
        self.txErrors = txErrors
    }

    public var id: String { name }
    public var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    public var isRunning: Bool { flags & UInt32(IFF_RUNNING) != 0 }
    public var isPointToPoint: Bool { flags & UInt32(IFF_POINTOPOINT) != 0 }
    public var isLoopback: Bool { flags & UInt32(IFF_LOOPBACK) != 0 }

    public var flagNames: [String] {
        let table: [(Int32, String)] = [
            (IFF_UP, "UP"), (IFF_BROADCAST, "BROADCAST"), (IFF_LOOPBACK, "LOOPBACK"), (IFF_POINTOPOINT, "POINTOPOINT"),
            (IFF_RUNNING, "RUNNING"), (IFF_NOARP, "NOARP"), (IFF_PROMISC, "PROMISC"), (IFF_MULTICAST, "MULTICAST"),
        ]
        return table.filter { flags & UInt32($0.0) != 0 }.map(\.1)
    }
}

public enum InterfaceInventory {
    public static func snapshot() -> [InterfaceSnapshot] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var byName: [String: InterfaceSnapshot] = [:]
        var order: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            if byName[name] == nil {
                byName[name] = InterfaceSnapshot(name: name, index: Int(if_nametoindex(name)), flags: ifa.pointee.ifa_flags,
                                                 mtu: 0, mac: nil, ipv4: [], ipv6: [], rxBytes: 0, txBytes: 0,
                                                 rxPackets: 0, txPackets: 0, rxErrors: 0, txErrors: 0)
                order.append(name)
            }
            guard let sa = ifa.pointee.ifa_addr else { continue }
            var item = byName[name]!
            item.flags = ifa.pointee.ifa_flags
            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                if let data = ifa.pointee.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    item.mtu = Int(d.ifi_mtu)
                    item.rxBytes = UInt64(d.ifi_ibytes)
                    item.txBytes = UInt64(d.ifi_obytes)
                    item.rxPackets = UInt64(d.ifi_ipackets)
                    item.txPackets = UInt64(d.ifi_opackets)
                    item.rxErrors = UInt64(d.ifi_ierrors)
                    item.txErrors = UInt64(d.ifi_oerrors)
                }
                item.mac = macAddress(sa)
            case AF_INET:
                if let a = SocketAddress.string(sa) {
                    let mask = ifa.pointee.ifa_netmask.flatMap { SocketAddress.string($0) }
                    let peer = (ifa.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) != 0)
                        ? ifa.pointee.ifa_dstaddr.flatMap { SocketAddress.string($0) } : nil
                    item.ipv4.append(InterfaceAddress(address: a, netmask: mask, peer: peer))
                }
            case AF_INET6:
                if let a = SocketAddress.string(sa) {
                    let mask = ifa.pointee.ifa_netmask.flatMap { SocketAddress.string($0) }
                    item.ipv6.append(InterfaceAddress(address: a.components(separatedBy: "%").first ?? a, netmask: mask, peer: nil))
                }
            default:
                break
            }
            byName[name] = item
        }
        return order.compactMap { byName[$0] }
    }

    private static func macAddress(_ sa: UnsafePointer<sockaddr>) -> String? {
        sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl -> String? in
            let alen = Int(sdl.pointee.sdl_alen)
            let nlen = Int(sdl.pointee.sdl_nlen)
            guard alen == 6, let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) else { return nil }
            let base = UnsafeRawPointer(sdl).advanced(by: offset + nlen).assumingMemoryBound(to: UInt8.self)
            let bytes = (0..<alen).map { base[$0] }
            if bytes.allSatisfy({ $0 == 0 }) { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }
}
