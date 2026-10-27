//
//  DDC.swift
//  DimBar — control external display brightness over DDC/CI on Apple Silicon.
//
//  Talks to the display's DDC/CI channel through IOAVService (the private
//  IOKit interface Apple uses on Apple Silicon). No kext, no root, no
//  accessibility permission required.
//

import Foundation
import IOKit
import CoreGraphics

// MARK: - Private IOKit symbols

typealias IOAVServiceRef = CFTypeRef

private typealias AVCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias AVReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias AVWriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias DisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

private enum PrivateAPI {
    static let iokit: UnsafeMutableRawPointer? = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    static let coreDisplay: UnsafeMutableRawPointer? = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

    static func symbol<T>(_ image: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let image, let ptr = dlsym(image, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    static let createWithService = symbol(iokit, "IOAVServiceCreateWithService", as: AVCreateWithServiceFn.self)
    static let readI2C = symbol(iokit, "IOAVServiceReadI2C", as: AVReadFn.self)
    static let writeI2C = symbol(iokit, "IOAVServiceWriteI2C", as: AVWriteFn.self)
    static let displayInfo = symbol(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", as: DisplayInfoFn.self)

    static var isAvailable: Bool {
        createWithService != nil && readI2C != nil && writeI2C != nil && displayInfo != nil
    }
}

// MARK: - VCP codes

enum VCP {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
}

let DDC_CHIP_DEFAULT: UInt32 = 0x37
let DDC_ADDR_SOURCE: UInt8 = 0x51   // I2C sub-address; part of the DDC packet checksum
let DDC_ADDR_DEST: UInt8 = 0x6E

// MARK: - Errors

enum DDCError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case symbolsMissing
    case noService(String)
    case noReply(String)
    case io(IOReturn, String)

    var description: String {
        switch self {
        case .unsupportedPlatform: return "DDC over IOAVService requires Apple Silicon"
        case .symbolsMissing:      return "could not resolve IOAVService private symbols"
        case .noService(let n):    return "no DDC service for display \(n)"
        case .noReply(let n):      return "display \(n) did not answer DDC requests"
        case .io(let r, let n):    return "I/O error \(r) on display \(n)"
        }
    }
}

// MARK: - IORegistry helpers

private func entryName(_ entry: io_registry_entry_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    IORegistryEntryGetName(entry, &buf)
    return String(cString: buf)
}

private func registryID(_ entry: io_registry_entry_t) -> UInt64 {
    var value: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(entry, &value) == KERN_SUCCESS else { return 0 }
    return value
}

private func searchProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString,
                                    kCFAllocatorDefault,
                                    IOOptionBits(kIORegistryIterateRecursively))
}

// MARK: - Display

/// One physical external display that speaks DDC/CI.
final class ExternalDisplay {
    let id: CGDirectDisplayID
    let name: String
    let serialKey: String
    let bus: DDCBus

    init(id: CGDirectDisplayID, name: String, serialKey: String, bus: DDCBus) {
        self.id = id
        self.name = name
        self.serialKey = serialKey
        self.bus = bus
    }

    var brightnessPercent: Int? {
        guard let value = bus.read(vcp: VCP.brightness) else { return nil }
        return value.percent
    }
}

// MARK: - DDC bus

/// A single display's DDC/CI channel.
final class DDCBus {
    private let service: IOAVServiceRef
    private let chip: UInt32
    private let label: String

    init(service: IOAVServiceRef, chip: UInt32, label: String) {
        self.service = service
        self.chip = chip
        self.label = label
    }

    // MARK: packet building

    private func readRequest(vcp: UInt8, specChecksum: Bool) -> [UInt8] {
        let header: [UInt8] = [0x82, 0x01, vcp]
        var checksum = DDC_ADDR_DEST ^ header[0] ^ header[1] ^ header[2]
        if specChecksum { checksum ^= DDC_ADDR_SOURCE }
        return header + [checksum]
    }

