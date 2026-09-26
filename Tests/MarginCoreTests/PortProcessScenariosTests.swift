import XCTest
@testable import MarginCore

/// Synthetic-fixture coverage of the sysctl pcblist parser: record walking,
/// bounds-checking, IPv4/IPv6 address extraction, and pid-0 / malformed skips.
final class PortProcessScenariosTests: XCTestCase {
    private func writeU32(_ bytes: inout [UInt8], _ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8((value >> 16) & 0xff)
        bytes[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func writeU16BE(_ bytes: inout [UInt8], _ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xff)
    }

    /// Builds a pcblist_n buffer: a 24-byte gen header followed by records.
    private func pcblist(records: [(port: UInt16, vflag: UInt32, ipv4: [UInt8], ipv6: [UInt8], length: Int)]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        writeU32(&bytes, 24, at: 0)                                  // gen header length

        for record in records {
            var rec = [UInt8](repeating: 0, count: record.length)
            writeU32(&rec, UInt32(record.length), at: 0)
            writeU16BE(&rec, record.port, at: 22)
            writeU32(&rec, record.vflag, at: 80)
            if record.vflag & 0x1 != 0 {
                for (i, byte) in record.ipv4.enumerated() { rec[112 + i] = byte }
            } else {
                for (i, byte) in record.ipv6.enumerated() { rec[100 + i] = byte }
            }
            bytes.append(contentsOf: rec)
        }
        return Data(bytes)
    }

    func testExtractsIPv4Listener() {
        let buffer = pcblist(records: [(port: 5432, vflag: 0x1, ipv4: [192, 168, 0, 14], ipv6: [], length: 524)])
        let listeners = PortProcessSource.parseSysctl(buffer)
        XCTAssertEqual(listeners.count, 1)
        XCTAssertEqual(listeners[0].port, 5432)
        XCTAssertEqual(listeners[0].address, "192.168.0.14")
        XCTAssertEqual(listeners[0].pid, 0)                 // pid comes from libproc
    }

    func testExtractsIPv6Loopback() {
        var ipv6 = [UInt8](repeating: 0, count: 16)
        ipv6[15] = 1                                        // ::1
        let buffer = pcblist(records: [(port: 8080, vflag: 0x2, ipv4: [], ipv6: ipv6, length: 524)])
        let listeners = PortProcessSource.parseSysctl(buffer)
        XCTAssertEqual(listeners.count, 1)
        XCTAssertEqual(listeners[0].address, "::1")
        XCTAssertTrue(listeners[0].isLoopback)
    }

    func testSkipsPortZeroRecords() {
        let buffer = pcblist(records: [(port: 0, vflag: 0x1, ipv4: [127, 0, 0, 1], ipv6: [], length: 524)])
        XCTAssertTrue(PortProcessSource.parseSysctl(buffer).isEmpty)
    }

    func testTruncatedRecordIsSkippedNotCrashed() {
        // Declares a 524-byte record but only provides 100 bytes.
        var bytes = [UInt8](repeating: 0, count: 24)
        writeU32(&bytes, 24, at: 0)
        var rec = [UInt8](repeating: 0, count: 100)
        writeU32(&rec, 524, at: 0)
        bytes.append(contentsOf: rec)
        XCTAssertTrue(PortProcessSource.parseSysctl(Data(bytes)).isEmpty)
    }

    func testZeroLengthRecordStopsWalk() {
        var bytes = [UInt8](repeating: 0, count: 24)
        writeU32(&bytes, 24, at: 0)
        var rec = [UInt8](repeating: 0, count: 24)
        writeU32(&rec, 0, at: 0)                            // bogus zero length
        bytes.append(contentsOf: rec)
        XCTAssertTrue(PortProcessSource.parseSysctl(Data(bytes)).isEmpty)
    }

    func testEmptyAndTinyBuffersReturnEmpty() {
        XCTAssertTrue(PortProcessSource.parseSysctl(Data()).isEmpty)
        XCTAssertTrue(PortProcessSource.parseSysctl(Data([0x01, 0x02, 0x03])).isEmpty)
    }

    func testMultipleRecordsAllDecoded() {
        let buffer = pcblist(records: [
            (port: 3000, vflag: 0x1, ipv4: [127, 0, 0, 1], ipv6: [], length: 524),
            (port: 3001, vflag: 0x1, ipv4: [10, 0, 0, 5], ipv6: [], length: 524)
        ])
        let listeners = PortProcessSource.parseSysctl(buffer)
        XCTAssertEqual(listeners.map(\.port), [3000, 3001])
    }
}
