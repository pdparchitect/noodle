import AppKit
import SwiftUI

/// Thumbnail only: fill the card, retaining the desktop's top-left origin.
/// The saved snapshot and the interactive preview remain uncropped.
struct ComputerPreviewImage: View {
    let image: NSImage
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
    }
}
