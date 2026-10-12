//
//  SourcePickers.swift
//  Photos Heat Map
//
//  Toolbar menus for choosing the Photos library and the album.
//
//  Library selection is a PhotoKit limitation, not an app limitation: PhotoKit
//  can only open the *System* Photo Library. There is no public API to open an
//  arbitrary .photoslibrary bundle, so instead of faking it the menu explains
//  how to switch the system library in Photos and offers to open Photos.
//

import SwiftUI
import AppKit

struct LibraryMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Toggle(isOn: .constant(true)) {
                Label("System Photo Library", systemImage: "photo.on.rectangle")
            }
            .disabled(true)

            Divider()

            Text("PhotoKit can only read the System Photo Library.")
            Text("To use another library: open it in Photos, then")
            Text("Photos › Settings › General › Use as System Photo Library,")
            Text("and press Rescan here.")

            Divider()

            Button("Open Photos…") {
                let url = URL(fileURLWithPath: "/System/Applications/Photos.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            Button("Rescan Library") { model.reload() }
                .disabled(model.isScanning)
        } label: {
            Label("Library", systemImage: "photo.on.rectangle")
        }
        .help("Which Photos library is shown")
    }
}

struct AlbumMenu: View {
    @Environment(AppModel.self) private var model

    private func items(_ kind: AlbumInfo.Kind) -> [AlbumInfo] {
        model.albums.filter { $0.kind == kind }
    }

    var body: some View {
        Menu {
            albumToggle(.entireLibrary)

            let smart = items(.smart)
            if !smart.isEmpty {
                Section("Smart Albums") {
                    ForEach(smart) { albumToggle($0) }
                }
            }
            let user = items(.user)
            if !user.isEmpty {
                Section("My Albums") {
                    ForEach(user) { albumToggle($0) }
                }
            }
            let shared = items(.shared)
            if !shared.isEmpty {
                Section("Shared Albums") {
                    ForEach(shared) { albumToggle($0) }
                }
            }
        } label: {
            Label(model.selectedAlbum.title, systemImage: model.selectedAlbum.isEntireLibrary ? "photo.stack" : "rectangle.stack")
        }
        .help("Album shown on the heat map")
    }

    private func albumToggle(_ album: AlbumInfo) -> some View {
        Toggle(isOn: Binding(
            get: { model.selectedAlbum == album },
            set: { on in
                if on { Task { await model.selectAlbum(album) } }
            }
        )) {
            if let count = album.count {
                Text("\(album.title)  (\(count.formatted()))")
            } else {
                Text(album.title)
            }
        }
    }
}
