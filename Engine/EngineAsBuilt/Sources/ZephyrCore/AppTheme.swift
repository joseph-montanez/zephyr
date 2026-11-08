import Foundation
import SwiftSDL
import ImGui

@MainActor
public struct ThemePreset: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let shortName: String
    public let isDark: Bool
    public let theme: AppTheme

    public init(id: String, displayName: String, shortName: String, isDark: Bool, theme: AppTheme) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.isDark = isDark
        self.theme = theme
    }
}

@inline(__always)
private func vec4(_ hex: UInt32, _ alpha: Float = 1.0) -> ImVec4 {
    ImVec4(
        x: Float((hex >> 16) & 0xFF) / 255.0,
        y: Float((hex >> 8) & 0xFF) / 255.0,
        z: Float(hex & 0xFF) / 255.0,
        w: alpha
    )
}

@inline(__always)
private func sdlColor(_ hex: UInt32, _ alpha: Float = 1.0) -> SDL_FColor {
    SDL_FColor(
        r: Float((hex >> 16) & 0xFF) / 255.0,
        g: Float((hex >> 8) & 0xFF) / 255.0,
        b: Float(hex & 0xFF) / 255.0,
        a: alpha
    )
}

@MainActor
public struct AppTheme {
    // MARK: - Metadata
    public let id: String
    public let name: String
    public let isDark: Bool

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
    public let buttonBg: ImVec4
    public let frameBg: ImVec4
    public let gridMinor: ImVec4
    public let gridMajor: ImVec4

