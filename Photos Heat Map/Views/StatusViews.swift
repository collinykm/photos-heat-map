//
//  StatusViews.swift
//  Photos Heat Map
//
//  Loading / permission / summary screens.
//

import SwiftUI
import AppKit
import Photos

struct ScanningView: View {
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(progress.scanned), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
            if progress.total == 0 {
                Text("Reading the Photos library…")
            } else {
                Text("Scanning \(progress.scanned, format: .number) of \(progress.total, format: .number) items…")
                Text("\(progress.found, format: .number) geotagged so far")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AccessDeniedView: View {
    let status: PHAuthorizationStatus

    var body: some View {
        ContentUnavailableView {
            Label("Photos access needed", systemImage: "lock.shield")
        } description: {
            Text(message)
        } actions: {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var message: String {
        switch status {
        case .restricted:
            return "Access to Photos is restricted on this Mac."
        case .denied:
            return "Allow Photos Heat Map to access your Photos library in System Settings › Privacy & Security › Photos, then relaunch the app."
        default:
            return "Grant access to your Photos library to continue."
        }
    }
}

/// Small summary line shown once the scan finished.
struct LibrarySummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
            Text("\(model.allAssets.count, format: .number) geotagged")
            Text("(\(model.imageCount, format: .number) photos, \(model.videoCount, format: .number) videos) of \(model.librarySize, format: .number) items")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .lineLimit(1)
    }
}