    private func writeRequest(vcp: UInt8, value: Int, specChecksum: Bool) -> [UInt8] {
        let header: [UInt8] = [0x84, 0x03, vcp, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        var checksum = DDC_ADDR_DEST ^ header[0] ^ header[1] ^ header[2] ^ header[3] ^ header[4]
        if specChecksum { checksum ^= DDC_ADDR_SOURCE }
        return header + [checksum]
    }

    // MARK: transport

    private func write(_ bytes: [UInt8]) -> IOReturn {
        guard let writeI2C = PrivateAPI.writeI2C else { return kIOReturnUnsupported }
        var payload = bytes
        var result: IOReturn = kIOReturnSuccess
        payload.withUnsafeMutableBytes { raw in
            result = writeI2C(service, chip, UInt32(DDC_ADDR_SOURCE), raw.baseAddress!, UInt32(bytes.count))
        }
        return result
    }

    private func read(count: Int = 12) -> [UInt8]? {
        guard let readI2C = PrivateAPI.readI2C else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var result: IOReturn = kIOReturnSuccess
        buffer.withUnsafeMutableBytes { raw in
            result = readI2C(service, chip, UInt32(DDC_ADDR_SOURCE), raw.baseAddress!, UInt32(count))
        }
        guard result == kIOReturnSuccess else { return nil }
        return buffer
    }

    /// A valid "Get VCP Feature Reply" starts with 6E 88 and echoes the VCP code.
    private func validate(_ reply: [UInt8], vcp: UInt8) -> Bool {
        reply.count >= 10 && reply[0] == DDC_ADDR_DEST && reply[1] == 0x88 && reply[4] == vcp
    }

    // MARK: public API

    struct Value {
        let current: Int
        let maximum: Int
        var percent: Int {
            guard maximum > 0 else { return 0 }
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
    }

    /// Reads a VCP feature. Tries the spec-compliant checksum first, then the
    /// variant that omits the source address (some tools use it, some monitors want it).
    func read(vcp: UInt8, attempts: Int = 2) -> Value? {
        for specChecksum in [true, false] {
            for _ in 0..<attempts {
                usleep(10_000)
                let status = write(readRequest(vcp: vcp, specChecksum: specChecksum))
                guard status == kIOReturnSuccess else { continue }
                usleep(10_000)
                guard let reply = read(), validate(reply, vcp: vcp) else { continue }
                let maximum = Int(reply[6]) << 8 | Int(reply[7])
                let current = Int(reply[8]) << 8 | Int(reply[9])
                guard maximum > 0 else { continue }
                return Value(current: current, maximum: maximum)
            }
        }
        return nil
    }

    /// Writes a VCP feature and verifies it by reading back.
    @discardableResult
    func write(vcp: UInt8, value: Int) -> Bool {
        for specChecksum in [true, false] {
            for _ in 0..<3 {
                usleep(10_000)
                // DDC/CI guideline: send the set request twice, some displays drop the first.
                _ = write(writeRequest(vcp: vcp, value: value, specChecksum: specChecksum))
                usleep(10_000)
                let status = write(writeRequest(vcp: vcp, value: value, specChecksum: specChecksum))
                guard status == kIOReturnSuccess else { continue }

                if let readBack = read(vcp: vcp) {
                    if abs(readBack.current - value) <= max(1, readBack.maximum / 100) { return true }
                } else {
                    // Display does not support reading back; trust the write.
                    return true
                }
            }
        }
        return false
    }

    func setBrightness(percent: Int) {
        guard let maxValue = read(vcp: VCP.brightness)?.maximum else {
            write(vcp: VCP.brightness, value: percent)
            return
        }
        let clamped = min(max(percent, 0), 100)
        let raw = Int((Double(clamped) / 100.0 * Double(maxValue)).rounded())
        write(vcp: VCP.brightness, value: raw)
    }
}

// MARK: - Discovery

enum DisplayDiscovery {

    /// All online displays that expose a working DDC channel, external only.
    static func externalDisplays() -> [ExternalDisplay] {
        guard PrivateAPI.isAvailable else { return [] }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let proxies = externalDDCProxies()
        var result: [ExternalDisplay] = []

        for id in ids.prefix(Int(count)) {
            guard CGDisplayIsBuiltin(id) == 0, CGDisplayIsActive(id) != 0 else { continue }
            guard let info = displayInfoDictionary(id) else { continue }
            guard let location = info["IODisplayLocation"] as? String else { continue }
            guard let adapter = adapterEntry(location: location) else { continue }
            defer { IOObjectRelease(adapter) }

            let name = productName(adapter: adapter) ?? "External Display"
            guard let proxy = matchProxy(for: adapter, among: proxies) else { continue }
            guard let service = PrivateAPI.createWithService?(kCFAllocatorDefault, proxy)?.takeRetainedValue() else { continue }

            let key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            result.append(ExternalDisplay(id: id, name: name, serialKey: key,
                                          bus: DDCBus(service: service, chip: DDC_CHIP_DEFAULT, label: name)))
        }
        return result
    }

    private static func displayInfoDictionary(_ id: CGDirectDisplayID) -> [String: Any]? {
        guard let fn = PrivateAPI.displayInfo, let dict = fn(id)?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }

    private static func adapterEntry(location: String) -> io_registry_entry_t? {
        let entry = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        return entry == 0 ? nil : entry
    }

    private static func productName(adapter: io_registry_entry_t) -> String? {
        guard let attributes = searchProperty(adapter, "DisplayAttributes") as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any] else { return nil }
        return product["ProductName"] as? String
    }

    /// Walks up `depth` parents and returns their registry IDs.
    private static func ancestorIDs(of entry: io_registry_entry_t, depth: Int = 12) -> Set<UInt64> {
        var ids: Set<UInt64> = []
        var current = entry
        var owned: [io_registry_entry_t] = []
        for _ in 0..<depth {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            ids.insert(registryID(parent))
            owned.append(parent)
            current = parent
        }
        owned.forEach { IOObjectRelease($0) }
        return ids
    }

    /// Every `DCPAVServiceProxy` node whose `Location` is `External`.
    private static func externalDDCProxies() -> [(service: io_service_t, ancestors: Set<UInt64>)] {
        var found: [(io_service_t, Set<UInt64>)] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            guard entryName(entry) == "DCPAVServiceProxy" else {
                IOObjectRelease(entry)
                continue
            }
            let location = searchProperty(entry, "Location") as? String
            if location == "External" {
                found.append((entry, ancestorIDs(of: entry)))
            } else {
                IOObjectRelease(entry)
            }
        }
        return found
    }

    /// A display's framebuffer shares its parent device (e.g. `dispext0`) with
    /// the matching DCPAVServiceProxy, so we match on shared ancestry.
    private static func matchProxy(for adapter: io_registry_entry_t,
                                   among proxies: [(service: io_service_t, ancestors: Set<UInt64>)]) -> io_service_t? {
        guard !proxies.isEmpty else { return nil }
        if proxies.count == 1 { return proxies[0].service }

        let adapterAncestors = ancestorIDs(of: adapter)
        if let hit = proxies.first(where: { !$0.ancestors.isDisjoint(with: adapterAncestors) }) {
            return hit.service
        }
        return proxies.first?.service
    }
}
