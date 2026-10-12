//
//  ContentView.swift
//  Photos Heat Map
//

import SwiftUI
import Photos

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .requestingAccess:
                ProgressView("Requesting access to Photos…")
            case .accessDenied(let status):
                AccessDeniedView(status: status)
            case .scanning(let progress):
                ScanningView(progress: progress)
            case .failed(let message):
                ContentUnavailableView("Couldn't read the library",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .ready:
                readyContent
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { model.startIfNeeded() }
    }

    // Stage 1: just show what was found. Later stages replace this with the map + grid.
    private var readyContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            LibrarySummaryView()
            Button("Rescan Library") { model.reload() }
        }
        .padding()
    }
}
