import Foundation
import IvyCore
import Tally

public protocol IvyContentSource: Sendable {
    /// Return every entry in the complete local Volume rooted at `rootCID`, or
    /// `[]`. Ivy transports the boundary opaquely; the application validates
    /// the content-addressed bytes before publishing it.
    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry]

    func authorizesVolumeRequest(
        from peer: AuthenticatedPeer,
        rootCID: String
    ) async -> Bool

    /// The roots of the Volumes this source bundles under `rootCID`, its own
    /// first, or `[]` when it holds no bundle for it. Each is then read with
    /// `volume` and authorized as a Volume request for it.
    func volumeBundle(rootCID: String) async -> [String]
}

public extension IvyContentSource {
    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        []
    }

    func volumeBundle(rootCID: String) async -> [String] {
        []
    }

    func authorizesVolumeRequest(
        from peer: AuthenticatedPeer,
        rootCID: String
    ) async -> Bool {
        true
    }
}
