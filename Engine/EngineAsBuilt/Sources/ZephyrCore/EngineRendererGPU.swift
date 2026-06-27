import Foundation
import SwiftSDL
import SwiftSDL_ttf
import ImGui

// Some SDL C enum cases disappear from unqualified lookup in optimized
// Windows builds. Construct the typed values from SDL_gpu.h raw values.
private let gpuTextureFormatInvalid = SDL_GPUTextureFormat(rawValue: 0)
private let gpuTextureFormatRGBA8UNorm = SDL_GPUTextureFormat(rawValue: 4)
private let gpuTextureFormatR32UInt = SDL_GPUTextureFormat(rawValue: 40)
private let gpuTextureType2D = SDL_GPUTextureType(rawValue: 0)
private let gpuSampleCount1 = SDL_GPUSampleCount(rawValue: 0)

// =========================================================================
// MARK: - EngineRendererGPU
//
// GPU resource creation and destruction for the EngineRenderer. Handles:
//   - Shader loading (MSL on Apple, DXIL on Windows)
//   - Graphics pipeline creation (CAD lines, points, triangles, AA,
//     ID-buffer for entity picking)
//   - ImGui rendering pipeline
//   - Texture upload to GPU
//   - Resource cleanup
//
// All methods are instance methods on EngineRenderer because they depend on
// `engine.gpuDevice` and write to the renderer's pipeline/shader handles.
// This file is separated from the main render loop for readability — the
// pipeline setup is ~250 lines of dense SDL_gpu boilerplate.
// =========================================================================

extension EngineRenderer {

    // MARK: - GPU Shader Loading

    /// Loads a compiled GPU shader from the app bundle. The shader file is
    /// expected at `{basePath}/{name}.msl` (macOS/iOS) or `.dxil` (Windows).
    ///
    /// - Parameters:
    ///   - name: Shader file name without extension.
    ///   - stage: Vertex or fragment shader stage.
    ///   - samplerCount: Number of samplers used by the shader.
    ///   - uniformBufferCount: Number of uniform buffers.
    ///   - storageBufferCount: Number of storage buffers.
    ///   - storageTextureCount: Number of storage textures.
    /// - Returns: The compiled shader handle, or nil on failure.
    internal func loadGPUShader(
        name: String,
        stage: SDL_GPUShaderStage,
        samplerCount: UInt32 = 0,
        uniformBufferCount: UInt32 = 0,
        storageBufferCount: UInt32 = 0,
        storageTextureCount: UInt32 = 0
    ) -> OpaquePointer? {
        guard let basePathPtr = SDL_GetBasePath() else {
            print("Failed to get base path for loading shader: \(name)")
            return nil
        }
        let basePath = String(cString: basePathPtr)

        #if os(macOS) || os(iOS)
        let fileExt = ".msl"
        let shaderFormat = SDL_GPU_SHADERFORMAT_MSL
        let entrypoint = "main0"
        #else
        let fileExt = ".dxil"
        let shaderFormat = SDL_GPU_SHADERFORMAT_DXIL
        let entrypoint = "main"
        #endif

        let filePath = basePath + name + fileExt

        var codeSize = 0
        guard let code = SDL_LoadFile(filePath, &codeSize) else {
            print("Failed to load shader file: \(filePath), error: \(String(cString: SDL_GetError()))")
            return nil
        }
        defer { SDL_free(code) }

        let codePtr = code.bindMemory(to: UInt8.self, capacity: codeSize)
        let codeBuf = UnsafeBufferPointer(start: codePtr, count: codeSize)
        let entrypointBytes = entrypoint.utf8CString

        var shaderInfo = SDL_GPUShaderCreateInfo(
            code_size: codeSize,
            code: codeBuf.baseAddress,
            entrypoint: entrypointBytes.withUnsafeBufferPointer(\.baseAddress),
            format: shaderFormat,
            stage: stage,
            num_samplers: samplerCount,
            num_storage_textures: storageTextureCount,
            num_storage_buffers: storageBufferCount,
            num_uniform_buffers: uniformBufferCount,
            props: 0
        )

        let shader = SDL_CreateGPUShader(engine.gpuDevice, &shaderInfo)
        return shader
    }

    // MARK: - GPU Pipeline Initialization

