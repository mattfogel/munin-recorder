import SwiftUI

/// Audio levels for mic and system sources
struct AudioLevels: Equatable {
    var micLevel: Float = 0
    var systemLevel: Float = 0

    static let zero = AudioLevels()
}

/// VU meter bars showing audio levels
/// 4 bars total: 2 for mic (left), 2 for system (right)
struct AudioLevelView: View {
    let levels: AudioLevels

    // Smoothed values for animation
    @State private var displayedMicLevel: Float = 0
    @State private var displayedSystemLevel: Float = 0

    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 2

    var body: some View {
        HStack(spacing: barSpacing) {
            // Mic bars (left pair)
            levelBar(level: displayedMicLevel)
            levelBar(level: displayedMicLevel * 0.85) // Slightly lower for visual interest

            Spacer()
                .frame(width: 4)

            // System bars (right pair)
            levelBar(level: displayedSystemLevel * 0.85)
            levelBar(level: displayedSystemLevel)
        }
        .onChange(of: levels) { _, newLevels in
            withAnimation(.linear(duration: 0.05)) {
                displayedMicLevel = newLevels.micLevel
                displayedSystemLevel = newLevels.systemLevel
            }
        }
    }

    @ViewBuilder
    private func levelBar(level: Float) -> some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let fillHeight = CGFloat(level) * height

            ZStack(alignment: .bottom) {
                // Background
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.1))

                // Filled portion with gradient
                if fillHeight > 0 {
                    levelGradient(level: level)
                        .frame(height: max(fillHeight, cornerRadius * 2))
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
        }
        .frame(width: barWidth)
    }

    private func levelGradient(level: Float) -> some View {
        // Green -> Yellow -> Red gradient based on level
        LinearGradient(
            stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: 0.5),
                .init(color: .yellow, location: 0.7),
                .init(color: .orange, location: 0.85),
                .init(color: .red, location: 1.0)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

/// Compact horizontal VU meter for tight spaces
struct AudioLevelBarHorizontal: View {
    let level: Float
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = CGFloat(level) * width

            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.1))

                // Filled portion
                if fillWidth > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(levelColor(for: level, tint: tint))
                        .frame(width: max(fillWidth, 4))
                }
            }
        }
        .frame(height: 4)
    }

    private func levelColor(for level: Float, tint: Color) -> Color {
        if level > 0.9 {
            return .red
        } else if level > 0.7 {
            return .orange
        } else {
            return tint
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AudioLevelView(levels: AudioLevels(micLevel: 0.6, systemLevel: 0.4))
            .frame(width: 40, height: 30)
            .padding()
            .background(Color.black)

        AudioLevelBarHorizontal(level: 0.7, tint: .green)
            .frame(width: 100)
            .padding()
            .background(Color.black)
    }
}
