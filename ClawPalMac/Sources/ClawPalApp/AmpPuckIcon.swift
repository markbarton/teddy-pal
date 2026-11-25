import AppKit
import SwiftUI

/// Renders the Amp Puck image bundled in ClawPalMac.app (falling back to /Applications/Amp.app).
struct AmpPuckIcon: View {
    let size: CGFloat

    private static let cachedImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "AmpPuck", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        let appPath = "/Applications/Amp.app/Contents/Resources/PuckClassic.png"
        if FileManager.default.fileExists(atPath: appPath),
           let img = NSImage(contentsOfFile: appPath) {
            return img
        }
        return nil
    }()

    var body: some View {
        if let img = Self.cachedImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bolt.horizontal.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}
