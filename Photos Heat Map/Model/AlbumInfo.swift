//
//  AlbumInfo.swift
//  Photos Heat Map
//

import Foundation

/// Value-type description of a PHAssetCollection (or the whole library).
struct AlbumInfo: Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable {
        case library
        case smart
        case user
        case shared
    }

    /// `PHAssetCollection.localIdentifier`, or `AlbumInfo.libraryID` for the whole library.
    let id: String
    let title: String
    let kind: Kind
    /// Number of images + videos in the album (nil for the whole library).
    let count: Int?
    /// Whether assets can be added to it (regular user albums only).
    let canAddContent: Bool

    static let libraryID = "__entire_library__"

    static let entireLibrary = AlbumInfo(id: libraryID, title: "All Photos", kind: .library, count: nil, canAddContent: false)

    var isEntireLibrary: Bool { id == Self.libraryID }
}
