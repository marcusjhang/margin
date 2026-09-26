import Darwin
import Foundation

/// Enumerates the calling user's listening sockets: which port is bound on
/// which address, by which process.
///
/// Two sources sit behind the one API:
/// - **Primary** — `sysctl net.inet.tcp.pcblist_n` / `net.inet.udp.pcblist_n`.
///   Every record is bounds-checked on its length field; records whose pid is 0
///   (other users / unreadable) are skipped.
/// - **Fallback / enrichment** — `libproc` (`proc_listallpids`,
///   `proc_pidinfo(PROC_PIDFDSOCKETINFO)`, `proc_pidpath`) supplies the owning
///   pid and process path for same-user processes, since the modern sysctl
///   snapshot does not export the pid directly.
public struct PortProcessSource: Sendable {
    public init() {}

    public func listeners() async -> [LiveState.Listener] {
        let sockets = Self.sysctlListeners()                    // port + address, pid 0
        var procByKey: [String: LiveState.Listener] = [:]
        for listener in Self.procListeners() where listener.pid > 0 {
            procByKey[Self.key(listener)] = listener
        }

        var result: [LiveState.Listener] = []
        var seen = Set<String>()
        for socket in sockets {
            // A sysctl socket with no matching same-user process is pid 0
            // (other user or kernel) and must be skipped. The kernel can expose
            // several PCB entries for one socket, so dedupe by address+port.
            let key = Self.key(socket)
            if let owned = procByKey[key], owned.pid > 0, seen.insert(key).inserted {
                result.append(owned)
            }
        }
        result.sort { ($0.port, $0.address) < ($1.port, $1.address) }
        return result
    }

    private static func key(_ listener: LiveState.Listener) -> String {
        "\(listener.port)|\(listener.address)"
    }

    // MARK: - sysctl pcblist_n (primary)

    /// Reads the two pcblist_n sysctls and decodes listening records. Pure and
    /// bounds-checked so malformed or truncated buffers never crash.
    static func sysctlListeners() -> [LiveState.Listener] {
        var result: [LiveState.Listener] = []
        if let tcp = readSysctl("net.inet.tcp.pcblist_n") {
            result.append(contentsOf: parseSysctl(tcp))
        }
        if let udp = readSysctl("net.inet.udp.pcblist_n") {
            result.append(contentsOf: parseSysctl(udp))
        }
        return result
    }

