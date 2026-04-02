import Foundation
import SwiftUI

let compactDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
}()

@MainActor let taskDetailDrawerAnimation = Animation.easeOut(duration: 0.16)
@MainActor let taskDetailDrawerTransition = AnyTransition.move(edge: .trailing).combined(with: .opacity)

struct CatFaceView: View {
    let state: PetVisualState

    var body: some View {
        ZStack {
            ear(offsetX: -28)
            ear(offsetX: 28)

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(furColor)
                .frame(width: 78, height: 64)

            HStack(spacing: 20) {
                eye
                eye
            }
            .offset(y: -4)

            VStack(spacing: 5) {
                Circle()
                    .fill(Color(red: 0.35, green: 0.19, blue: 0.17))
                    .frame(width: 10, height: 8)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addCurve(
                        to: CGPoint(x: 18, y: 0),
                        control1: CGPoint(x: 5, y: 8),
                        control2: CGPoint(x: 13, y: 8)
                    )
                }
                .stroke(Color(red: 0.31, green: 0.18, blue: 0.16), lineWidth: 2)
                .frame(width: 18, height: 8)
            }
            .offset(y: 13)

            if state == .focus {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.yellow.opacity(0.88))
                    .frame(width: 40, height: 8)
                    .offset(y: 42)
            }
        }
        .scaleEffect(state == .celebrate ? 1.05 : 1.0)
        .rotationEffect(.degrees(state == .alert ? -4 : 0))
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private var eye: some View {
        Group {
            if state == .idle {
                Capsule()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: 12, height: 3)
            } else {
                Circle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: 9, height: 9)
            }
        }
    }

    private func ear(offsetX: CGFloat) -> some View {
        Triangle()
            .fill(furColor)
            .frame(width: 24, height: 22)
            .offset(x: offsetX, y: -30)
    }

    private var furColor: Color {
        switch state {
        case .celebrate:
            Color(red: 0.22, green: 0.28, blue: 0.43)
        case .alert:
            Color(red: 0.26, green: 0.22, blue: 0.2)
        default:
            Color(red: 0.13, green: 0.14, blue: 0.16)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

struct TaskHeaderBlock<Title: View, Badges: View>: View {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6
    let title: Title
    let badges: Badges

    init(
        spacing: CGFloat = 8,
        rowSpacing: CGFloat = 6,
        @ViewBuilder title: () -> Title,
        @ViewBuilder badges: () -> Badges
    ) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.title = title()
        self.badges = badges()
    }

    var body: some View {
        TitleBadgeFlowLayout(spacing: spacing, rowSpacing: rowSpacing) {
            title
            badges
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TitleBadgeFlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measuredSize(in: CGRect(origin: .zero, size: CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: proposal.height ?? .greatestFiniteMagnitude)), subviews: subviews, place: false)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        _ = measuredSize(in: bounds, subviews: subviews, place: true)
    }

    private func measuredSize(in bounds: CGRect, subviews: Subviews, place: Bool) -> CGSize {
        let maxWidth = max(bounds.width, 1)
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)

            if index == 0, size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }

            if cursorX > bounds.minX, cursorX + size.width > bounds.minX + maxWidth {
                cursorX = bounds.minX
                cursorY += lineHeight + rowSpacing
                lineHeight = 0
            }

            if place {
                subview.place(
                    at: CGPoint(x: cursorX, y: cursorY),
                    proposal: ProposedViewSize(width: min(size.width, maxWidth), height: size.height)
                )
            }

            measuredWidth = max(measuredWidth, cursorX - bounds.minX + size.width)
            cursorX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: measuredWidth, height: (cursorY - bounds.minY) + lineHeight)
    }
}

struct BadgeFlow<Content: View>: View {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6
    let content: Content

    init(
        spacing: CGFloat = 6,
        rowSpacing: CGFloat = 6,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.content = content()
    }

    var body: some View {
        BadgeFlowLayout(spacing: spacing, rowSpacing: rowSpacing) {
            content
        }
    }
}

private struct BadgeFlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if cursorX > 0, cursorX + size.width > maxWidth {
                cursorX = 0
                cursorY += lineHeight + rowSpacing
                lineHeight = 0
            }

            measuredWidth = max(measuredWidth, cursorX + size.width)
            lineHeight = max(lineHeight, size.height)
            cursorX += size.width + spacing
        }

        return CGSize(
            width: measuredWidth,
            height: cursorY + lineHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if cursorX > bounds.minX, cursorX + size.width > bounds.minX + maxWidth {
                cursorX = bounds.minX
                cursorY += lineHeight + rowSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: cursorX, y: cursorY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            cursorX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

enum TaskBoardPalette {
    static let canvas = Color(red: 0.93, green: 0.92, blue: 0.88)
    static let canvasAlt = Color(red: 0.88, green: 0.91, blue: 0.93)
    static let paper = Color(red: 0.98, green: 0.94, blue: 0.72)
    static let paperSoft = Color(red: 0.98, green: 0.97, blue: 0.92)
    static let paperRose = Color(red: 0.98, green: 0.93, blue: 0.9)
    static let ink = Color(red: 0.14, green: 0.14, blue: 0.16)
    static let accent = Color(red: 0.18, green: 0.39, blue: 0.34)
    static let accentWarm = Color(red: 0.8, green: 0.55, blue: 0.19)
    static let line = Color.black.opacity(0.08)
    static let urgent = Color(red: 0.84, green: 0.34, blue: 0.25)
    static let important = Color(red: 0.83, green: 0.58, blue: 0.21)
    static let quiet = Color(red: 0.38, green: 0.48, blue: 0.62)
}

struct PaperCard<Content: View>: View {
    var tint: Color = TaskBoardPalette.paperSoft
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 18
    let content: Content

    init(
        tint: Color = TaskBoardPalette.paperSoft,
        cornerRadius: CGFloat = 24,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(TaskBoardPalette.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 20, x: 0, y: 10)
    }
}

struct CatAvatarView: View {
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let image = AppIconProvider.applicationIconImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size * 1.22, height: size * 1.22)
            } else {
                CatFaceView(state: .idle)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

func formatDate(_ date: Date?) -> String {
    guard let date else { return "未设置" }
    return compactDateFormatter.string(from: date)
}

func formatPercentage(_ value: Double) -> String {
    String(format: "%.2f%%", PriorityVector.clampedPercentage(value))
}

func urgencyColor(for value: Double) -> Color {
    let ratio = PriorityVector.clampedPercentage(value) / 100
    return Color(
        red: 0.66 + (0.2 * ratio),
        green: 0.6 - (0.26 * ratio),
        blue: 0.35 - (0.16 * ratio)
    )
}

func importanceColor(for value: Double) -> Color {
    let ratio = PriorityVector.clampedPercentage(value) / 100
    return Color(
        red: 0.52 + (0.24 * ratio),
        green: 0.55 + (0.12 * ratio),
        blue: 0.28 - (0.12 * ratio)
    )
}
