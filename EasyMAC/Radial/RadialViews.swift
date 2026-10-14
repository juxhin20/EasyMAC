import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class RadialModel {
    var direction: RadialDirection = .center
    var centerHasAction = true
    var accent: Color = .accentColor
    /// Accumulated (unwrapped) angle so the highlight always rotates the short way round.
    var highlightAngle: Double = 0
    var appeared = false

    func set(_ new: RadialDirection) {
        guard new != direction else { return }
        if let target = new.angle {
            // SwiftUI angles grow clockwise; maths angles grow counter-clockwise.
            let screenAngle = -target
            if direction == .center {
                highlightAngle = screenAngle
            } else {
                var delta = (screenAngle - highlightAngle).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                highlightAngle += delta
            }
        }
        direction = new
    }
}

/// The donut shown at the cursor, with the chosen direction lit up — like Loop.
struct RadialRingView: View {
    let model: RadialModel
    static let diameter: CGFloat = 92
    static let thickness: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.regularMaterial, lineWidth: Self.thickness)
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: Self.thickness)
                .blendMode(.overlay)

            if model.direction == .center {
                if model.centerHasAction {
                    Circle()
                        .strokeBorder(model.accent, lineWidth: Self.thickness)
                        .transition(.opacity)
                }
            } else {
                Circle()
                    .inset(by: Self.thickness / 2)
                    .trim(from: 0, to: 0.125)
                    .stroke(model.accent, style: StrokeStyle(lineWidth: Self.thickness, lineCap: .butt))
                    .rotationEffect(.degrees(model.highlightAngle - 22.5))
                    .transition(.opacity)
            }

            Circle()
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            Circle()
                .inset(by: Self.thickness)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .scaleEffect(model.appeared ? 1 : 0.6)
        .opacity(model.appeared ? 1 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.highlightAngle)
        .animation(.easeOut(duration: 0.12), value: model.direction)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.appeared)
        .frame(width: Self.diameter + 40, height: Self.diameter + 40)
    }
}

/// Frosted rectangle with an accent border showing where the window will land.
struct SnapPreviewView: View {
    let accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(accent.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent, lineWidth: 3)
            }
    }
}