    /// Creates all GPU pipelines: CAD geometry pipelines (lines, points,
    /// triangles, anti-aliased variants), ImGui pipeline, and ID-buffer
    /// pipeline for GPU-based entity picking.
    ///
    /// - Returns: `true` if all required pipelines were created successfully.
    internal func initGPUPipelines() -> Bool {
        // Load shaders
        cadVertShader = loadGPUShader(name: "cad.vert", stage: SDL_GPU_SHADERSTAGE_VERTEX, uniformBufferCount: 1, storageBufferCount: 0)
        cadFragShader = loadGPUShader(name: "cad.frag", stage: SDL_GPU_SHADERSTAGE_FRAGMENT)
        cadAAFragShader = loadGPUShader(name: "cad_aa.frag", stage: SDL_GPU_SHADERSTAGE_FRAGMENT)
        imguiVertShader = loadGPUShader(name: "imgui.vert", stage: SDL_GPU_SHADERSTAGE_VERTEX, uniformBufferCount: 1)
        imguiFragShader = loadGPUShader(name: "imgui.frag", stage: SDL_GPU_SHADERSTAGE_FRAGMENT, samplerCount: 1)

        guard cadVertShader != nil, cadFragShader != nil, cadAAFragShader != nil,
              imguiVertShader != nil, imguiFragShader != nil else {
            print("Failed to load shaders.")
            return false
        }

        let swapchainFormat = SDL_GetGPUSwapchainTextureFormat(engine.gpuDevice, engine.window)

        // --- Create Sampler ---
        var samplerInfo = SDL_GPUSamplerCreateInfo()
        samplerInfo.min_filter = SDL_GPU_FILTER_LINEAR
        samplerInfo.mag_filter = SDL_GPU_FILTER_LINEAR
        samplerInfo.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR
        samplerInfo.address_mode_u = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE
        samplerInfo.address_mode_v = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE
        samplerInfo.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE
        samplerInfo.mip_lod_bias = 0.0
        samplerInfo.max_anisotropy = 1.0
        samplerInfo.compare_op = SDL_GPU_COMPAREOP_NEVER
        samplerInfo.min_lod = 0.0
        samplerInfo.max_lod = 1000.0
        samplerInfo.props = 0
        fontSampler = SDL_CreateGPUSampler(engine.gpuDevice, &samplerInfo)
        if fontSampler == nil {
            print("Failed to create GPU sampler, error: \(String(cString: SDL_GetError()))")
            return false
        }

        // --- Blend state (shared by CAD and ImGui) ---
        var blendState = SDL_GPUColorTargetBlendState()
        blendState.src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA
        blendState.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA
        blendState.color_blend_op = SDL_GPU_BLENDOP_ADD
        blendState.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA
        blendState.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA
        blendState.alpha_blend_op = SDL_GPU_BLENDOP_ADD
        blendState.color_write_mask = 0xF
        blendState.enable_blend = true
        blendState.enable_color_write_mask = true

        // --- CAD Pipelines ---
        guard createCADPipelines(swapchainFormat: swapchainFormat, blendState: blendState) else {
            return false
        }

        // --- ID-Buffer Pipeline (GPU entity picking) ---
        createIDBufferPipeline()

        // --- ImGui Pipeline ---
        guard createImGuiPipeline(swapchainFormat: swapchainFormat, blendState: blendState) else {
            return false
        }

        return true
    }

