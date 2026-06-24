//
//  Exceptions.swift
//
//
//  Created by Christian Treffs on 26.10.19.
//

// Conversion process is not perfect yet so we have a small list of exceptions
public enum Exceptions {
    /// Set of missing functions that are not exposed to Swift automatically,
    /// but are present in definitions.json
    ///
    /// causes "Use of unresolved identifier '...'" compiler error.
    public static let unresolvedIdentifier: Set<String> = [
        "igErrorCheckEndFrameRecover",
        "igImFontAtlasBuildMultiplyCalcLookupTable",
        "igImFontAtlasBuildMultiplyRectAlpha8",
        "igImFontAtlasBuildRender1bppRectFromString",
        "igImTriangleBarycentricCoords",
        "igDockBuilderCopyDockSpace",
        "igSetAllocatorFunctions",
        "ImBitArray_ClearAllBits",
        "ImBitArray_ClearBit",
        "ImBitArray_SetAllBits",
        "ImBitArray_SetBit",
        "ImBitArray_SetBitRange",
        "ImBitArray_TestBit",
        "ImChunkStream_clear",
        "ImChunkStream_empty",
        "ImChunkStream_size",
        "ImChunkStream_swap",
        "ImGuiFreeType_DebugEditFontLoaderFlags",
        "ImGuiFreeType_GetFontLoader",
        "ImGuiTextRange_empty",
        "ImGuiTextRange_empty_Nil",
        "ImGuiTextRange_split",
        "ImGuiTextRange_ImGuiTextRange_Nil",
        "ImGuiTextRange_ImGuiTextRange_Str",
        "ImGuiTextRange_destroy",
        "ImPool_Clear",
        "ImPool_GetAliveCount",
        "ImPool_GetBufSize",
        "ImPool_GetMapSize",
        "ImPool_GetSize",
        "ImPool_Remove_PoolIdx",
        "ImPool_RemovePoolIdx",
        "ImPool_Reserve",
        "ImSpan_size",
        "ImSpan_size_in_bytes",
        "ImSpanAllocator_GetArenaSizeInBytes",
        "ImSpanAllocator_GetSpanPtrBegin",
        "ImSpanAllocator_GetSpanPtrEnd",
        "ImSpanAllocator_Reserve",
        "ImSpanAllocator_SetArenaBasePtr",
        "ImStableVector_clear",
        "ImStableVector_empty",
        "ImStableVector_pop_back",
        "ImStableVector_push_back",
        "ImStableVector_reserve",
        "ImStableVector_resize",
        "ImStableVector_size",
        "ImStableVector_size_in_bytes",
        "ImVector__grow_capacity",
        "ImVector_capacity",
        "ImVector_clear",
        "ImVector_clear_delete",
        "ImVector_clear_destruct",
        "ImVector_empty",
        "ImVector_max_size",
        "ImVector_pop_back",
        "ImVector_reserve",
        "ImVector_reserve_discard",
        "ImVector_resize_Nil",
        "ImVector_resizeNil",
        "ImVector_shrink",
        "ImVector_size",
        "ImVector_size_in_bytes",
        "ImVector_swap",
    ]

    /// causes "Use of undeclared type '...'" compiler error.
    public static let undeclardTypes: [String: Declaration] = [
        "ImBitArray": Declaration(name: "ImBitArray", typealiasType: "OpaquePointer"),
        "ImChunkStream": Declaration(name: "ImChunkStream", typealiasType: "OpaquePointer"),
        "ImGuiFreeTypeLoaderFlags": Declaration(name: "ImGuiFreeTypeLoaderFlags", typealiasType: "OpaquePointer"),
        "ImGuiTextRange": Declaration(name: "ImGuiTextRange", typealiasType: "OpaquePointer"),
        "ImPool": Declaration(name: "ImPool", typealiasType: "OpaquePointer"),
        "ImSpanAllocator": Declaration(name: "ImSpanAllocator", typealiasType: "OpaquePointer"),
        "ImStableVector": Declaration(name: "ImStableVector", typealiasType: "OpaquePointer"),
        "ImVector__charPtr": Declaration(name: "ImVector__charPtr", typealiasType: "OpaquePointer"),
    ]

    public static let stripPrefix: Set<String> = [
        "ig",
    ]
}

public struct Declaration {
    public let name: String
    public let typealiasType: String
    public var dataType: DataType {
        DataType(meta: .primitive, type: .custom(name), isConst: true)
    }
}

extension Declaration: Equatable {}
extension Declaration: Hashable {}
