import Darwin
import Foundation

public enum IPv4 {
    public static func parse(_ s: String) -> UInt32? {
        var addr = in_addr()
        let ok = s.withCString { inet_pton(AF_INET, $0, &addr) }
        guard ok == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    public static func isValid(_ s: String) -> Bool { parse(s) != nil }

    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }

    public static func mask(prefix: Int) -> UInt32 {
        prefix <= 0 ? 0 : (prefix >= 32 ? UInt32.max : UInt32.max << UInt32(32 - prefix))
    }

    public static func maskString(prefix: Int) -> String { format(mask(prefix: prefix)) }

    /// Accepts dotted (255.255.0.0) or hex (0xffff0000) masks.
    public static func prefix(fromMask s: String) -> Int? {
        var value: UInt32?
        if s.hasPrefix("0x") { value = UInt32(s.dropFirst(2), radix: 16) } else { value = parse(s) }
        guard let v = value else { return nil }
        let bits = v.nonzeroBitCount
        return mask(prefix: bits) == v ? bits : nil
    }

    public static func contains(network: String, prefix: Int, ip: String) -> Bool {
        guard let n = parse(network), let a = parse(ip) else { return false }
        let m = mask(prefix: prefix)
        return n & m == a & m
    }

    public static func isPrivate(_ s: String) -> Bool {
        guard let v = parse(s) else { return false }
        return contains(network: "10.0.0.0", prefix: 8, ip: s) || contains(network: "172.16.0.0", prefix: 12, ip: s)
            || contains(network: "192.168.0.0", prefix: 16, ip: s) || contains(network: "100.64.0.0", prefix: 10, ip: s)
            || v >> 24 == 127 || contains(network: "169.254.0.0", prefix: 16, ip: s)
    }
}

public enum Validation {
    public static func isDomain(_ raw: String) -> Bool {
        var d = raw.lowercased()
        if d.hasSuffix(".") { d.removeLast() }
        guard !d.isEmpty, d.count <= 253 else { return false }
        let labels = d.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        return !(labels.last!.allSatisfy { $0.isNumber })
    }

    public static func isInterfaceName(_ s: String) -> Bool {
        guard (2...15).contains(s.count), let first = s.first, first.isASCII, first.isLetter else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    public static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }
}