    /// Creates the CAD geometry pipelines: line-list, point-list, triangle-list,
    /// and anti-aliased triangle-list variants.
    private func createCADPipelines(
        swapchainFormat: SDL_GPUTextureFormat,
        blendState: SDL_GPUColorTargetBlendState
    ) -> Bool {
        let cadColorDesc = SDL_GPUColorTargetDescription(
            format: swapchainFormat,
            blend_state: blendState
        )
        var cadColorDescs = [cadColorDesc]

        // Vertex attributes for CADVertex (stride = 36 with entityIndex, u, v)
        let cadAttributes = [
            SDL_GPUVertexAttribute(location: 0, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, offset: 0),
            SDL_GPUVertexAttribute(location: 1, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, offset: 8),
            SDL_GPUVertexAttribute(location: 2, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_UINT, offset: 32),
            SDL_GPUVertexAttribute(location: 3, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, offset: 24)
        ]
        let cadBindings = [
            SDL_GPUVertexBufferDescription(slot: 0, pitch: 36, input_rate: SDL_GPU_VERTEXINPUTRATE_VERTEX, instance_step_rate: 0)
        ]

        let success = cadAttributes.withUnsafeBufferPointer { attrBuf in
            cadBindings.withUnsafeBufferPointer { bindBuf in
                cadColorDescs.withUnsafeMutableBufferPointer { colorBuf in

                    let vertexInput = SDL_GPUVertexInputState(
                        vertex_buffer_descriptions: bindBuf.baseAddress,
                        num_vertex_buffers: 1,
                        vertex_attributes: attrBuf.baseAddress,
                        num_vertex_attributes: 4
                    )

                    let targetInfo = SDL_GPUGraphicsPipelineTargetInfo(
                        color_target_descriptions: colorBuf.baseAddress,
                        num_color_targets: 1,
                        depth_stencil_format: gpuTextureFormatInvalid,
                        has_depth_stencil_target: false,
                        padding1: 0, padding2: 0, padding3: 0
                    )

                    let rasterizer = SDL_GPURasterizerState(
                        fill_mode: SDL_GPU_FILLMODE_FILL,
                        cull_mode: SDL_GPU_CULLMODE_NONE,
                        front_face: SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
                        depth_bias_constant_factor: 0, depth_bias_clamp: 0,
                        depth_bias_slope_factor: 0, enable_depth_bias: false,
                        enable_depth_clip: false, padding1: 0, padding2: 0
                    )
                    let multisample = SDL_GPUMultisampleState(
                        sample_count: gpuSampleCount1, sample_mask: 0,
                        enable_mask: false, enable_alpha_to_coverage: false,
                        padding2: 0, padding3: 0
                    )
                    let depthStencil = SDL_GPUDepthStencilState(
                        compare_op: SDL_GPU_COMPAREOP_NEVER,
                        back_stencil_state: SDL_GPUStencilOpState(
                            fail_op: SDL_GPU_STENCILOP_KEEP, pass_op: SDL_GPU_STENCILOP_KEEP,
                            depth_fail_op: SDL_GPU_STENCILOP_KEEP, compare_op: SDL_GPU_COMPAREOP_NEVER),
                        front_stencil_state: SDL_GPUStencilOpState(
                            fail_op: SDL_GPU_STENCILOP_KEEP, pass_op: SDL_GPU_STENCILOP_KEEP,
                            depth_fail_op: SDL_GPU_STENCILOP_KEEP, compare_op: SDL_GPU_COMPAREOP_NEVER),
                        compare_mask: 0, write_mask: 0,
                        enable_depth_test: false, enable_depth_write: false,
                        enable_stencil_test: false,
                        padding1: 0, padding2: 0, padding3: 0
                    )

                    var pipelineCreateInfo = SDL_GPUGraphicsPipelineCreateInfo(
                        vertex_shader: cadVertShader,
                        fragment_shader: cadFragShader,
                        vertex_input_state: vertexInput,
                        primitive_type: SDL_GPU_PRIMITIVETYPE_LINELIST,
                        rasterizer_state: rasterizer,
                        multisample_state: multisample,
                        depth_stencil_state: depthStencil,
                        target_info: targetInfo,
                        props: 0
                    )

                    cadLinePipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &pipelineCreateInfo)

                    pipelineCreateInfo.primitive_type = SDL_GPU_PRIMITIVETYPE_POINTLIST
                    cadPointPipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &pipelineCreateInfo)

                    pipelineCreateInfo.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST
                    cadTrianglePipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &pipelineCreateInfo)

                    // AA pipelines — use cad_aa.frag, TRIANGLELIST only
                    pipelineCreateInfo.fragment_shader = cadAAFragShader
                    pipelineCreateInfo.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST
                    cadLineAAPipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &pipelineCreateInfo)
                    cadTriangleAAPipeline = cadLineAAPipeline

