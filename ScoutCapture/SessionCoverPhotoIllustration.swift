import SwiftUI

/// A decorative report-cover illustration shared by the initial session prompts.
struct SessionCoverPhotoIllustration: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 300, size.height / 200)
            let origin = CGPoint(x: (size.width - 300 * scale) / 2, y: (size.height - 200 * scale) / 2)
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: scale, y: scale)
            let line = StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
            let ink = GraphicsContext.Shading.color(.primary.opacity(0.88))
            let accent = GraphicsContext.Shading.color(.cyan)

            context.stroke(Path(roundedRect: CGRect(x: 5, y: 5, width: 290, height: 190), cornerRadius: 18), with: ink, style: line)

            var house = Path()
            house.move(to: CGPoint(x: 39, y: 94))
            for point in [CGPoint(x: 39, y: 84), CGPoint(x: 150, y: 28), CGPoint(x: 261, y: 84), CGPoint(x: 261, y: 94), CGPoint(x: 150, y: 39), CGPoint(x: 39, y: 94)] {
                house.addLine(to: point)
            }
            house.move(to: CGPoint(x: 57, y: 92))
            house.addLine(to: CGPoint(x: 57, y: 171))
            house.move(to: CGPoint(x: 243, y: 92))
            house.addLine(to: CGPoint(x: 243, y: 171))
            house.move(to: CGPoint(x: 204, y: 54))
            for point in [CGPoint(x: 204, y: 30), CGPoint(x: 223, y: 30), CGPoint(x: 223, y: 64)] {
                house.addLine(to: point)
            }
            house.addRect(CGRect(x: 75, y: 100, width: 31, height: 36))
            house.addRect(CGRect(x: 194, y: 100, width: 31, height: 36))
            house.addRect(CGRect(x: 132, y: 102, width: 36, height: 62))
            house.addRect(CGRect(x: 124, y: 164, width: 52, height: 9))
            house.move(to: CGPoint(x: 29, y: 173))
            house.addLine(to: CGPoint(x: 271, y: 173))
            house.addEllipse(in: CGRect(x: 156, y: 131, width: 3, height: 3))
            context.stroke(house, with: ink, style: line)

            var bushes = Path()
            bushes.move(to: CGPoint(x: 25, y: 172))
            bushes.addQuadCurve(to: CGPoint(x: 40, y: 153), control: CGPoint(x: 20, y: 153))
            bushes.addCurve(to: CGPoint(x: 69, y: 153), control1: CGPoint(x: 39, y: 136), control2: CGPoint(x: 68, y: 136))
            bushes.addQuadCurve(to: CGPoint(x: 82, y: 172), control: CGPoint(x: 86, y: 151))
            bushes.move(to: CGPoint(x: 218, y: 172))
            bushes.addQuadCurve(to: CGPoint(x: 233, y: 153), control: CGPoint(x: 213, y: 153))
            bushes.addCurve(to: CGPoint(x: 262, y: 153), control1: CGPoint(x: 232, y: 136), control2: CGPoint(x: 261, y: 136))
            bushes.addQuadCurve(to: CGPoint(x: 275, y: 172), control: CGPoint(x: 279, y: 151))
            context.stroke(bushes, with: ink, style: line)

            var highlights = Path()
            highlights.move(to: CGPoint(x: 49, y: 88))
            highlights.addLine(to: CGPoint(x: 150, y: 37))
            highlights.addLine(to: CGPoint(x: 251, y: 88))
            for x in [75.0, 194.0] {
                highlights.move(to: CGPoint(x: x + 2, y: 118))
                highlights.addLine(to: CGPoint(x: x + 29, y: 118))
                highlights.move(to: CGPoint(x: x + 15.5, y: 102))
                highlights.addLine(to: CGPoint(x: x + 15.5, y: 134))
            }
            context.stroke(highlights, with: accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
