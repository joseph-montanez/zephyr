// Sources/ZephyrCore/Commands/DimEditCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// DIMEDIT (DED) and DIMTEDIT, Phase 2.1: one command class with a mode
/// (mirroring DimChainCommand) because both edit existing dimension text
/// placement. DIMEDIT offers Home/New/Rotate/Oblique; DIMTEDIT offers
/// Home/New/Left/Right/Center/Angle.
///
/// Flow: adopt every dimension in the selection, or pick dimensions until
/// Enter; choose an option; type a value when the option needs one. Each
/// target persists with the PropertiesPanel pattern (updateDimensionBlock +
/// updateEntity, one undo entry per dimension).
///
/// Home and Left/Right/Center only support linear and aligned dimensions:
/// they recompute placement through the shared DimChainMath.continueNext
/// path, and other types have no central default-placement helper to reuse.
/// Skipped targets are reported, never silently dropped. Obliquing stores
/// radians-from-dimline in metadata.obliqueAngle (nil = perpendicular).
@MainActor
public final class DimEditCommand: FeatureCommand {

    public enum Mode {
        case dimedit
        case dimtedit
    }

    private enum Phase {
        case collect
        case option
        case value
    }

    private enum PendingOption {
        case home
        case newText
        case rotate
        case oblique
        case left
        case right
        case center
    }

    private let mode: Mode
    private var phase = Phase.collect
    private var targets: [UUID] = []
    private var pendingOption = PendingOption.home