    private static func readSysctl(_ name: String) -> Data? {
        var mib: [Int32] = []
        let parts = name.split(separator: ".")
        switch parts.first {
        case "net":
            mib = name == "net.inet.tcp.pcblist_n"
                ? [CTL_NET, PF_INET, IPPROTO_TCP, TCPCTL_PCBLIST]
                : [CTL_NET, PF_INET, IPPROTO_UDP, UDPCTL_PCBLIST]
        default:
            return nil
        }
        var mib32 = mib
        var size = 0
        guard sysctl(&mib32, u_int(mib32.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int32 in
            sysctl(&mib32, u_int(mib32.count), ptr.baseAddress, &size, nil, 0)
        }
        guard ok == 0 else { return nil }
        return data
    }

    /// Decodes the pcblist_n byte stream into listeners. Walks records by their
    /// length field, bounds-checking every read against the buffer size.
    ///
    /// macOS exports each socket as a record whose first field is the record
    /// length. The inpcb prefix that follows is shared by TCP and UDP:
    /// - record length: offset 0 (u32, little-endian)
    /// - foreign port: offset 20 (u16, network order)
    /// - local port: offset 22 (u16, network order)
    /// - inp_vflag: offset 80 (u32; bit 0 = IPv4, bit 1 = IPv6)
    /// - IPv4 local addr: offset 112 (u32, network order)
    /// - IPv6 local addr: offset 100 (16 bytes)
    static func parseSysctl(_ data: Data) -> [LiveState.Listener] {
        let count = data.count
        guard count >= 24 else { return [] }
        let genLen = Int(readU32(data, 0))
        guard genLen >= 24, genLen <= count else { return [] }

        var result: [LiveState.Listener] = []
        var offset = genLen

        while offset + 24 <= count {
            let recordLen = Int(readU32(data, offset))
            // Bounds-check the record: it must be sane and fully contained.
            guard recordLen >= 24, offset + recordLen <= count else { break }

            let port = Int(readU16BE(data, offset + 22))
            let vflag = readU32(data, offset + 80)

            if port > 0 {
                var address: String? = nil
                if vflag & 0x1 != 0 {
                    address = formatIPv4Bytes(readBytes(data, offset + 112, 4))
                } else if vflag & 0x2 != 0 {
                    address = formatAddress(readBytes(data, offset + 100, 16), family: AF_INET6)
                }
                if let address {
                    // pid is not present in the modern snapshot; libproc fills it.
                    result.append(LiveState.Listener(port: port, address: address, pid: 0, processPath: nil))
                }
            }

            offset += recordLen
        }
        return result
    }

    // MARK: - libproc (pid + path enrichment)

    static func procListeners() -> [LiveState.Listener] {
        var pids = [Int32](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<Int32>.size, pids.count)

        var result: [LiveState.Listener] = []
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let path = processPath(pid)
            for socket in socketInfo(pid: pid) {
                result.append(LiveState.Listener(
                    port: socket.port,
                    address: socket.address,
                    pid: pid,
                    processPath: path
                ))
            }
        }
        return result
    }

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func socketInfo(pid: Int32) -> [(port: Int, address: String)] {
        // 1. Enumerate the process's file descriptors.
        let fdStride = MemoryLayout<proc_fdinfo>.size
        var fdBuffer = [UInt8](repeating: 0, count: fdStride * 4096)
        let fdBufferSize = fdBuffer.count
        let fdBytes = fdBuffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(fdBufferSize))
        }
        guard fdBytes > 0 else { return [] }
        let fdCount = min(Int(fdBytes) / fdStride, 4096)

        var result: [(port: Int, address: String)] = []
        for index in 0..<fdCount {
            let fdi = fdBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * fdStride, as: proc_fdinfo.self) }
            guard fdi.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }

            // 2. Query that socket's addresses and ports.
            let sockStride = MemoryLayout<socket_fdinfo>.size
            var sockBuffer = [UInt8](repeating: 0, count: sockStride)
            let written = sockBuffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
                proc_pidfdinfo(pid, fdi.proc_fd, PROC_PIDFDSOCKETINFO, raw.baseAddress, Int32(sockStride))
            }
            guard written >= Int32(sockStride) else { continue }
            let fd = sockBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: socket_fdinfo.self) }

            // Only listening sockets count as bound ports.
            let info: in_sockinfo
            let listening: Bool
            switch Int(fd.psi.soi_kind) {
            case SOCKINFO_TCP:
                info = fd.psi.soi_proto.pri_tcp.tcpsi_ini
                listening = fd.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            case SOCKINFO_IN:
                info = fd.psi.soi_proto.pri_in
                listening = true
            default:
                continue
            }
            guard listening else { continue }
            // insi_lport is exported in network byte order.
            let port = Int(UInt16(truncatingIfNeeded: info.insi_lport).byteSwapped)
            guard port > 0 else { continue }

            let addrBytes = withUnsafeBytes(of: info.insi_laddr) { Array($0) }
            var address: String? = nil
            if info.insi_vflag & 0x1 != 0 {
                address = formatAddress(Array(addrBytes.suffix(4)), family: AF_INET)
            } else if info.insi_vflag & 0x2 != 0 {
                address = formatAddress(addrBytes, family: AF_INET6)
            }
            if let address {
                result.append((port: port, address: address))
            }
        }
        return result
    }

    // MARK: - Byte helpers

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func readU16BE(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let hi = data[data.startIndex + offset]
        let lo = data[data.startIndex + offset + 1]
        return UInt16(hi) << 8 | UInt16(lo)
    }

    private static func readBytes(_ data: Data, _ offset: Int, _ length: Int) -> [UInt8] {
        guard offset >= 0, offset + length <= data.count else { return [] }
        let start = data.startIndex + offset
        return [UInt8](data[start..<start + length])
    }

    private static func formatIPv4Bytes(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 4 else { return nil }
        return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }

    private static func formatAddress(_ bytes: [UInt8], family: Int32) -> String? {
        let length = family == AF_INET ? 4 : 16
        guard bytes.count >= length else { return nil }
        let src = Array(bytes.prefix(length))
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard inet_ntop(family, raw.baseAddress, &out, socklen_t(out.count)) != nil else { return nil }
            return String(cString: out)
        }
        return result
    }
}
