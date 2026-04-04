import SwiftUI

struct LoadingView: View {
    var progress: Double = 0.0
    var showsProgressBar: Bool = true
    var showsLogo: Bool = true

    private var backgroundColor: Color {
        .black
    }

    private var logoName: String {
        "ScoutCaptureLogoWhite"
    }

    private var trackColor: Color {
        Color.white.opacity(0.20)
    }

    private var fillColor: Color {
        Color.white.opacity(0.96)
    }

    var body: some View {
        GeometryReader { proxy in
            let logoWidth = max(proxy.size.width - 32, 0)
            let logoHeight = logoWidth * (238.0 / 772.0)
            let progressOffsetY = showsLogo ? (logoHeight / 2.0) + 18.0 : 0
            ZStack {
                backgroundColor
                    .ignoresSafeArea()

                if showsLogo {
                    Image(logoName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoWidth)
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)
                        .frame(height: 6)

                    GeometryReader { barProxy in
                        Capsule()
                            .fill(fillColor)
                            .frame(width: max(0, min(1, progress)) * barProxy.size.width, height: 6)
                    }
                }
                .frame(width: min(proxy.size.width * 0.56, 260), height: 6)
                .offset(y: progressOffsetY)
                .opacity(showsProgressBar ? 1 : 0)
                .accessibilityLabel("Loading progress")
                .accessibilityValue("In progress")
            }
        }
    }
}
