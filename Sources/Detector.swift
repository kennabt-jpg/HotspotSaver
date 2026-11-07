import Foundation
import Network

struct NetInfo {
    var connected: Bool
    var metered: Bool
    var lowDataMode: Bool
    var interface: String?
    var interfaceKind: String
    var gateway: String?
    var address: String?
    var tethered: Bool
    var reasons: [String]

    var summary: String {
        guard connected else { return "No internet connection" }
        var parts = [interface.map { "\(interfaceKind) (\($0))" } ?? interfaceKind]
        if let g = gateway { parts.append("gateway \(g)") }
        parts.append(metered ? "metered" : "not metered")
        parts.append("Low Data Mode \(lowDataMode ? "on" : "off")")
        return parts.joined(separator: " · ")
    }
}

/// Decides whether the Mac is on a phone hotspot.
///
/// Two monitors run side by side:
/// - `physical` ignores tunnel interfaces, so it sees the real uplink under most VPNs;
/// - `overall` is the normal system path. VPNs built on Apple's Network Extension framework
///   (most corporate and consumer VPNs) pass the "metered" flag through from the interface underneath.
/// Signals: macOS's metered ("expensive") flag, which it sets for iPhone hotspots over
/// Wi-Fi, USB and Bluetooth, and the iPhone hotspot subnet 172.20.10.0/28.
final class Detector: @unchecked Sendable {
    var config = DetectionConfig()
    var onUpdate: ((NetInfo) -> Void)?
    private var monitors: [NWPathMonitor] = []
    private var physicalPath: NWPath?
    private var overallPath: NWPath?

    /// Callbacks arrive on `queue`; `current()` must be called on the same queue.
    func start(queue: DispatchQueue = .main) {
        let physical = NWPathMonitor(prohibitedInterfaceTypes: [.other])
        let overall = NWPathMonitor()
        physical.pathUpdateHandler = { [weak self] p in self?.physicalPath = p; self?.emit() }
        overall.pathUpdateHandler = { [weak self] p in self?.overallPath = p; self?.emit() }
        physical.start(queue: queue)
        overall.start(queue: queue)
        monitors = [physical, overall]
    }

    func stop() { monitors.forEach { $0.cancel() }; monitors = [] }

    var hasBothPaths: Bool { physicalPath != nil && overallPath != nil }

    private func emit() {
        if let info = current() { onUpdate?(info) }
    }

    func current() -> NetInfo? {
        guard physicalPath != nil || overallPath != nil else { return nil }
        return evaluate(physical: physicalPath, overall: overallPath)
    }