    public init(
        id: String = "custom",
        name: String = "Custom",
        isDark: Bool = true,
        viewportBg: SDL_FColor,
        topChromeBg: ImVec4,
        tabBarBg: ImVec4,
        panelBg: ImVec4,
        panelBgDim: ImVec4,
        windowBg: ImVec4,
        textPrimary: ImVec4,
        textDim: ImVec4,
        textIcon: ImVec4,
        textAccent: ImVec4,
        brandGold: ImVec4,
        brandGoldHover: ImVec4,
        brandGoldActive: ImVec4,
        rowHoverText: ImVec4,
        border: ImVec4,
        borderDim: ImVec4,
        macClose: ImVec4,
        macCloseHover: ImVec4,
        macMin: ImVec4,
        macMinHover: ImVec4,
        macMax: ImVec4,
        macMaxHover: ImVec4,
        hoverBg: ImVec4,
        activeBg: ImVec4,
        commandRowHighlight: ImVec4,
        dangerBg: ImVec4,
        buttonBg: ImVec4? = nil,
        frameBg: ImVec4? = nil,
        gridMinor: ImVec4? = nil,
        gridMajor: ImVec4? = nil
    ) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.viewportBg = viewportBg
        self.topChromeBg = topChromeBg
        self.tabBarBg = tabBarBg
        self.panelBg = panelBg
        self.panelBgDim = panelBgDim
        self.windowBg = windowBg
        self.textPrimary = textPrimary
        self.textDim = textDim
        self.textIcon = textIcon
        self.textAccent = textAccent
        self.brandGold = brandGold
        self.brandGoldHover = brandGoldHover
        self.brandGoldActive = brandGoldActive
        self.rowHoverText = rowHoverText
        self.border = border
        self.borderDim = borderDim
        self.macClose = macClose
        self.macCloseHover = macCloseHover
        self.macMin = macMin
        self.macMinHover = macMinHover
        self.macMax = macMax
        self.macMaxHover = macMaxHover
        self.hoverBg = hoverBg
        self.activeBg = activeBg
        self.commandRowHighlight = commandRowHighlight
        self.dangerBg = dangerBg
        self.buttonBg = buttonBg ?? (isDark ? border : ImVec4(x: 0.88, y: 0.92, z: 0.96, w: 1.00))
        self.frameBg = frameBg ?? (isDark ? ImVec4(x: 0.043, y: 0.098, z: 0.145, w: 1.00) : ImVec4(x: 0.88, y: 0.92, z: 0.96, w: 0.80))
        self.gridMinor = gridMinor ?? (isDark ? ImVec4(x: 1.00, y: 1.00, z: 1.00, w: 0.38) : ImVec4(x: 0.16, y: 0.23, z: 0.31, w: 0.42))
        self.gridMajor = gridMajor ?? (isDark ? ImVec4(x: 1.00, y: 1.00, z: 1.00, w: 0.62) : ImVec4(x: 0.10, y: 0.18, z: 0.28, w: 0.60))
    }
    
    // MARK: - Built-in Themes

    /// Pre-defined Dark Theme
    public static let dark = AppTheme(
        id: "dark",
        name: "Dark",
        isDark: true,
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
        dangerBg: ImVec4(x: 0.91, y: 0.10, z: 0.15, w: 1.00),
        buttonBg: ImVec4(x: 0.18, y: 0.42, z: 0.60, w: 1.00),
        frameBg: ImVec4(x: 0.043, y: 0.098, z: 0.145, w: 1.00)
    )
    
    /// Pre-defined Light Theme
    public static let light = AppTheme(
        id: "light",
        name: "Light",
        isDark: false,
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

    // MARK: - Catppuccin Flavors (https://catppuccin.com/palette/)

    /// Catppuccin Latte — Crisp, warm light mode
    public static let catppuccinLatte = AppTheme(
        id: "catppuccin-latte",
        name: "Catppuccin Latte",
        isDark: false,
        viewportBg: sdlColor(0xeff1f5), // Base #eff1f5
        topChromeBg: vec4(0xe6e9ef),    // Mantle #e6e9ef
        tabBarBg: vec4(0xe6e9ef),       // Mantle #e6e9ef
        panelBg: vec4(0xeff1f5),        // Base #eff1f5
        panelBgDim: vec4(0xeff1f5, 0.95),
        windowBg: vec4(0xeff1f5),

        textPrimary: vec4(0x4c4f69),    // Text #4c4f69
        textDim: vec4(0x6c6f85),        // Subtext0 #6c6f85
        textIcon: vec4(0x5c5f77),       // Subtext1 #5c5f77
        textAccent: vec4(0x1e66f5),     // Blue #1e66f5

        brandGold: vec4(0xdf8e1d),      // Yellow #df8e1d
        brandGoldHover: vec4(0xfe640b), // Peach #fe640b
        brandGoldActive: vec4(0xd20f39),// Red #d20f39
        rowHoverText: vec4(0xeff1f5),   // Base #eff1f5

        border: vec4(0xccd0da),         // Surface0 #ccd0da
        borderDim: vec4(0xccd0da, 0.60),

        macClose: vec4(0xd20f39),       // Red #d20f39
        macCloseHover: vec4(0xe64553),  // Maroon #e64553
        macMin: vec4(0xdf8e1d),         // Yellow #df8e1d
        macMinHover: vec4(0xfe640b),    // Peach #fe640b
        macMax: vec4(0x40a02b),         // Green #40a02b
        macMaxHover: vec4(0x179299),    // Teal #179299

        hoverBg: vec4(0xccd0da, 0.40),  // Surface0 translucent
        activeBg: vec4(0xbcc0cc, 0.85), // Surface1 #bcc0cc
        commandRowHighlight: vec4(0xdf8e1d, 0.16),
        dangerBg: vec4(0xd20f39),
        buttonBg: vec4(0xe6e9ef),       // Mantle #e6e9ef
        frameBg: vec4(0xe6e9ef, 0.85)
    )

    /// Catppuccin Frappé — Cozy low-contrast dark mode
    public static let catppuccinFrappe = AppTheme(
        id: "catppuccin-frappe",
        name: "Catppuccin Frappe",
        isDark: true,
        viewportBg: sdlColor(0x232634), // Crust #232634
        topChromeBg: vec4(0x292c3c),    // Mantle #292c3c
        tabBarBg: vec4(0x232634),       // Crust #232634
        panelBg: vec4(0x303446),        // Base #303446
        panelBgDim: vec4(0x303446, 0.95),
        windowBg: vec4(0x303446),

        textPrimary: vec4(0xc6d0f5),    // Text #c6d0f5
        textDim: vec4(0xa5adce),        // Subtext0 #a5adce
        textIcon: vec4(0xb5bfe2),       // Subtext1 #b5bfe2
        textAccent: vec4(0x8caaee),     // Blue #8caaee

        brandGold: vec4(0xe5c890),      // Yellow #e5c890
        brandGoldHover: vec4(0xef9f76), // Peach #ef9f76
        brandGoldActive: vec4(0xe78284),// Red #e78284
        rowHoverText: vec4(0x232634),   // Crust #232634

        border: vec4(0x51576d),         // Surface1 #51576d
        borderDim: vec4(0x414559, 0.70),// Surface0 #414559

        macClose: vec4(0xe78284),       // Red #e78284
        macCloseHover: vec4(0xea999c),  // Maroon #ea999c
        macMin: vec4(0xe5c890),         // Yellow #e5c890
        macMinHover: vec4(0xef9f76),    // Peach #ef9f76
        macMax: vec4(0xa6d189),         // Green #a6d189
        macMaxHover: vec4(0x81c8be),    // Teal #81c8be

        hoverBg: vec4(0x626880, 0.35),  // Surface2 translucent
        activeBg: vec4(0x51576d, 0.85), // Surface1 #51576d
        commandRowHighlight: vec4(0xe5c890, 0.16),
        dangerBg: vec4(0xe78284),
        buttonBg: vec4(0x414559),       // Surface0 #414559
        frameBg: vec4(0x232634)          // Crust #232634 (deep recessed dark)
    )

    /// Catppuccin Macchiato — Medium-contrast midnight dark mode
    public static let catppuccinMacchiato = AppTheme(
        id: "catppuccin-macchiato",
        name: "Catppuccin Macchiato",
        isDark: true,
        viewportBg: sdlColor(0x181926), // Crust #181926
        topChromeBg: vec4(0x1e2030),    // Mantle #1e2030
        tabBarBg: vec4(0x181926),       // Crust #181926
        panelBg: vec4(0x24273a),        // Base #24273a
        panelBgDim: vec4(0x24273a, 0.95),
        windowBg: vec4(0x24273a),

        textPrimary: vec4(0xcad3f5),    // Text #cad3f5
        textDim: vec4(0xa5adcb),        // Subtext0 #a5adcb
        textIcon: vec4(0xb8c0e0),       // Subtext1 #b8c0e0
        textAccent: vec4(0x8aadf4),     // Blue #8aadf4

        brandGold: vec4(0xeed49f),      // Yellow #eed49f
        brandGoldHover: vec4(0xf5a97f), // Peach #f5a97f
        brandGoldActive: vec4(0xed8796),// Red #ed8796
        rowHoverText: vec4(0x181926),   // Crust #181926

        border: vec4(0x494d64),         // Surface1 #494d64
        borderDim: vec4(0x363a4f, 0.70),// Surface0 #363a4f

        macClose: vec4(0xed8796),       // Red #ed8796
        macCloseHover: vec4(0xee99a0),  // Maroon #ee99a0
        macMin: vec4(0xeed49f),         // Yellow #eed49f
        macMinHover: vec4(0xf5a97f),    // Peach #f5a97f
        macMax: vec4(0xa6da95),         // Green #a6da95
        macMaxHover: vec4(0x8bd5ca),    // Teal #8bd5ca

        hoverBg: vec4(0x5b6078, 0.35),  // Surface2 translucent
        activeBg: vec4(0x494d64, 0.85), // Surface1 #494d64
        commandRowHighlight: vec4(0xeed49f, 0.16),
        dangerBg: vec4(0xed8796),
        buttonBg: vec4(0x363a4f),       // Surface0 #363a4f
        frameBg: vec4(0x181926)          // Crust #181926 (deep recessed dark)
    )

    /// Catppuccin Mocha — Deep, high-contrast dark mode
    public static let catppuccinMocha = AppTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        isDark: true,
        viewportBg: sdlColor(0x11111b), // Crust #11111b
        topChromeBg: vec4(0x181825),    // Mantle #181825
        tabBarBg: vec4(0x11111b),       // Crust #11111b
        panelBg: vec4(0x1e1e2e),        // Base #1e1e2e
        panelBgDim: vec4(0x1e1e2e, 0.95),
        windowBg: vec4(0x1e1e2e),

        textPrimary: vec4(0xcdd6f4),    // Text #cdd6f4
        textDim: vec4(0xa6adc8),        // Subtext0 #a6adc8
        textIcon: vec4(0xbac2de),       // Subtext1 #bac2de
        textAccent: vec4(0x89b4fa),     // Blue #89b4fa

        brandGold: vec4(0xf9e2af),      // Yellow #f9e2af
        brandGoldHover: vec4(0xfab387), // Peach #fab387
        brandGoldActive: vec4(0xf38ba8),// Red #f38ba8
        rowHoverText: vec4(0x11111b),   // Crust #11111b

        border: vec4(0x45475a),         // Surface1 #45475a
        borderDim: vec4(0x313244, 0.70),// Surface0 #313244

        macClose: vec4(0xf38ba8),       // Red #f38ba8
        macCloseHover: vec4(0xeba0ac),  // Maroon #eba0ac
        macMin: vec4(0xf9e2af),         // Yellow #f9e2af
        macMinHover: vec4(0xfab387),    // Peach #fab387
        macMax: vec4(0xa6e3a1),         // Green #a6e3a1
        macMaxHover: vec4(0x94e2d5),    // Teal #94e2d5

        hoverBg: vec4(0x585b70, 0.35),  // Surface2 translucent
        activeBg: vec4(0x45475a, 0.85), // Surface1 #45475a
        commandRowHighlight: vec4(0xf9e2af, 0.16),
        dangerBg: vec4(0xf38ba8),
        buttonBg: vec4(0x313244),       // Surface0 #313244
        frameBg: vec4(0x11111b)          // Crust #11111b (deep recessed dark)
    )

    /// Galactic Purple — Deep-space dark mode with neon violet/cyan accents.
    /// Pairs with the viewport starfield panorama (see `GalacticStarfield`).
    public static let galacticPurple = AppTheme(
        id: "galactic-purple",
        name: "Galactic Purple",
        isDark: true,
        viewportBg: sdlColor(0x160A2E), // vivid deep space #160A2E
        topChromeBg: vec4(0x4A1D96),    // electric nebula violet
        tabBarBg: vec4(0x2A1257),
        panelBg: vec4(0x2C1660),        // vibrant starship panel
        panelBgDim: vec4(0x2C1660, 0.95),
        windowBg: vec4(0x2C1660),

        textPrimary: vec4(0xF1E8FF),    // starlight lavender
        textDim: vec4(0xC9B8E8),
        textIcon: vec4(0xD5C8F0),
        textAccent: vec4(0x8AF3FF),     // ion cyan

        brandGold: vec4(0xD040FF),      // electric nova violet
        brandGoldHover: vec4(0xE38DFF),
        brandGoldActive: vec4(0xB020FF),
        rowHoverText: vec4(0x160A2E),

        border: vec4(0x8B5CF6),
        borderDim: vec4(0x8B5CF6, 0.60),

        macClose: vec4(0xFF6B9D),
        macCloseHover: vec4(0xFF8FB5),
        macMin: vec4(0xFFD166),
        macMinHover: vec4(0xFFE08A),
        macMax: vec4(0x4DE3C2),
        macMaxHover: vec4(0x7DF0D4),

        hoverBg: vec4(0x9D6BFF, 0.32),
        activeBg: vec4(0x6D28D9, 0.85),
        commandRowHighlight: vec4(0xD040FF, 0.25),
        dangerBg: vec4(0xFF3D81),
        buttonBg: vec4(0x3A2068),
        frameBg: vec4(0x160A2E),
        gridMinor: vec4(0xC4B5FD, 0.40),
        gridMajor: vec4(0xDDD0FF, 0.65)
    )

    /// Cotton Candy — Barbie-pink light mode with rainbow candy accents
    public static let cottonCandy = AppTheme(
        id: "cotton-candy",
        name: "Cotton Candy",
        isDark: false,
        viewportBg: sdlColor(0xFFC9DD),
        topChromeBg: vec4(0xFF6FA9),
        tabBarBg: vec4(0xFF6FA9),
        panelBg: vec4(0xFFD9E8),
        panelBgDim: vec4(0xFFD9E8, 0.95),
        windowBg: vec4(0xFFD9E8),
        textPrimary: vec4(0x5C1031),
        textDim: vec4(0x9C3D6E),
        textIcon: vec4(0x7A1F4B),
        textAccent: vec4(0xE6007E),
        brandGold: vec4(0xFF1E8C),
        brandGoldHover: vec4(0xFF5DAC),
        brandGoldActive: vec4(0xC90076),
        rowHoverText: vec4(0x5C1031),
        border: vec4(0xF44A9B),
        borderDim: vec4(0xF44A9B, 0.60),
        macClose: vec4(0xFF2F7A),
        macCloseHover: vec4(0xFF6E9C),
        macMin: vec4(0xFF9E00),
        macMinHover: vec4(0xFFC93C),
        macMax: vec4(0x12C98A),
        macMaxHover: vec4(0x35E0A5),
        hoverBg: vec4(0xFF9CC4, 0.55),
        activeBg: vec4(0xFF7EB0, 0.90),
        commandRowHighlight: vec4(0xFF1E8C, 0.22),
        dangerBg: vec4(0xE6007E),
        buttonBg: vec4(0xFF8ABB),
        frameBg: vec4(0xFFC9DD, 0.90)
    )

    // MARK: - Presets Registry

    public static let allPresets: [ThemePreset] = [
        ThemePreset(id: "dark", displayName: "Dark", shortName: "DARK", isDark: true, theme: .dark),
        ThemePreset(id: "light", displayName: "Light", shortName: "LIGHT", isDark: false, theme: .light),
        ThemePreset(id: "catppuccin-latte", displayName: "Catppuccin Latte", shortName: "LATTE", isDark: false, theme: .catppuccinLatte),
        ThemePreset(id: "catppuccin-frappe", displayName: "Catppuccin Frappe", shortName: "FRAPPE", isDark: true, theme: .catppuccinFrappe),
        ThemePreset(id: "catppuccin-macchiato", displayName: "Catppuccin Macchiato", shortName: "MACCHIATO", isDark: true, theme: .catppuccinMacchiato),
        ThemePreset(id: "catppuccin-mocha", displayName: "Catppuccin Mocha", shortName: "MOCHA", isDark: true, theme: .catppuccinMocha),
        ThemePreset(id: "cotton-candy", displayName: "Cotton Candy", shortName: "CANDY", isDark: false, theme: .cottonCandy),
        ThemePreset(id: "galactic-purple", displayName: "Galactic Purple", shortName: "GALAXY", isDark: true, theme: .galacticPurple),
    ]

    /// Lookup an AppTheme by name or alias (case-insensitive).
    public static func theme(named name: String) -> AppTheme? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "é", with: "e")

        switch clean {
        case "dark", "darkmode", "zephyrdark":
            return .dark
        case "light", "lightmode", "zephyrlight":
            return .light
        case "latte", "catppuccinlatte":
            return .catppuccinLatte
        case "frappe", "catppuccinfrappe":
            return .catppuccinFrappe
        case "macchiato", "catppuccinmacchiato":
            return .catppuccinMacchiato
        case "candy", "cottoncandy", "barbie", "barbiecottoncandy", "rainbow":
            return .cottonCandy
        case "mocha", "catppuccinmocha":
            return .catppuccinMocha
        case "galaxy", "galactic", "galacticpurple", "purple", "space":
            return .galacticPurple
        default:
            return nil
        }
    }

    /// Retrieve the next theme in the preset sequence.
    public static func nextTheme(after current: AppTheme) -> AppTheme {
        guard let idx = allPresets.firstIndex(where: { $0.id == current.id }) else {
            return allPresets[0].theme
        }
        let nextIdx = (idx + 1) % allPresets.count
        return allPresets[nextIdx].theme
    }
}
