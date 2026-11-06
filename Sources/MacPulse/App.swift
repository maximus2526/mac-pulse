import AppKit
import SwiftUI

@main
struct MacPulseApp: App {
    @StateObject private var monitor = Monitor.shared

    init() {
        // Debug: MACPULSE_SNAPSHOT=/dir renders the popover to PNGs after a few samples and quits.
        if let dir = ProcessInfo.processInfo.environment["MACPULSE_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                let m = Monitor.shared
                for (name, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
                    for id in [MetricID.cpu, .network] {
                        m.selected = id
                        let v = PopoverView().environmentObject(m).environment(\.colorScheme, scheme)
                            .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.95))
                        let r = ImageRenderer(content: v); r.scale = 2
                        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "\(dir)/popover-\(name)-\(id.rawValue).png"))
                        }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(monitor)
        } label: {
            Image(nsImage: monitor.menuImage)
        }
        .menuBarExtraStyle(.window)
    }
}
