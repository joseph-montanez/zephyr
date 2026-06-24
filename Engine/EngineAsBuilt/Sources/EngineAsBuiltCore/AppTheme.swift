import Foundation
import SwiftSDL
import ImGui

@MainActor
public struct AppTheme {
    // MARK: - Core Colors
    public let viewportBg: SDL_FColor
    
    // MARK: - Window & Panel
    public let topChromeBg: ImVec4
    public let tabBarBg: ImVec4
    public let panelBg: ImVec4
    public let panelBgDim: ImVec4
    public let windowBg: ImVec4 // for properties/command line
    
    // MARK: - Text
    public let textPrimary: ImVec4
    public let textDim: ImVec4
    public let textIcon: ImVec4
    public let textAccent: ImVec4
    
    // MARK: - Accents
    public let brandGold: ImVec4
    public let brandGoldHover: ImVec4
    public let brandGoldActive: ImVec4
    public let rowHoverText: ImVec4
    
    // MARK: - Borders & Separators
    public let border: ImVec4
    public let borderDim: ImVec4
    
    // MARK: - macOS Window Controls
    public let macClose: ImVec4
    public let macCloseHover: ImVec4
    public let macMin: ImVec4
    public let macMinHover: ImVec4
    public let macMax: ImVec4
    public let macMaxHover: ImVec4
    
    // MARK: - Interactive
    public let hoverBg: ImVec4 // For lists and panels
    public let activeBg: ImVec4 // Selected items
    public let commandRowHighlight: ImVec4 // Command palette hover/selection
    public let dangerBg: ImVec4 // For close buttons
    
    // Pre-defined Dark Theme
    public static let dark = AppTheme(
        viewportBg: SDL_FColor(r: 0.043, g: 0.098, b: 0.145, a: 1.0), // deep navy #0B1925
        topChromeBg: ImVec4(x: 0.086, y: 0.208, z: 0.302, w: 1.00),
        tabBarBg: ImVec4(x: 0.063, y: 0.169, z: 0.255, w: 1.00), // #102B41
        panelBg: ImVec4(x: 0.086, y: 0.208, z: 0.302, w: 1.00), // #16354D
        panelBgDim: ImVec4(x: 0.086, y: 0.208, z: 0.302, w: 0.95),
        windowBg: ImVec4(x: 0.086, y: 0.208, z: 0.302, w: 1.00),
        
        textPrimary: ImVec4(x: 0.85, y: 0.90, z: 0.95, w: 1.00),
        textDim: ImVec4(x: 0.60, y: 0.70, z: 0.80, w: 1.00),
        textIcon: ImVec4(x: 0.90, y: 0.90, z: 0.90, w: 1.00),
        textAccent: ImVec4(x: 0.38, y: 0.62, z: 0.80, w: 1.00), // A lighter blue for the category number
        
        brandGold: ImVec4(x: 0.98, y: 0.73, z: 0.01, w: 1.00),
        brandGoldHover: ImVec4(x: 1.00, y: 0.80, z: 0.10, w: 1.00),
        brandGoldActive: ImVec4(x: 0.88, y: 0.63, z: 0.00, w: 1.00),
        rowHoverText: ImVec4(x: 0.043, y: 0.098, z: 0.145, w: 1.00),
        
        border: ImVec4(x: 0.18, y: 0.42, z: 0.60, w: 1.00), // medBlue #2d6b98
        borderDim: ImVec4(x: 0.18, y: 0.42, z: 0.60, w: 0.50),
        
        macClose: ImVec4(x: 1.00, y: 0.37, z: 0.34, w: 1.00),      // #FF5F56
        macCloseHover: ImVec4(x: 1.00, y: 0.50, z: 0.45, w: 1.00),
        macMin: ImVec4(x: 1.00, y: 0.74, z: 0.18, w: 1.00),        // #FFBD2E
        macMinHover: ImVec4(x: 1.00, y: 0.82, z: 0.35, w: 1.00),
        macMax: ImVec4(x: 0.15, y: 0.79, z: 0.25, w: 1.00),        // #27C93F
        macMaxHover: ImVec4(x: 0.25, y: 0.88, z: 0.35, w: 1.00),
        
        hoverBg: ImVec4(x: 1.00, y: 1.00, z: 1.00, w: 0.12),
        activeBg: ImVec4(x: 0.18, y: 0.42, z: 0.60, w: 1.00),
        commandRowHighlight: ImVec4(x: 0.98, y: 0.73, z: 0.01, w: 0.12),
        dangerBg: ImVec4(x: 0.91, y: 0.10, z: 0.15, w: 1.00)
    )
    
    // Pre-defined Light Theme
    public static let light = AppTheme(
        viewportBg: SDL_FColor(r: 0.95, g: 0.96, b: 0.97, a: 1.00), // light gray
        topChromeBg: ImVec4(x: 0.84, y: 0.91, z: 0.96, w: 1.00), // paleBlue #d6e9f5
        tabBarBg: ImVec4(x: 0.84, y: 0.91, z: 0.96, w: 1.00),
        panelBg: ImVec4(x: 0.97, y: 0.98, z: 0.98, w: 1.00), // panelLight #f7f9fa
        panelBgDim: ImVec4(x: 0.97, y: 0.98, z: 0.98, w: 0.95),
        windowBg: ImVec4(x: 0.97, y: 0.98, z: 0.98, w: 1.00),
        
        textPrimary: ImVec4(x: 0.086, y: 0.208, z: 0.302, w: 1.00), // navy
        textDim: ImVec4(x: 0.30, y: 0.40, z: 0.50, w: 1.00),
        textIcon: ImVec4(x: 0.10, y: 0.10, z: 0.10, w: 1.00),
        textAccent: ImVec4(x: 0.28, y: 0.52, z: 0.70, w: 1.00), // A darker blue for the category number in light theme
        
        brandGold: ImVec4(x: 0.88, y: 0.63, z: 0.00, w: 1.00),
        brandGoldHover: ImVec4(x: 1.00, y: 0.80, z: 0.10, w: 1.00),
        brandGoldActive: ImVec4(x: 0.98, y: 0.73, z: 0.01, w: 1.00),
        rowHoverText: ImVec4(x: 0.086, y: 0.208, z: 0.302, w: 1.00),
        
        border: ImVec4(x: 0.62, y: 0.70, z: 0.76, w: 1.00), // lineLight #9eb2c2
        borderDim: ImVec4(x: 0.62, y: 0.70, z: 0.76, w: 0.50),
        
        macClose: ImVec4(x: 1.00, y: 0.37, z: 0.34, w: 1.00),      // #FF5F56
        macCloseHover: ImVec4(x: 1.00, y: 0.50, z: 0.45, w: 1.00),
        macMin: ImVec4(x: 1.00, y: 0.74, z: 0.18, w: 1.00),        // #FFBD2E
        macMinHover: ImVec4(x: 1.00, y: 0.82, z: 0.35, w: 1.00),
        macMax: ImVec4(x: 0.15, y: 0.79, z: 0.25, w: 1.00),        // #27C93F
        macMaxHover: ImVec4(x: 0.25, y: 0.88, z: 0.35, w: 1.00),
        
        hoverBg: ImVec4(x: 0.00, y: 0.00, z: 0.00, w: 0.10),
        activeBg: ImVec4(x: 0.74, y: 0.84, z: 0.91, w: 1.00), // softBlue
        commandRowHighlight: ImVec4(x: 0.88, y: 0.63, z: 0.00, w: 0.14),
        dangerBg: ImVec4(x: 0.91, y: 0.10, z: 0.15, w: 1.00)
    )
}
