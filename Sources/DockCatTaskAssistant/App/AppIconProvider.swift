import AppKit
import SwiftUI

@MainActor
enum AppIconProvider {
    static let applicationIconImage: NSImage? = {
        let renderer = ImageRenderer(content: AppIconArtwork(size: 1024))
        renderer.scale = 1
        return renderer.nsImage
    }()

    @MainActor
    static func dockArtworkView() -> some View {
        AppIconArtwork(size: 128)
    }
}

private struct AppIconArtwork: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.93, blue: 0.86),
                            Color(red: 0.88, green: 0.92, blue: 0.94),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            let imgName = "DashCatAvatar"
            if let url = Bundle.module.url(forResource: imgName, withExtension: "jpg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size * 0.78, height: size * 0.78)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.1, style: .continuous))
            } else {
                CatFaceView(state: .focus)
                    .frame(width: size * 0.58, height: size * 0.58)
            }
        }
        .frame(width: size, height: size)
    }
}
