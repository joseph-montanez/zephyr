//
//  Export.swift
//
//
//  Created by Christian Treffs on 26.10.19.
//

@_exported import CImGui

// MARK: - Type aliases for _c POD types (new cimgui ABI-safe convention)
// The new cimgui (2025+) emits _c-suffixed POD types (ImVec2_c, ImVec4_c, etc.)
// to avoid the MSVC/Clang ARM64 ABI bug with small float aggregates.
// The C++ imgui.h still uses ImVec2/ImVec4 with constructors internally.
// These aliases let existing Swift code use the familiar names.
public typealias ImVec2 = ImVec2_c
public typealias ImVec4 = ImVec4_c
public typealias ImRect = ImRect_c
public typealias ImColor = ImColor_c
