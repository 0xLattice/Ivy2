import Foundation
import Tally

public enum VolumeFetchFailure: Sendable, Equatable {
    case callerBoundaryExceeded
    case localCapacityUnavailable
    /// No peer was asked: none was named, or the request could not be sent.
    case notSent
}

public struct AttributedVolumeResponse: Sendable, Equatable {
    public let rootCID: String
    public let entries: [String: Data]
    public let servedBy: PeerID?
    public let failure: VolumeFetchFailure?

    public static let empty = AttributedVolumeResponse(
        rootCID: "",
        entries: [:],
        servedBy: nil
    )
    public static let localCapacityUnavailable = AttributedVolumeResponse(
        rootCID: "",
        entries: [:],
        servedBy: nil,
        failure: .localCapacityUnavailable
    )

    public init(
        rootCID: String,
        entries: [String: Data],
        servedBy: PeerID?,
        failure: VolumeFetchFailure? = nil
    ) {
        self.rootCID = rootCID
        self.entries = entries
        self.servedBy = servedBy
        self.failure = failure
    }
}

/// The Volumes a peer bundles under one root, as served: unvalidated, and
/// possibly fewer than the peer holds.
public struct AttributedVolumeBundleResponse: Sendable, Equatable {
    /// In the order served: the root's own Volume first.
    public let volumes: [AttributedVolumeResponse]
    /// The last peer asked answered that it holds no bundle for the root,
    /// rather than failing or not answering.
    public let noBundle: Bool
    /// The answer ended with the peer's end marker: the bundle is whole, or
    /// the peer holds none. False when it ended any other way (no answer in
    /// time, a stream violation, a lost session, a refusal) or nobody was asked.
    public let ended: Bool
    /// Why an answer that did not end is not the peer's doing: this node cut
    /// it short (`localCapacityUnavailable`, `callerBoundaryExceeded`) or
    /// asked nobody (`notSent`). Nil when the peer ended it, or failed to.
    public let failure: VolumeFetchFailure?

    public static let empty = AttributedVolumeBundleResponse(volumes: [])
    static let localCapacityUnavailable = AttributedVolumeBundleResponse(
        volumes: [],
        failure: .localCapacityUnavailable
    )
    static let notSent = AttributedVolumeBundleResponse(volumes: [], failure: .notSent)

    public init(
        volumes: [AttributedVolumeResponse],
        noBundle: Bool = false,
        ended: Bool = false,
        failure: VolumeFetchFailure? = nil
    ) {
        self.volumes = volumes
        self.noBundle = noBundle
        self.ended = ended
        self.failure = failure
    }

    var single: AttributedVolumeResponse {
        volumes.first ?? AttributedVolumeResponse(
            rootCID: "",
            entries: [:],
            servedBy: nil,
            failure: failure
        )
    }
}

struct VolumeArchive {
    let entries: [ContentEntry]
    let data: Data

    static func encode(
        entries: [ContentEntry],
        rootCID: String
    ) -> VolumeArchive? {
        guard !entries.isEmpty,
              entries.count <= Int(MessageLimits.maxVolumeEntryCount) else {
            return nil
        }
        var remainingBytes = MessageLimits.maxVolumeArchiveBytes - 2
        for entry in entries {
            guard MessageLimits.accepts(entry.cid) else {
                return nil
            }
            let metadataBytes = 2 + entry.cid.utf8.count + 4
            guard metadataBytes <= remainingBytes,
                  entry.data.count <= remainingBytes - metadataBytes else {
                return nil
            }
            remainingBytes -= metadataBytes + entry.data.count
        }
        let encodedBytes = MessageLimits.maxVolumeArchiveBytes - remainingBytes
        let entries = entries.sorted { $0.cid < $1.cid }
        guard entries.contains(where: { $0.cid == rootCID }) else { return nil }
        var previous: String?
        var data = Data(capacity: encodedBytes)
        guard data.appendCount(
            entries.count,
            max: MessageLimits.maxVolumeEntryCount
        ) else { return nil }
        for entry in entries {
            guard previous.map({ $0 < entry.cid }) ?? true,
                  data.appendLengthPrefixedString(entry.cid),
                  data.appendLengthPrefixedData(
                    entry.data,
                    maxDataPayload: UInt32(MessageLimits.maxVolumeArchiveBytes)
                  ) else {
                return nil
            }
            previous = entry.cid
        }
        return VolumeArchive(entries: entries, data: data)
    }

    static func decode(
        _ data: Data,
        rootCID: String,
        expectedEntries: UInt16
    ) -> [ContentEntry]? {
        guard !data.isEmpty,
              data.count <= MessageLimits.maxVolumeArchiveBytes else { return nil }
        var reader = DataReader(
            data,
            maxDataPayload: UInt32(MessageLimits.maxVolumeArchiveBytes)
        )
        guard let count = reader.readUInt16(),
              count == expectedEntries,
              count > 0 else { return nil }
        var entries: [ContentEntry] = []
        entries.reserveCapacity(Int(count))
        var previous: String?
        var containsRoot = false
        for _ in 0..<count {
            guard let cid = reader.readString(),
                  let bytes = reader.readData(),
                  MessageLimits.accepts(cid),
                  previous.map({ $0 < cid }) ?? true else { return nil }
            containsRoot = containsRoot || cid == rootCID
            entries.append(ContentEntry(cid: cid, data: bytes))
            previous = cid
        }
        return containsRoot && reader.remaining == 0 ? entries : nil
    }
}