    public init(mode: Mode) {
        self.mode = mode
    }

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .collect
        targets = []
        pendingOption = .home
        adoptSelectionDimensions(engine: engine)
        if targets.isEmpty {
            processor.commandPrompt = "Select dimensions (Enter when done):"
        } else {
            phase = .option
            processor.commandPrompt = optionPrompt()
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .collect else { return .continue }
        let hitHandle = engine.cadSelection.hitTest(
            worldX: worldX, worldY: worldY,
            document: engine.document,
            threshold: 12.0 / engine.camera.zoom)
        if let handle = hitHandle,
           let entity = engine.document.entity(for: handle),
           entity.dimensionMetadata != nil,
           !targets.contains(handle) {
            targets.append(handle)
        }
        processor.commandPrompt = targets.isEmpty
            ? "Select dimensions (Enter when done):"
            : "Select dimensions (\(targets.count) selected, Enter when done):"
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return handleEnter(engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .collect:
            if !trimmed.isEmpty { return .continue }
            return handleEnter(engine: engine, processor: processor)
        case .option:
            guard let option = parseOption(trimmed) else {
                processor.commandPrompt = optionPrompt()
                return .continue
            }
            switch option {
            case .home, .left, .right, .center:
                applyImmediate(option, engine: engine, processor: processor)
                return .finished
            case .newText, .rotate, .oblique:
                pendingOption = option
                phase = .value
                processor.commandPrompt = valuePrompt(for: option)
                return .continue
            }
        case .value:
            applyValue(trimmed, engine: engine, processor: processor)
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure edits (nonisolated: no actor state, test-callable)

    /// Nil unless the metadata is linear or aligned with both origins.
    nonisolated static func placementChain(
        for metadata: CADDimensionMetadata
    ) -> DimChainMath.ChainedDim? {
        guard metadata.type == .linearOrRotated || metadata.type == .aligned,
              let p2 = metadata.defPoint3 else {
            return nil
        }
        let source = DimChainMath.SourceChain(
            baseOrigin: metadata.defPoint2,
            prevOrigin: metadata.defPoint2,
            dimLinePos: metadata.defPoint,
            angle: metadata.rotationAngle,
            isLinear: metadata.type == .linearOrRotated)
        return DimChainMath.continueNext(from: source, picked: p2)
    }

    /// Home: default text midpoint plus the readable rotation. Nil for
    /// non-linear/aligned types.
    nonisolated static func homed(
        _ metadata: CADDimensionMetadata
    ) -> CADDimensionMetadata? {
        guard let chained = placementChain(for: metadata) else { return nil }
        var next = metadata
        next.textMidpoint = chained.textMidpoint
        next.textRotationAngle = nil
        return next
    }

    public enum Justification {
        case left
        case right
        case center
    }

    /// Left/Right/Center: text at the dimline start/end/middle. Nil for
    /// non-linear/aligned types.
    nonisolated static func justified(
        _ metadata: CADDimensionMetadata, _ justification: Justification
    ) -> CADDimensionMetadata? {
        guard let chained = placementChain(for: metadata) else { return nil }
        var next = metadata
        switch justification {
        case .left: next.textMidpoint = chained.dimStart
        case .right: next.textMidpoint = chained.dimEnd
        case .center: next.textMidpoint = chained.textMidpoint
        }
        return next
    }

    nonisolated static func withText(
        _ metadata: CADDimensionMetadata, _ text: String
    ) -> CADDimensionMetadata {
        var next = metadata
        next.textOverride = text
        return next
    }

    nonisolated static func withTextRotation(
        _ metadata: CADDimensionMetadata, radians: Double
    ) -> CADDimensionMetadata {
        var next = metadata
        next.textRotationAngle = radians
        return next
    }

    /// Nil clears back to perpendicular. Non-linear/aligned pass through
    /// unchanged (nil return) since only those types slant.
    nonisolated static func withOblique(
        _ metadata: CADDimensionMetadata, radians: Double?
    ) -> CADDimensionMetadata? {
        guard metadata.type == .linearOrRotated || metadata.type == .aligned else {
            return nil
        }
        var next = metadata
        if let radians, abs(radians - .pi / 2) > 1e-9 {
            next.obliqueAngle = radians
        } else {
            next.obliqueAngle = nil
        }
        return next
    }

    /// Strict degree value in typed input. Nil for anything unparseable.
    nonisolated static func parseAngleDegrees(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else {
            return nil
        }
        return value
    }

    // MARK: - Private

    private func adoptSelectionDimensions(engine: PhrostEngine) {
        for handle in engine.cadSelection.selectedHandles {
            guard let entity = engine.document.entity(for: handle),
                  entity.dimensionMetadata != nil,
                  !targets.contains(handle) else {
                continue
            }
            targets.append(handle)
        }
    }

    private func optionPrompt() -> String {
        switch mode {
        case .dimedit:
            return "Enter option [Home/New/Rotate/Oblique]:"
        case .dimtedit:
            return "Enter option [Home/New/Left/Right/Center/Angle]:"
        }
    }

    private func parseOption(_ text: String) -> PendingOption? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch mode {
        case .dimedit:
            switch key {
            case "H", "HOME": return .home
            case "N", "NEW": return .newText
            case "R", "ROTATE": return .rotate
            case "O", "OBLIQUE": return .oblique
            default: return nil
            }
        case .dimtedit:
            switch key {
            case "H", "HOME": return .home
            case "N", "NEW": return .newText
            case "L", "LEFT": return .left
            case "R", "RIGHT": return .right
            case "C", "CENTER": return .center
            case "A", "ANGLE": return .rotate
            default: return nil
            }
        }
    }

    private func valuePrompt(for option: PendingOption) -> String {
        switch option {
        case .newText:
            return "New dimension text (Enter to keep current):"
        case .rotate:
            return mode == .dimedit
                ? "Rotation angle in degrees (Enter to keep current):"
                : "Text angle in degrees (Enter to keep current):"
        case .oblique:
            return "Obliquing angle in degrees from dimension line, 90 is normal (Enter to keep current):"
        case .home, .left, .right, .center:
            return optionPrompt()
        }
    }

    private func handleEnter(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard phase == .collect else {
            processor.commandPrompt = optionPrompt()
            return .continue
        }
        guard !targets.isEmpty else { return .finished }
        phase = .option
        processor.commandPrompt = optionPrompt()
        return .continue
    }

    private func applyImmediate(
        _ option: PendingOption, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        var applied = 0
        var skipped = 0
        for handle in targets {
            guard let entity = engine.document.entity(for: handle),
                  let box = entity.dimensionMetadata else {
                skipped += 1
                continue
            }
            let next: CADDimensionMetadata?
            switch option {
            case .home:
                next = Self.homed(box.value)
            case .left:
                next = Self.justified(box.value, .left)
            case .right:
                next = Self.justified(box.value, .right)
            case .center:
                next = Self.justified(box.value, .center)
            case .newText, .rotate, .oblique:
                next = nil
            }
            guard let next else {
                skipped += 1
                continue
            }
            var updated = entity
            updated.dimensionMetadata = CADDimensionMetadataBox(next)
            DimensionPrimitives.updateDimensionBlock(for: &updated, in: engine.document)
            engine.document.updateEntity(updated)
            applied += 1
        }
        engine.tabManager.markActiveDirty()
        report(applied: applied, skipped: skipped, what: optionName(option), processor: processor)
    }

    private func applyValue(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Empty keeps the current value: nothing to change.
        if text.isEmpty {
            report(applied: 0, skipped: targets.count, what: optionName(pendingOption), processor: processor)
            return
        }
        var applied = 0
        var skipped = 0
        for handle in targets {
            guard let entity = engine.document.entity(for: handle),
                  let box = entity.dimensionMetadata else {
                skipped += 1
                continue
            }
            let next: CADDimensionMetadata?
            switch pendingOption {
            case .newText:
                next = Self.withText(box.value, text)
            case .rotate:
                guard let degrees = Self.parseAngleDegrees(text) else {
                    skipped += 1
                    continue
                }
                next = Self.withTextRotation(box.value, radians: degrees * .pi / 180.0)
            case .oblique:
                guard let degrees = Self.parseAngleDegrees(text) else {
                    skipped += 1
                    continue
                }
                next = Self.withOblique(box.value, radians: degrees * .pi / 180.0)
            case .home, .left, .right, .center:
                next = nil
            }
            guard let next else {
                skipped += 1
                continue
            }
            var updated = entity
            updated.dimensionMetadata = CADDimensionMetadataBox(next)
            DimensionPrimitives.updateDimensionBlock(for: &updated, in: engine.document)
            engine.document.updateEntity(updated)
            applied += 1
        }
        engine.tabManager.markActiveDirty()
        report(applied: applied, skipped: skipped, what: optionName(pendingOption), processor: processor)
    }

    private func optionName(_ option: PendingOption) -> String {
        switch option {
        case .home: return "Home"
        case .newText: return "New text"
        case .rotate: return mode == .dimedit ? "Rotate" : "Angle"
        case .oblique: return "Oblique"
        case .left: return "Left"
        case .right: return "Right"
        case .center: return "Center"
        }
    }

    private func report(applied: Int, skipped: Int, what: String, processor: CADCommandProcessor) {
        var message = "\(what) applied to \(applied) dimension(s)."
        if skipped > 0 {
            message += " \(skipped) skipped (linear/aligned only, or invalid input)."
        }
        print("[DIMEDIT] \(message)")
        processor.commandPrompt = message
    }
}
