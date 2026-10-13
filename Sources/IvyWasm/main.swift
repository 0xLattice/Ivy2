import IvyCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// The core for a JavaScript host: a WASI reactor exporting the functions
// below. Events go in and effects come out as docs/event-codec.md encodes
// them. The module is given the time on every step and reads no clock.
//
// A function that returns bytes returns a block the caller frees with
// `ivy_free`: a little-endian UInt32 length, then that many bytes. Zero
// means there was nothing to return: an unknown handle, or input that does
// not decode.

// WebAssembly runs one thread, so nothing races on these.
nonisolated(unsafe) private var cores: [Int32: IvyCore] = [:]
nonisolated(unsafe) private var lastHandle: Int32 = 0

private func block(_ bytes: Data) -> UnsafeMutableRawPointer {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 4 + bytes.count, alignment: 8)
    pointer.storeBytes(of: UInt32(bytes.count).littleEndian, as: UInt32.self)
    bytes.copyBytes(to: (pointer + 4).assumingMemoryBound(to: UInt8.self), count: bytes.count)
    return pointer
}

private func input(_ pointer: UnsafeRawPointer?, _ length: Int32) -> Data {
    guard let pointer, length > 0 else { return Data() }
    return Data(bytes: pointer, count: Int(length))
}

@_expose(wasm, "ivy_alloc")
@_cdecl("ivy_alloc")
func ivyAlloc(_ length: Int32) -> UnsafeMutableRawPointer? {
    guard length > 0 else { return nil }
    return UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: 8)
}

@_expose(wasm, "ivy_free")
@_cdecl("ivy_free")
func ivyFree(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// What a connection may be sent before the core waits for `writable`.
@_expose(wasm, "ivy_write_high_water_mark")
@_cdecl("ivy_write_high_water_mark")
func ivyWriteHighWaterMark() -> Int32 {
    Int32(IvyCore.writeHighWaterMark)
}

/// A core from an encoded configuration, or zero if the bytes are not one
/// or the configuration is not valid.
@_expose(wasm, "ivy_core_create")
@_cdecl("ivy_core_create")
func ivyCoreCreate(_ pointer: UnsafeRawPointer?, _ length: Int32) -> Int32 {
    guard let config = IvyConfig(encoded: input(pointer, length)),
          (try? config.validate()) != nil,
          lastHandle < .max else { return 0 }
    lastHandle += 1
    cores[lastHandle] = IvyCore(config: config)
    return lastHandle
}

@_expose(wasm, "ivy_core_destroy")
@_cdecl("ivy_core_destroy")
func ivyCoreDestroy(_ handle: Int32) {
    cores[handle] = nil
}

/// Applies one encoded event at the given time and returns the effects.
@_expose(wasm, "ivy_core_step")
@_cdecl("ivy_core_step")
func ivyCoreStep(
    _ handle: Int32,
    _ pointer: UnsafeRawPointer?,
    _ length: Int32,
    _ uptimeNanoseconds: UInt64,
    _ unixSeconds: UInt64
) -> UnsafeMutableRawPointer? {
    guard cores[handle] != nil, let event = Event(encoded: input(pointer, length)) else {
        return nil
    }
    let now = Timestamp(uptime: .nanoseconds(uptimeNanoseconds), unixSeconds: unixSeconds)
    return block(Effect.encoded(cores[handle]!.step(event, now: now)))
}

/// The node's 32-byte Ed25519 public key.
@_expose(wasm, "ivy_core_public_key")
@_cdecl("ivy_core_public_key")
func ivyCorePublicKey(_ handle: Int32) -> UnsafeMutableRawPointer? {
    cores[handle].map { block($0.config.peerKey.rawRepresentation) }
}

@_expose(wasm, "ivy_core_connected_peers")
@_cdecl("ivy_core_connected_peers")
func ivyCoreConnectedPeers(_ handle: Int32) -> UnsafeMutableRawPointer? {
    cores[handle].map { block(EventCodec.encoded(peers: $0.connectedPeers)) }
}

@_expose(wasm, "ivy_core_connected_peer_endpoints")
@_cdecl("ivy_core_connected_peer_endpoints")
func ivyCoreConnectedPeerEndpoints(_ handle: Int32) -> UnsafeMutableRawPointer? {
    cores[handle].map { block(EventCodec.encoded(endpoints: $0.connectedPeerEndpoints)) }
}

@_expose(wasm, "ivy_core_known_peer_endpoints")
@_cdecl("ivy_core_known_peer_endpoints")
func ivyCoreKnownPeerEndpoints(_ handle: Int32) -> UnsafeMutableRawPointer? {
    cores[handle].map { block(EventCodec.encoded(endpoints: $0.knownPeerEndpoints)) }
}

/// The peers with an unexpired provider record for a root, given as UTF-8.
@_expose(wasm, "ivy_core_providers")
@_cdecl("ivy_core_providers")
func ivyCoreProviders(
    _ handle: Int32,
    _ pointer: UnsafeRawPointer?,
    _ length: Int32
) -> UnsafeMutableRawPointer? {
    cores[handle].map {
        block(EventCodec.encoded(
            peers: $0.providers(for: String(decoding: input(pointer, length), as: UTF8.self))))
    }
}
