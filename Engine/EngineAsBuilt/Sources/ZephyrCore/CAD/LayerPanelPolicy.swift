import Foundation

/// Pixel math for the Layers panel: toolbar metrics, wrapping, and the
/// row cell zones shared by drawing, hit-testing, and the rename field.
/// Pure values derived from the ImGui frame height so the layout scales
/// with the UI scale and is testable without a draw list.
public struct LayerPanelPolicy: Equatable, Sendable {
    /// Scale factor relative to the 22px baseline frame height.
    public var scale: Float
    /// The frame height the policy was derived from.
    public var frameHeight: Float

    public init(frameHeight: Float) {
        self.frameHeight = max(frameHeight, 1)
        self.scale = max(frameHeight / 22.0, 0.5)
    }

    /// Square toolbar icon button size.
    public var toolbarButtonSize: Float { 28 * scale }

    /// Horizontal stride between toolbar buttons (size + gap).
    public var toolbarButtonStride: Float { toolbarButtonSize + 4 * scale }

    /// Extra gap inserted between toolbar groups.
    public var toolbarGroupGap: Float { 10 * scale }

    /// Layer row height (frame height plus icon breathing room).
    public var rowHeight: Float { frameHeight + 4 * scale }

    /// Icon glyph size inside rows and toolbar buttons.
    public var rowIconSize: Float { 16 * scale }

    /// Row cell boundaries, as x offsets from the row's left edge:
    /// `status | eye | swatch | name … indicators | props`.
    public struct RowZones: Equatable, Sendable {
        public var statusEnd: Float
        public var eyeEnd: Float
        public var swatchEnd: Float
        public var nameStart: Float
        public var propsWidth: Float
        public var indicatorWidth: Float
        public var swatchRect: (x0: Float, x1: Float)

        public init(
            statusEnd: Float, eyeEnd: Float, swatchEnd: Float,
            nameStart: Float, propsWidth: Float, indicatorWidth: Float,
            swatchRect: (x0: Float, x1: Float)
        ) {
            self.statusEnd = statusEnd
            self.eyeEnd = eyeEnd
            self.swatchEnd = swatchEnd
            self.nameStart = nameStart
            self.propsWidth = propsWidth
            self.indicatorWidth = indicatorWidth
            self.swatchRect = swatchRect
        }

        public static func == (lhs: RowZones, rhs: RowZones) -> Bool {
            lhs.statusEnd == rhs.statusEnd
                && lhs.eyeEnd == rhs.eyeEnd
                && lhs.swatchEnd == rhs.swatchEnd
                && lhs.nameStart == rhs.nameStart
                && lhs.propsWidth == rhs.propsWidth
                && lhs.indicatorWidth == rhs.indicatorWidth
                && lhs.swatchRect.x0 == rhs.swatchRect.x0
                && lhs.swatchRect.x1 == rhs.swatchRect.x1
        }
    }

    public var rowZones: RowZones {
        let s = scale
        return RowZones(
            statusEnd: 20 * s,
            eyeEnd: 44 * s,
            swatchEnd: 64 * s,
            nameStart: 70 * s,
            propsWidth: 34 * s,
            indicatorWidth: 20 * s,
            swatchRect: (x0: 48 * s, x1: 58 * s))
    }

    /// How many toolbar buttons fit in the given width (at least one).
    public func toolbarColumns(availableWidth: Float) -> Int {
        guard toolbarButtonStride > 0 else { return 1 }
        let fit = Int((availableWidth + 4 * scale) / toolbarButtonStride)
        return max(fit, 1)
    }

    /// Rows needed to flow `count` buttons at `columns` per row.
    public static func wrapRows(count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        return (count + columns - 1) / columns
    }
}
