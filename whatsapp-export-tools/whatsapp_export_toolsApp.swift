//
//  whatsapp_export_toolsApp.swift
//  whatsapp-export-tools
//
//  Created by Marcel Mißbach on 04.01.26.
//

import SwiftUI

@main
struct whatsapp_export_toolsApp: App {
    var body: some Scene {
        WindowGroup("WhatsApp Export Tools") {
            Group {
                if WETReplaceSelectionCheck.isEnabled {
                    Text("Running WET replace selection check…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding()
                } else if AIGlowSnapshotRunner.isEnabled {
                    AIGlowSnapshotView(isRunning: false)
                } else {
                    ContentView()
                }
            }
            .onAppear {
                WETReplaceSelectionCheck.runIfNeeded()
                AIGlowSnapshotRunner.runIfNeeded()
            }
        }
        .defaultSize(width: 980, height: 780)
    }
}
