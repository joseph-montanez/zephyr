//
//  EngineTypes.swift
//  Zephyr
//
//  Extensive commentary added to ensure compliance with SOLID principles
//  and to document rendering/interactive system architectures.
//

import Foundation

// MARK: - Interactive Tool Modes

/// Represents the active interactive state of the CAD application.
/// By maintaining this as an independent, Sendable enum, we decouple the
/// view layer from the domain layer. The engine routes input events differently
/// depending on this mode.
public enum ToolMode: Int, CaseIterable {
    /// The user is passively selecting or panning the document. Click-and-drag
    /// invokes a selection marquee, while single clicks select entities.
    case select = 0
    
    /// The user is moving previously selected entities by a specific vector.
    /// In this mode, the first click establishes a base point, and the second
    /// click determines the translation vector.
    case move = 1
    
    /// The user is rotating previously selected entities around a specific origin.
    /// In this mode, the first click establishes the center of rotation, and
    /// subsequent tracking dynamically rotates the selection.
    case rotate = 2
    
    /// The user is uniformly scaling previously selected entities.
    /// The first click establishes the origin of scaling, and the distance of
    /// subsequent tracking establishes the scale factor.
    case scale = 3
    
    /// A human-readable label suitable for display in UI toolbars and status bars.
    public var label: String {
        switch self {
        case .select: return "Select"
        case .move: return "Move"
        case .rotate: return "Rotate"
        case .scale: return "Scale"
        }
    }
}

// MARK: - GPU Rendering Structures

/// Represents a single vertex in the GPU's vertex buffer.
/// It is critical that the memory layout of this struct aligns perfectly
/// with the vertex shader's expected input layout.
public struct CADVertex: Sendable {
    // -------------------------------------------------------------------------
    // Spatial Coordinates
    // -------------------------------------------------------------------------
    /// X coordinate in world-space or screen-space depending on the pipeline type.
    public var x: Float
    
    /// Y coordinate in world-space or screen-space.
    public var y: Float
    
    // -------------------------------------------------------------------------
    // Color Information (RGBA)
    // -------------------------------------------------------------------------
    /// Red color channel [0.0 - 1.0]
    public var r: Float
    
    /// Green color channel [0.0 - 1.0]
    public var g: Float
    
    /// Blue color channel [0.0 - 1.0]
    public var b: Float
    
    /// Alpha opacity channel [0.0 - 1.0]
    public var a: Float
    
    // -------------------------------------------------------------------------
    // Texture/AA Coordinates
    // -------------------------------------------------------------------------
    /// U texture coordinate (used for anti-aliasing distance field)
    public var u: Float
    
    /// V texture coordinate (used for anti-aliasing distance field)
    public var v: Float
    
    // -------------------------------------------------------------------------
    // Hit-Testing Metadata
    // -------------------------------------------------------------------------
    /// Entity index (0-based, dense array mapping). Used by the GPU ID-buffer 
    /// pick pass to determine which entity is under the cursor.
    /// 
    /// - Note: 0 is reserved for "no entity" (the background or an untargetable 
    ///   element like a grip line). Valid entity indices are >= 1.
    public var entityIndex: UInt32

    /// Initializes a vertex to be pushed into the GPU vertex buffer array.
    ///
    /// - Parameters:
    ///   - x: X coordinate (world space)
    ///   - y: Y coordinate (world space)
    ///   - r: Red color value (0.0 to 1.0)
    ///   - g: Green color value (0.0 to 1.0)
    ///   - b: Blue color value (0.0 to 1.0)
    ///   - a: Alpha opacity value (0.0 to 1.0)
    ///   - entityIndex: Target ID for the GPU picking buffer. Defaults to 0 (non-interactive).
    public init(x: Float, y: Float, r: Float, g: Float, b: Float, a: Float, u: Float = 0.0, v: Float = 0.0, entityIndex: UInt32 = 0) {
        self.x = x
        self.y = y
        self.r = r
        self.g = g
        self.b = b
        self.a = a
        self.u = u
        self.v = v
        self.entityIndex = entityIndex
    }
}

/// Identifies the distinct GPU pipeline configurations used by the rendering engine.
/// Each pipeline configures the GPU differently (e.g., topology type, antialiasing).
public enum CADPipelineType: Sendable {
    /// Renders standard solid 1px lines using `SDL_GPU_PRIMITIVETYPE_LINELIST`.
    case line
    
    /// Renders discrete points using `SDL_GPU_PRIMITIVETYPE_POINTLIST`.
    /// Used primarily for grips and construction nodes.
    case point
    
    /// Renders filled solid geometry using `SDL_GPU_PRIMITIVETYPE_TRIANGLELIST`.
    /// Used for thick lines, blocks, and filled polygons.
    case triangle
    
    /// Renders anti-aliased wide lines. This usually requires a specialized
    /// fragment shader that calculates signed distance to the line's center.
    case aaLine
}

/// Defines a distinct, contiguous draw call within the GPU pipeline.
/// When the renderer accumulates geometry, it groups vertices of the same pipeline
/// type together into batches to minimize expensive GPU state changes.
public struct CADDrawBatch: Sendable {
    /// The pipeline topology required to render this batch. 
    /// If the renderer encounters a batch with a different pipeline type than the
    /// currently bound pipeline, it will switch pipelines before drawing.
    public var pipelineType: CADPipelineType
    
    /// The starting index in the bound vertex buffer where this batch begins.
    public var firstVertex: UInt32
    
    /// The total number of vertices to consume in this draw call.
    public var vertexCount: UInt32
    /// Drawn only while the camera is actively panning.
    public var isPanProxy: Bool

    /// Initializes a new drawing batch.
    ///
    /// - Parameters:
    ///   - pipelineType: The topology required (line, point, triangle, etc.)
    ///   - firstVertex: Starting index in the global vertex array.
    ///   - vertexCount: Number of sequential vertices to draw.
    public init(
        pipelineType: CADPipelineType,
        firstVertex: UInt32,
        vertexCount: UInt32,
        isPanProxy: Bool = false
    ) {
        self.pipelineType = pipelineType
        self.firstVertex = firstVertex
        self.vertexCount = vertexCount
        self.isPanProxy = isPanProxy
    }
}