                    return cadLinePipeline != nil && cadPointPipeline != nil
                        && cadTrianglePipeline != nil && cadLineAAPipeline != nil
                }
            }
        }

        guard success else {
            print("Failed to create CAD pipelines, error: \(String(cString: SDL_GetError()))")
            return false
        }
        return true
    }

    /// Creates the ID-buffer pipeline for GPU-based entity picking. Renders
    /// into a 9×9 R32_UINT texture where each pixel stores the entity index.
    /// A ring buffer of 3 transfer buffers enables async readback without
    /// CPU stalls.
    private func createIDBufferPipeline() {
        cadIDVertShader = loadGPUShader(name: "cad_id.vert", stage: SDL_GPU_SHADERSTAGE_VERTEX, uniformBufferCount: 1, storageBufferCount: 0)
        cadIDFragShader = loadGPUShader(name: "cad_id.frag", stage: SDL_GPU_SHADERSTAGE_FRAGMENT)

        guard cadIDVertShader != nil, cadIDFragShader != nil else { return }

        // No blending — just write entity index as uint
        var idBlendState = SDL_GPUColorTargetBlendState()
        idBlendState.enable_blend = false
        idBlendState.enable_color_write_mask = true
        idBlendState.color_write_mask = 0xF

        let idColorDesc = SDL_GPUColorTargetDescription(
            format: gpuTextureFormatR32UInt,
            blend_state: idBlendState
        )
        var idColorDescs = [idColorDesc]

        // Same vertex layout as main CAD pipeline (stride=36)
        let idAttributes = [
            SDL_GPUVertexAttribute(location: 0, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, offset: 0),
            SDL_GPUVertexAttribute(location: 1, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, offset: 8),
            SDL_GPUVertexAttribute(location: 2, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_UINT, offset: 32),
            SDL_GPUVertexAttribute(location: 3, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, offset: 24)
        ]
        let idBindings = [
            SDL_GPUVertexBufferDescription(slot: 0, pitch: 36, input_rate: SDL_GPU_VERTEXINPUTRATE_VERTEX, instance_step_rate: 0)
        ]

        let idSuccess = idAttributes.withUnsafeBufferPointer { attrBuf in
            idBindings.withUnsafeBufferPointer { bindBuf in
                idColorDescs.withUnsafeMutableBufferPointer { colorBuf in
                    let vertexInput = SDL_GPUVertexInputState(
                        vertex_buffer_descriptions: bindBuf.baseAddress,
                        num_vertex_buffers: 1,
                        vertex_attributes: attrBuf.baseAddress,
                        num_vertex_attributes: 4
                    )
                    let targetInfo = SDL_GPUGraphicsPipelineTargetInfo(
                        color_target_descriptions: colorBuf.baseAddress,
                        num_color_targets: 1,
                        depth_stencil_format: gpuTextureFormatInvalid,
                        has_depth_stencil_target: false,
                        padding1: 0, padding2: 0, padding3: 0
                    )

                    let rasterizer = SDL_GPURasterizerState(
                        fill_mode: SDL_GPU_FILLMODE_FILL, cull_mode: SDL_GPU_CULLMODE_NONE,
                        front_face: SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
                        depth_bias_constant_factor: 0, depth_bias_clamp: 0,
                        depth_bias_slope_factor: 0, enable_depth_bias: false,
                        enable_depth_clip: false, padding1: 0, padding2: 0
                    )
                    let multisample = SDL_GPUMultisampleState(
                        sample_count: gpuSampleCount1, sample_mask: 0,
                        enable_mask: false, enable_alpha_to_coverage: false,
                        padding2: 0, padding3: 0
                    )
                    let depthStencil = SDL_GPUDepthStencilState(
                        compare_op: SDL_GPU_COMPAREOP_NEVER,
                        back_stencil_state: SDL_GPUStencilOpState(
                            fail_op: SDL_GPU_STENCILOP_KEEP, pass_op: SDL_GPU_STENCILOP_KEEP,
                            depth_fail_op: SDL_GPU_STENCILOP_KEEP, compare_op: SDL_GPU_COMPAREOP_NEVER),
                        front_stencil_state: SDL_GPUStencilOpState(
                            fail_op: SDL_GPU_STENCILOP_KEEP, pass_op: SDL_GPU_STENCILOP_KEEP,
                            depth_fail_op: SDL_GPU_STENCILOP_KEEP, compare_op: SDL_GPU_COMPAREOP_NEVER),
                        compare_mask: 0, write_mask: 0,
                        enable_depth_test: false, enable_depth_write: false,
                        enable_stencil_test: false,
                        padding1: 0, padding2: 0, padding3: 0
                    )

                    var pipelineCreateInfo = SDL_GPUGraphicsPipelineCreateInfo(
                        vertex_shader: cadIDVertShader,
                        fragment_shader: cadIDFragShader,
                        vertex_input_state: vertexInput,
                        primitive_type: SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
                        rasterizer_state: rasterizer,
                        multisample_state: multisample,
                        depth_stencil_state: depthStencil,
                        target_info: targetInfo,
                        props: 0
                    )
                    cadIDPipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &pipelineCreateInfo)

                    // Line-list variant for thin lines
                    var linePipelineInfo = pipelineCreateInfo
                    linePipelineInfo.primitive_type = SDL_GPU_PRIMITIVETYPE_LINELIST
                    cadIDLinePipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &linePipelineInfo)

                    // Point-list variant
                    var pointPipelineInfo = pipelineCreateInfo
                    pointPipelineInfo.primitive_type = SDL_GPU_PRIMITIVETYPE_POINTLIST
                    cadIDPointPipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &pointPipelineInfo)

                    return cadIDPipeline != nil
                }
            }
        }

        if !idSuccess {
            print("Warning: Failed to create CAD ID pipeline: \(String(cString: SDL_GetError()))")
            cadIDPipeline = nil
        }

        // Allocate 9×9 pick texture (R32_UINT format)
        var pickTexInfo = SDL_GPUTextureCreateInfo()
        pickTexInfo.type = gpuTextureType2D
        pickTexInfo.format = gpuTextureFormatR32UInt
        pickTexInfo.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET
        pickTexInfo.width = 9
        pickTexInfo.height = 9
        pickTexInfo.layer_count_or_depth = 1
        pickTexInfo.num_levels = 1
        pickTexInfo.sample_count = gpuSampleCount1
        pickTexture = SDL_CreateGPUTexture(engine.gpuDevice, &pickTexInfo)
        if pickTexture == nil {
            print("Warning: Failed to create pick texture: \(String(cString: SDL_GetError()))")
        }

        // Allocate 3 ring-buffer transfer buffers for async readback (9×9×4 = 324 bytes each)
        let pickBytes = UInt32(9 * 9 * 4)
        for i in 0..<3 {
            var transferInfo = SDL_GPUTransferBufferCreateInfo()
            transferInfo.usage = SDL_GPUTransferBufferUsage(rawValue: 1)
            transferInfo.size = pickBytes
            pickRingBuffers[i] = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &transferInfo)
        }
    }

    /// Creates the ImGui rendering pipeline with the standard ImDrawVert
    /// vertex layout (20-byte stride: float2 pos, float2 uv, ubyte4 color).
    private func createImGuiPipeline(
        swapchainFormat: SDL_GPUTextureFormat,
        blendState: SDL_GPUColorTargetBlendState
    ) -> Bool {
        let imguiColorDesc = SDL_GPUColorTargetDescription(
            format: swapchainFormat,
            blend_state: blendState
        )
        var imguiColorDescs = [imguiColorDesc]

        let imguiAttributes = [
            SDL_GPUVertexAttribute(location: 0, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, offset: 0),
            SDL_GPUVertexAttribute(location: 1, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, offset: 8),
            SDL_GPUVertexAttribute(location: 2, buffer_slot: 0, format: SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, offset: 16)
        ]
        let imguiBindings = [
            SDL_GPUVertexBufferDescription(slot: 0, pitch: 20, input_rate: SDL_GPU_VERTEXINPUTRATE_VERTEX, instance_step_rate: 0)
        ]

        let imguiSuccess = imguiAttributes.withUnsafeBufferPointer { attrBuf in
            imguiBindings.withUnsafeBufferPointer { bindBuf in
                imguiColorDescs.withUnsafeMutableBufferPointer { colorBuf in

                    let vertexInput = SDL_GPUVertexInputState(
                        vertex_buffer_descriptions: bindBuf.baseAddress,
                        num_vertex_buffers: 1,
                        vertex_attributes: attrBuf.baseAddress,
                        num_vertex_attributes: 3
                    )

                    let targetInfo = SDL_GPUGraphicsPipelineTargetInfo(
                        color_target_descriptions: colorBuf.baseAddress,
                        num_color_targets: 1,
                        depth_stencil_format: gpuTextureFormatInvalid,
                        has_depth_stencil_target: false,
                        padding1: 0, padding2: 0, padding3: 0
                    )

                    let rasterizer = SDL_GPURasterizerState(
                        fill_mode: SDL_GPU_FILLMODE_FILL, cull_mode: SDL_GPU_CULLMODE_NONE,
                        front_face: SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
                        depth_bias_constant_factor: 0, depth_bias_clamp: 0,
                        depth_bias_slope_factor: 0, enable_depth_bias: false,
                        enable_depth_clip: false, padding1: 0, padding2: 0
                    )
                    let multisample = SDL_GPUMultisampleState(
                        sample_count: gpuSampleCount1, sample_mask: 0,
                        enable_mask: false, enable_alpha_to_coverage: false,
                        padding2: 0, padding3: 0
                    )
                    let depthStencil = SDL_GPUDepthStencilState(
                        compare_op: SDL_GPU_COMPAREOP_NEVER,
                        back_stencil_state: SDL_GPUStencilOpState(
                            fail_op: SDL_GPU_STENCILOP_KEEP, pass_op: SDL_GPU_STENCILOP_KEEP,
                            depth_fail_op: SDL_GPU_STENCILOP_KEEP, compare_op: SDL_GPU_COMPAREOP_NEVER),
                        front_stencil_state: SDL_GPUStencilOpState(
                            fail_op: SDL_GPU_STENCILOP_KEEP, pass_op: SDL_GPU_STENCILOP_KEEP,
                            depth_fail_op: SDL_GPU_STENCILOP_KEEP, compare_op: SDL_GPU_COMPAREOP_NEVER),
                        compare_mask: 0, write_mask: 0,
                        enable_depth_test: false, enable_depth_write: false,
                        enable_stencil_test: false,
                        padding1: 0, padding2: 0, padding3: 0
                    )

                    var pipelineCreateInfo = SDL_GPUGraphicsPipelineCreateInfo(
                        vertex_shader: imguiVertShader,
                        fragment_shader: imguiFragShader,
                        vertex_input_state: vertexInput,
                        primitive_type: SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
                        rasterizer_state: rasterizer,
                        multisample_state: multisample,
                        depth_stencil_state: depthStencil,
                        target_info: targetInfo,
                        props: 0
                    )

                    imguiPipeline = SDL_CreateGPUGraphicsPipeline(engine.gpuDevice, &pipelineCreateInfo)
                    return imguiPipeline != nil
                }
            }
        }

        guard imguiSuccess else {
            print("Failed to create ImGui pipeline, error: \(String(cString: SDL_GetError()))")
            return false
        }
        return true
    }

    // MARK: - GPU Texture Upload

    /// Uploads raw RGBA8 pixel data to a new GPU texture.
    ///
    /// - Parameters:
    ///   - width: Texture width in pixels.
    ///   - height: Texture height in pixels.
    ///   - pixelData: Pointer to RGBA8 pixel data (4 bytes per pixel).
    /// - Returns: The GPU texture handle, or nil on failure.
    internal func uploadToGPUTexture(
        width: Int32, height: Int32, pixelData: UnsafeRawPointer
    ) -> OpaquePointer? {
        var texCreateInfo = SDL_GPUTextureCreateInfo()
        texCreateInfo.type = gpuTextureType2D
        texCreateInfo.format = gpuTextureFormatRGBA8UNorm
        texCreateInfo.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER
        texCreateInfo.width = UInt32(width)
        texCreateInfo.height = UInt32(height)
        texCreateInfo.layer_count_or_depth = 1
        texCreateInfo.num_levels = 1
        texCreateInfo.sample_count = gpuSampleCount1

        let texture = SDL_CreateGPUTexture(engine.gpuDevice, &texCreateInfo)
        if texture == nil {
            print("Failed to create GPU texture, error: \(String(cString: SDL_GetError()))")
            return nil
        }

        let sizeInBytes = UInt32(width * height * 4)
        var bufferCreateInfo = SDL_GPUTransferBufferCreateInfo()
        bufferCreateInfo.usage = SDL_GPUTransferBufferUsage(rawValue: 0)
        bufferCreateInfo.size = sizeInBytes

        let transferBuf = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &bufferCreateInfo)
        if transferBuf == nil {
            print("Failed to create transfer buffer, error: \(String(cString: SDL_GetError()))")
            SDL_ReleaseGPUTexture(engine.gpuDevice, texture)
            return nil
        }

        let mapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, transferBuf, false)
        if mapped == nil {
            print("Failed to map transfer buffer, error: \(String(cString: SDL_GetError()))")
            SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
            SDL_ReleaseGPUTexture(engine.gpuDevice, texture)
            return nil
        }
        memcpy(mapped, pixelData, Int(sizeInBytes))
        SDL_UnmapGPUTransferBuffer(engine.gpuDevice, transferBuf)

        guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) else {
            print("Failed to acquire command buffer for texture upload")
            SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
            SDL_ReleaseGPUTexture(engine.gpuDevice, texture)
            return nil
        }

        let copyPass = SDL_BeginGPUCopyPass(cmd)
        if copyPass == nil {
            print("Failed to begin copy pass, error: \(String(cString: SDL_GetError()))")
            SDL_CancelGPUCommandBuffer(cmd)
            SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
            SDL_ReleaseGPUTexture(engine.gpuDevice, texture)
            return nil
        }

        var sourceInfo = SDL_GPUTextureTransferInfo()
        sourceInfo.transfer_buffer = transferBuf
        sourceInfo.offset = 0
        sourceInfo.pixels_per_row = UInt32(width)
        sourceInfo.rows_per_layer = UInt32(height)

        var destRegion = SDL_GPUTextureRegion()
        destRegion.texture = texture
        destRegion.w = UInt32(width)
        destRegion.h = UInt32(height)
        destRegion.d = 1

        SDL_UploadToGPUTexture(copyPass, &sourceInfo, &destRegion, false)
        SDL_EndGPUCopyPass(copyPass)

        if !SDL_SubmitGPUCommandBuffer(cmd) {
            print("Failed to submit command buffer for texture upload")
            SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
            SDL_ReleaseGPUTexture(engine.gpuDevice, texture)
            return nil
        }

        SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
        return texture
    }

    // MARK: - Cleanup

    /// Performs all GPU resource cleanup. Called from `deinit` via
    /// `MainActor.assumeIsolated`.
    internal func performCleanup() {
        print("Cleaning up Zephyr...")

        // Destroy all cached textures (deduplicate pointers)
        var releasedTextures = Set<OpaquePointer>()
        for texture in engine.textureManager.textureCache.values {
            if let texture = texture, releasedTextures.insert(texture).inserted {
                SDL_ReleaseGPUTexture(engine.gpuDevice, texture)
            }
        }

        // Clean up Font Cache (deduplicate pointers)
        var closedFonts = Set<OpaquePointer>()
        for font in engine.fontCache.values {
            if let font = font, closedFonts.insert(font).inserted {
                TTF_CloseFont(font)
            }
        }
        engine.fontCache.removeAll()

        // Release pipelines, shaders, sampler
        if let p = cadLinePipeline { SDL_ReleaseGPUGraphicsPipeline(engine.gpuDevice, p) }
        if let p = cadPointPipeline { SDL_ReleaseGPUGraphicsPipeline(engine.gpuDevice, p) }
        if let p = cadTrianglePipeline { SDL_ReleaseGPUGraphicsPipeline(engine.gpuDevice, p) }
        if let p = cadLineAAPipeline { SDL_ReleaseGPUGraphicsPipeline(engine.gpuDevice, p) }
        if let p = imguiPipeline { SDL_ReleaseGPUGraphicsPipeline(engine.gpuDevice, p) }
        if let s = cadVertShader { SDL_ReleaseGPUShader(engine.gpuDevice, s) }
        if let s = cadFragShader { SDL_ReleaseGPUShader(engine.gpuDevice, s) }
        if let s = cadAAFragShader { SDL_ReleaseGPUShader(engine.gpuDevice, s) }
        if let s = imguiVertShader { SDL_ReleaseGPUShader(engine.gpuDevice, s) }
        if let s = imguiFragShader { SDL_ReleaseGPUShader(engine.gpuDevice, s) }
        if let s = fontSampler { SDL_ReleaseGPUSampler(engine.gpuDevice, s) }

        // Release engine.fontTexture
        if let tex = engine.fontTexture { SDL_ReleaseGPUTexture(engine.gpuDevice, tex) }

        // Cancel async vertex-buffer build
        _vbBuildTask?.cancel()

        // Release CAD vertex buffer
        if let buf = cadVertexBuffer { SDL_ReleaseGPUBuffer(engine.gpuDevice, buf) }
        if let buf = imguiVertexBuffer { SDL_ReleaseGPUBuffer(engine.gpuDevice, buf) }
        if let buf = imguiIndexBuffer { SDL_ReleaseGPUBuffer(engine.gpuDevice, buf) }

        ImGuiDestroyContext(engine.ctx)
        SDL_ReleaseWindowFromGPUDevice(engine.gpuDevice, engine.window)
        SDL_DestroyGPUDevice(engine.gpuDevice)
        SDL_DestroyWindow(engine.window)
        TTF_Quit()
        SDL_Quit()
        print("Zephyr Cleaned up.")
    }
}
