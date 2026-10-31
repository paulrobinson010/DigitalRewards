import SwiftUI

/// The pixel alien from the app icon, drawn from the same 11 × 8 grid as `Branding/app-icon.svg`.
struct PixelAlien: View {
    static let sprite = ["X.........X",
                         ".X.......X.",
                         "..XXXXXXX..",
                         ".XX.XXX.XX.",
                         "XXXXXXXXXXX",
                         "XX.XXXXX.XX",
                         "XXX.....XXX",
                         ".X.X...X.X."]
    /// Second animation frame: the legs step the other way.
    static let spriteAlt = ["X.........X",
                            ".X.......X.",
                            "..XXXXXXX..",
                            ".XX.XXX.XX.",
                            "XXXXXXXXXXX",
                            "XX.XXXXX.XX",
                            "XXX.....XXX",
                            "X.X.....X.X"]

    var color: Color = Theme.green
    /// Alternate the leg frames, like the arcade original.
    var animated = false
    var glow: CGFloat = 8

    var body: some View {
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: 0.45)) { context in
                    let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2
                    AlienCanvas(rows: frame == 0 ? Self.sprite : Self.spriteAlt, color: color)
                }
            } else {
                AlienCanvas(rows: Self.sprite, color: color)
            }
        }
        .aspectRatio(11.0 / 8.0, contentMode: .fit)
        .neonGlow(color, radius: glow)
        .accessibilityHidden(true)
    }
}

private struct AlienCanvas: View {
    let rows: [String]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let columns = rows.first?.count ?? 1
            let px = min(size.width / CGFloat(columns), size.height / CGFloat(rows.count))
            let x0 = (size.width - px * CGFloat(columns)) / 2
            let y0 = (size.height - px * CGFloat(rows.count)) / 2
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() where ch == "X" {
                    // A hair of overlap so neighbouring pixels don't show seams.
                    let rect = CGRect(x: x0 + CGFloat(c) * px, y: y0 + CGFloat(r) * px,
                                      width: px + 0.5, height: px + 0.5)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