    func evaluate(physical: NWPath?, overall: NWPath?) -> NetInfo {
        let phys = physical?.status == .satisfied ? physical : nil
        let all = overall?.status == .satisfied ? overall : nil
        // A path that is "up" only through a VPN tunnel isn't a real connection: when the hotspot
        // drops, a full-tunnel VPN can keep the overall path satisfied for a while.
        let underlay = (all?.availableInterfaces.contains { !isTunnelInterface($0.name) } ?? false)
            || allIPv4().contains { !isTunnelInterface($0.name) && $0.octets.first != 169 }
        let connected = phys != nil || (all != nil && underlay)
        let metered = (phys?.isExpensive ?? false) || (all?.isExpensive ?? false)
        let lowData = (phys?.isConstrained ?? false) || (all?.isConstrained ?? false)
        let best = phys ?? all
        let iface = best?.availableInterfaces.first { $0.type != .other && $0.type != .loopback }
        let gateways: [String] = (best?.gateways ?? []).compactMap { ep in
            if case let .hostPort(host, _) = ep, case let .ipv4(a) = host { return "\(a)" }
            return nil
        }
        let v4 = iface.flatMap { ipv4(interface: $0.name) }

        var reasons: [String] = []
        if config.useMeteredFlag && metered { reasons.append("macOS marks this connection as metered") }
        for prefix in config.hotspotAddressPrefixes where !prefix.isEmpty {
            if prefix == "172.20.10." {
                // iPhone Personal Hotspot: client address 172.20.10.2–14 on a /28.
                if let v4, isIPhoneHotspot(v4) {
                    reasons.append("iPhone hotspot address \(v4.address)")
                } else if iface == nil, let other = anyIPhoneHotspotInterface() {
                    // Primary interface hidden behind a VPN tunnel: look at the physical interfaces directly.
                    reasons.append("iPhone hotspot address \(other.address) on \(other.name)")
                }
            } else if let g = gateways.first(where: { $0.hasPrefix(prefix) }) {
                reasons.append("gateway \(g) matches \(prefix)")
            } else if let v4, v4.address.hasPrefix(prefix) {
                reasons.append("address \(v4.address) matches \(prefix)")
            }
        }

        let kind: String
        switch iface?.type {
        case .wifi?: kind = "Wi-Fi"
        case .wiredEthernet?: kind = "USB/Ethernet"
        case .cellular?: kind = "Cellular"
        default: kind = all != nil && phys == nil ? "VPN" : "Network"
        }
        return NetInfo(connected: connected, metered: metered, lowDataMode: lowData,
                       interface: iface?.name, interfaceKind: kind, gateway: gateways.first,
                       address: v4?.address, tethered: connected && !reasons.isEmpty, reasons: reasons)
    }

    /// One-shot detection for the command-line tool.
    static func detectOnce(config: DetectionConfig, timeout: TimeInterval = 3) -> NetInfo? {
        let queue = DispatchQueue(label: "local.HotspotSaver.detect-once")
        let d = Detector()
        d.config = config
        let ready = DispatchSemaphore(value: 0)
        var signalled = false
        d.onUpdate = { _ in
            if d.hasBothPaths && !signalled { signalled = true; ready.signal() }
        }
        d.start(queue: queue)
        _ = ready.wait(timeout: .now() + timeout)
        let info = queue.sync { d.current() }
        queue.sync { d.stop() }
        return info
    }
}

struct IPv4Info {
    let name: String
    let address: String
    let octets: [UInt8]
    let mask: UInt32
}

func isIPhoneHotspot(_ v: IPv4Info) -> Bool {
    v.octets.count == 4 && v.octets[0] == 172 && v.octets[1] == 20 && v.octets[2] == 10
        && (2...14).contains(v.octets[3]) && v.mask == 0xFFFF_FFF0
}

/// Interfaces that aren't a physical uplink: VPN tunnels, loopback, bridges, AirDrop/peer links, VM networks.
private let tunnelPrefixes = ["utun", "ipsec", "ppp", "lo", "gif", "stf", "bridge", "awdl", "llw", "anpi", "vmnet", "vboxnet"]

func isTunnelInterface(_ name: String) -> Bool { tunnelPrefixes.contains { name.hasPrefix($0) } }

/// Any up, non-tunnel interface sitting on an iPhone hotspot subnet.
func anyIPhoneHotspotInterface() -> IPv4Info? {
    allIPv4().first { !isTunnelInterface($0.name) && isIPhoneHotspot($0) }
}

func ipv4(interface name: String) -> IPv4Info? {
    allIPv4().first { $0.name == name }
}

func allIPv4() -> [IPv4Info] {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    var out: [IPv4Info] = []
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let mask = ifa.ifa_netmask.map { nm in
            nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        } ?? 0
        let host = UInt32(bigEndian: addr)
        let octets = [UInt8(host >> 24), UInt8((host >> 16) & 0xFF), UInt8((host >> 8) & 0xFF), UInt8(host & 0xFF)]
        out.append(IPv4Info(name: String(cString: ifa.ifa_name),
                            address: octets.map(String.init).joined(separator: "."),
                            octets: octets, mask: mask))
    }
    return out
}
