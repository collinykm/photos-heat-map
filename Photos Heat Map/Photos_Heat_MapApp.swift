//
//  Photos_Heat_MapApp.swift
//  Photos Heat Map
//

import SwiftUI

@main
struct Photos_Heat_MapApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .windowToolbarStyle(.unified)
    }
}
