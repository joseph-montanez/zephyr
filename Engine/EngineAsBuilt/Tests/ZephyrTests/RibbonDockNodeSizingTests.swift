import XCTest
import ImGui

/// Pins the two ImGui mechanisms the ribbon relies on and that are easy to
/// get subtly wrong:
///
/// 1. A **docked** window's height is owned by its dock node, so changing the
///    ribbon presentation (menu / labels / icons) has to resize that node at
///    runtime — and the new size must survive the following frames.
/// 2. A popup opened with `OpenPopup` only draws in frames where
///    `BeginPopup` is called for its id, so the flyout code must evaluate
///    `BeginPopup` every frame instead of only on the click frame. That bug
///    (flyouts opening into nothing) is what motivated this test.
///
/// Runs headless: a bare ImGui context, no window, same recipe as
/// `SequentialFrameCaptureTests`.
final class RibbonDockNodeSizingTests: XCTestCase {

    private func makeContext() -> UnsafeMutablePointer<ImGuiIO> {
        _ = ImGuiCreateContext(nil)
        let io = ImGuiGetIO()!
        io.pointee.ConfigFlags |= Int32(ImGuiConfigFlags_DockingEnable.rawValue)
        io.pointee.IniFilename = nil
        _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        igImFontAtlasBuildMain(io.pointee.Fonts)
        io.pointee.DeltaTime = 1.0 / 60.0
        return io
    }

    private let hostFlags: Int32 =
        Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        | Int32(ImGuiWindowFlags_NoResize.rawValue)
        | Int32(ImGuiWindowFlags_NoMove.rawValue)
        | Int32(ImGuiWindowFlags_NoBringToFrontOnFocus.rawValue)
        | Int32(ImGuiWindowFlags_NoNavFocus.rawValue)
        | Int32(ImGuiWindowFlags_NoBackground.rawValue)

    // MARK: - Dock node sizing

    func testDockedWindowNodeCanBeResizedAtRuntime() {
        let io = makeContext()
        defer { ImGuiDestroyContext(nil) }

        var dockID: ImGuiID = 0
        var ribbonNode: ImGuiID = 0
        var measuredWidth: Float = 0
        var measuredHeight: Float = 0
        var windowDockID: ImGuiID = 0

        func frame(_ body: () -> Void) {
            io.pointee.DisplaySize = ImVec2(x: 1280, y: 800)
            ImGuiNewFrame()
            body()
            ImGuiRender()
        }

        // The dockspace host the ribbon lives in (mirrors AppUI).
        func host() {
            ImGuiSetNextWindowPos(
                ImVec2(x: 0, y: 0), Int32(ImGuiCond_Always.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(
                ImVec2(x: 1280, y: 800), Int32(ImGuiCond_Always.rawValue))
            var open = true
            if igBegin("MainWorkspace", &open, hostFlags) {
                // No PassthruCentralNode: ImGui refuses to *split* a
                // passthru central node from the builder API (user dragging
                // still works). The sizing semantics under test are the same.
                dockID = igDockSpace(
                    igGetID_Str("MainDockSpace"), ImVec2(x: 0, y: 0), 0, nil)
            }
            igEnd()
        }

        // Submits the ribbon window and records the node rect it lives in.
        func ribbonWindow() {
            var open = true
            if igBegin(
                "Ribbon", &open,
                Int32(ImGuiWindowFlags_NoTitleBar.rawValue)) {
                windowDockID = ImGuiGetWindowDockID()
                if let node = ImGuiDockBuilderGetNode(windowDockID) {
                    let rect = ImGuiDockNodeRect(node)
                    measuredWidth = rect.Max.x - rect.Min.x
                    measuredHeight = rect.Max.y - rect.Min.y

                }
            }
            igEnd()
        }

        // Frame 1: dockspace plus a top split reserved for the ribbon, using
        // the documented builder idiom (the root must be sized first, and the
        // returned id is the node at the split direction).
        frame {
            host()
            if dockID != 0 {
                ImGuiDockBuilderRemoveNode(dockID)
                // The rebuilt node must be flagged as a dockspace, otherwise
                // DockSpace() resets it and the split is discarded.
                // ImGuiDockNodeFlags_DockSpace (1 << 10) is a private flag
                // with no Swift binding; the raw bit is what the builder
                // needs to keep treating this node as a dockspace.
                ImGuiDockBuilderAddNode(dockID, 1 << 10)
                ImGuiDockBuilderSetNodeSize(
                    dockID, ImVec2(x: 1280, y: 800))
                var main: ImGuiID = dockID
                ribbonNode = ImGuiDockBuilderSplitNode(
                    main, ImGuiDir_Up, 0.25, nil, &main)
                ImGuiDockBuilderDockWindow("Ribbon", ribbonNode)
                ImGuiDockBuilderFinish(dockID)
            }
        }
        XCTAssertNotEqual(ribbonNode, 0, "the builder must hand back a node")
        XCTAssertNotEqual(ribbonNode, dockID,
                          "the ribbon node must be the top split, not the root")

        // Frames 2-3: the window docks in the reserved node.
        frame {
            host()
            ribbonWindow()
        }
        frame {
            host()
            ribbonWindow()
        }
        XCTAssertEqual(windowDockID, ribbonNode,
                       "the ribbon must be docked in the reserved node")
        XCTAssertGreaterThan(measuredWidth, 100)
        XCTAssertGreaterThan(measuredHeight, 100,
                             "a 25% top split of 800 should be tall")
        XCTAssertLessThan(measuredHeight, 400,
                          "the top split must not fill the whole dockspace")

        // Collapse: resize the node to a labels-bar height, like the ribbon
        // does when cycling to a shorter presentation.
        let target: Float = 58
        ImGuiDockBuilderSetNodeSize(
            ribbonNode, ImVec2(x: measuredWidth, y: target))

        frame {
            host()
            ribbonWindow()
        }
        XCTAssertEqual(measuredHeight, target, accuracy: 2,
                       "the node must adopt the requested height")

        // ...and the new size must stick instead of snapping back.
        frame {
            host()
            ribbonWindow()
        }
        frame {
            host()
            ribbonWindow()
        }
        XCTAssertEqual(measuredHeight, target, accuracy: 2,
                       "the collapsed height must survive later frames")

        // Expanding again follows the same path.
        let expanded: Float = 140
        ImGuiDockBuilderSetNodeSize(
            ribbonNode, ImVec2(x: measuredWidth, y: expanded))
        frame {
            host()
            ribbonWindow()
        }
        XCTAssertEqual(measuredHeight, expanded, accuracy: 2)
    }

    // MARK: - Popup submission

    /// `BeginPopup` must run every frame: the popup body only executes in
    /// frames where it is submitted, even while ImGui keeps the popup open.
    func testPopupBodyOnlyRunsWhenBeginPopupIsCalled() {
        let io = makeContext()
        defer { ImGuiDestroyContext(nil) }

        var openPopupThisFrame = false
        var submitPopup = true
        var bodyRuns = 0
        var openReported = false

        func frame() {
            io.pointee.DisplaySize = ImVec2(x: 1280, y: 800)
            ImGuiNewFrame()
            var open = true
            if igBegin(
                "Ribbon", &open,
                Int32(ImGuiWindowFlags_NoTitleBar.rawValue)) {
                if openPopupThisFrame {
                    ImGuiOpenPopup("##flyout", 0)
                }
                openReported = ImGuiIsPopupOpen("##flyout", 0)
                if submitPopup, ImGuiBeginPopup("##flyout", 0) {
                    bodyRuns += 1
                    igMenuItem_Bool("Ellipse", nil, false, true)
                    ImGuiEndPopup()
                }
            }
            igEnd()
            ImGuiRender()
        }

        // Frame 0: nothing open.
        frame()
        XCTAssertFalse(openReported)
        XCTAssertEqual(bodyRuns, 0)

        // Frame 1: the click opens the popup and it draws in the same frame.
        openPopupThisFrame = true
        frame()
        XCTAssertTrue(openReported, "OpenPopup must register the popup")
        XCTAssertEqual(bodyRuns, 1, "the body must draw in the opening frame")

        // Frame 2: no further click, but BeginPopup still runs -> body draws
        // again and the popup stays on screen.
        openPopupThisFrame = false
        frame()
        XCTAssertEqual(bodyRuns, 2)
        XCTAssertTrue(openReported)

        // Frame 3: skipping BeginPopup is exactly the reported bug — the
        // popup is still "open" but nothing renders.
        submitPopup = false
        frame()
        XCTAssertEqual(bodyRuns, 2,
                       "without BeginPopup the body must not run")
        XCTAssertTrue(
            openReported,
            "ImGui still considers it open, which is why it looked like "
                + "nothing happened")
    }

    // MARK: - Tab bar height theft (the clipped panel titles)

    /// A *visible* dock tab bar lives inside the node rect, above the
    /// window, so the window is shorter than its node by the tab bar's
    /// height. Sizing the node to the content height alone (the old
    /// ribbon behaviour) therefore clips the bottom row of content.
    func testVisibleDockTabBarStealsHeightFromDockedWindow() {
        let io = makeContext()
        defer { ImGuiDestroyContext(nil) }

        var dockID: ImGuiID = 0
        var ribbonNode: ImGuiID = 0
        var nodeHeight: Float = 0
        var windowY: Float = 0
        var cursorY: Float = 0
        var availY: Float = 0
        var paddingY: Float = 0

        func frame(_ body: () -> Void) {
            io.pointee.DisplaySize = ImVec2(x: 1280, y: 800)
            ImGuiNewFrame()
            body()
            ImGuiRender()
        }
        func host() {
            ImGuiSetNextWindowPos(
                ImVec2(x: 0, y: 0), Int32(ImGuiCond_Always.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(
                ImVec2(x: 1280, y: 800), Int32(ImGuiCond_Always.rawValue))
            var open = true
            if igBegin("MainWorkspace", &open, hostFlags) {
                dockID = igDockSpace(
                    igGetID_Str("MainDockSpace"), ImVec2(x: 0, y: 0), 0, nil)
            }
            igEnd()
        }
        func ribbonWindow() {
            var open = true
            if igBegin(
                "Ribbon", &open,
                Int32(ImGuiWindowFlags_NoTitleBar.rawValue)) {
                // The docked window rect equals the node rect; the tab
                // bar steals its height from the *content* origin, so
                // measure where the first item would draw.
                windowY = ImGuiGetWindowPos().y
                cursorY = ImGuiGetCursorScreenPos().y
                availY = ImGuiGetContentRegionAvail().y
                paddingY = ImGuiGetStyle()?.pointee.WindowPadding.y ?? 8
                if let node = ImGuiDockBuilderGetNode(ImGuiGetWindowDockID()) {
                    let rect = ImGuiDockNodeRect(node)
                    nodeHeight = rect.Max.y - rect.Min.y
                }
            }
            igEnd()
        }

        frame {
            host()
            if dockID != 0 {
                ImGuiDockBuilderRemoveNode(dockID)
                ImGuiDockBuilderAddNode(dockID, 1 << 10)
                ImGuiDockBuilderSetNodeSize(
                    dockID, ImVec2(x: 1280, y: 800))
                var main: ImGuiID = dockID
                ribbonNode = ImGuiDockBuilderSplitNode(
                    main, ImGuiDir_Up, 0.25, nil, &main)
                ImGuiDockBuilderDockWindow("Ribbon", ribbonNode)
                ImGuiDockBuilderFinish(dockID)
            }
        }
        for _ in 0..<3 {
            frame {
                host()
                ribbonWindow()
            }
        }

        XCTAssertNotEqual(ribbonNode, 0)
        XCTAssertGreaterThan(nodeHeight, 100)
        XCTAssertGreaterThan(
            cursorY - windowY, paddingY + 5,
            "content must start below the tab bar + top padding: "
                + "offset \(cursorY - windowY), padding \(paddingY) — the "
                + "excess is the tab bar height node sizing must add back")
        XCTAssertLessThan(
            availY, nodeHeight - paddingY * 2 - 5,
            "content space must lose the tab bar height on top of "
                + "padding: avail \(availY), node \(nodeHeight)")
    }

    /// `ImGuiDockNodeFlags_AutoHideTabBar` on the dockspace is the fix's
    /// foundation: a solo window hides its tab bar (window fills the
    /// node), and a second window in the node brings the tab bar back.
    func testAutoHideTabBarHidesForSoloWindowAndShowsForTwo() {
        let io = makeContext()
        defer { ImGuiDestroyContext(nil) }

        var dockID: ImGuiID = 0
        var ribbonNode: ImGuiID = 0
        var hidden = false
        var soloTopOffset: Float = -1
        var paddingY: Float = 0
        let autoHide = Int32(ImGuiDockNodeFlags_AutoHideTabBar.rawValue)

        func frame(_ body: () -> Void) {
            io.pointee.DisplaySize = ImVec2(x: 1280, y: 800)
            ImGuiNewFrame()
            body()
            ImGuiRender()
        }
        func host() {
            ImGuiSetNextWindowPos(
                ImVec2(x: 0, y: 0), Int32(ImGuiCond_Always.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(
                ImVec2(x: 1280, y: 800), Int32(ImGuiCond_Always.rawValue))
            var open = true
            if igBegin("MainWorkspace", &open, hostFlags) {
                dockID = igDockSpace(
                    igGetID_Str("MainDockSpace"), ImVec2(x: 0, y: 0),
                    autoHide, nil)
            }
            igEnd()
        }
        func window(_ name: String, record: Bool) {
            var open = true
            if igBegin(
                name, &open,
                Int32(ImGuiWindowFlags_NoTitleBar.rawValue)), record {
                // Only the visible tab's Begin body runs, so record the
                // content offset here but the node flags separately.
                soloTopOffset = ImGuiGetCursorScreenPos().y
                    - ImGuiGetWindowPos().y
                paddingY = ImGuiGetStyle()?.pointee.WindowPadding.y ?? 8
            }
            igEnd()
        }
        func recordNode() {
            if ribbonNode != 0,
               let node = ImGuiDockBuilderGetNode(ribbonNode) {
                hidden = ImGuiDockNodeIsHiddenTabBar(node)
            }
        }

        frame {
            host()
            if dockID != 0 {
                ImGuiDockBuilderRemoveNode(dockID)
                ImGuiDockBuilderAddNode(dockID, 1 << 10)
                ImGuiDockBuilderSetNodeSize(
                    dockID, ImVec2(x: 1280, y: 800))
                var main: ImGuiID = dockID
                ribbonNode = ImGuiDockBuilderSplitNode(
                    main, ImGuiDir_Up, 0.25, nil, &main)
                ImGuiDockBuilderDockWindow("Ribbon", ribbonNode)
                ImGuiDockBuilderFinish(dockID)
            }
        }
        for _ in 0..<4 {
            frame {
                host()
                window("Ribbon", record: true)
                recordNode()
            }
        }
        XCTAssertTrue(
            hidden, "a solo docked window must auto-hide its tab bar")
        XCTAssertEqual(
            soloTopOffset, paddingY, accuracy: 2,
            "with the tab bar hidden content starts right below the "
                + "top padding: offset \(soloTopOffset), padding \(paddingY)")

        ImGuiDockBuilderDockWindow("Other", ribbonNode)
        for _ in 0..<4 {
            frame {
                host()
                window("Ribbon", record: true)
                window("Other", record: false)
                recordNode()
            }
        }
        XCTAssertFalse(
            hidden,
            "a second window in the node must bring the tab bar back")
    }

    /// Pop-out: undocking with `igSetWindowDock(window, 0)` using a
    /// pointer captured inside `Begin` but called after `End` — the
    /// exact shape `RibbonUI` uses for its Pop-out button, since
    /// actions are dispatched after `igEnd()`.
    func testSetWindowDockZeroUndocksAfterEnd() throws {
        let io = makeContext()
        defer { ImGuiDestroyContext(nil) }

        var dockID: ImGuiID = 0
        var ribbonNode: ImGuiID = 0
        var isDocked = false
        var windowDockID: ImGuiID = 1
        var windowPointer: UnsafeMutablePointer<ImGuiWindow>?

        func frame(_ body: () -> Void) {
            io.pointee.DisplaySize = ImVec2(x: 1280, y: 800)
            ImGuiNewFrame()
            body()
            ImGuiRender()
        }
        func host() {
            ImGuiSetNextWindowPos(
                ImVec2(x: 0, y: 0), Int32(ImGuiCond_Always.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(
                ImVec2(x: 1280, y: 800), Int32(ImGuiCond_Always.rawValue))
            var open = true
            if igBegin("MainWorkspace", &open, hostFlags) {
                dockID = igDockSpace(
                    igGetID_Str("MainDockSpace"), ImVec2(x: 0, y: 0),
                    Int32(ImGuiDockNodeFlags_AutoHideTabBar.rawValue), nil)
            }
            igEnd()
        }
        func ribbonWindow() {
            var open = true
            if igBegin(
                "Ribbon", &open,
                Int32(ImGuiWindowFlags_NoTitleBar.rawValue)) {
                isDocked = ImGuiIsWindowDocked()
                windowDockID = ImGuiGetWindowDockID()
                windowPointer = ImGuiGetCurrentWindow()
            }
            igEnd()
        }

        frame {
            host()
            if dockID != 0 {
                ImGuiDockBuilderRemoveNode(dockID)
                _ = ImGuiDockBuilderAddNode(dockID, 1 << 10)
                ImGuiDockBuilderSetNodeSize(
                    dockID, ImVec2(x: 1280, y: 800))
                var main: ImGuiID = dockID
                ribbonNode = ImGuiDockBuilderSplitNode(
                    main, ImGuiDir_Up, 0.25, nil, &main)
                ImGuiDockBuilderDockWindow("Ribbon", ribbonNode)
                ImGuiDockBuilderFinish(dockID)
            }
        }
        for _ in 0..<3 {
            frame {
                host()
                ribbonWindow()
            }
        }
        XCTAssertTrue(isDocked, "precondition: the ribbon starts docked")
        XCTAssertEqual(windowDockID, ribbonNode)
        let pointer = try XCTUnwrap(windowPointer)

        // The pop-out click: after End, still inside the frame.
        frame {
            host()
            ribbonWindow()
            igSetWindowDock(
                pointer, 0, Int32(ImGuiCond_Always.rawValue))
        }
        for _ in 0..<3 {
            frame {
                host()
                ribbonWindow()
            }
        }
        XCTAssertFalse(isDocked, "pop-out must leave the window floating")
        XCTAssertEqual(windowDockID, 0)
    }

    /// The unhide triangle sits at the top-center of its node, not
    /// the stock top-left corner: with the node at (0,0) the corner
    /// sits inside a frameless window's OS resize border, so clicks
    /// resize instead of unhiding. The Zephyr ImGui patch centers it
    /// on the top edge, and keeps its hit rect 12px below the
    /// viewport top for the same reason. Losing the patch in a
    /// vendor update fails this test.
    func testUnhideTriangleSitsAtTopCenter() {
        let io = makeContext()
        defer { ImGuiDestroyContext(nil) }

        var dockID: ImGuiID = 0
        var ribbonNode: ImGuiID = 0
        var hidden = false
        var nodeX: Float = -1
        var nodeY: Float = -1
        var nodeW: Float = 0

        func frame(mouse: ImVec2, down: Bool, _ body: () -> Void) {
            io.pointee.DisplaySize = ImVec2(x: 1280, y: 800)
            ImGuiIO_AddMousePosEvent(io, mouse.x, mouse.y)
            ImGuiIO_AddMouseButtonEvent(io, 0, down)
            ImGuiNewFrame()
            body()
            ImGuiRender()
        }
        func host() {
            // Zero padding like AppUI, so the node starts at (0,0) —
            // squarely in the resize border this test is about.
            ImGuiPushStyleVar(
                Int32(ImGuiStyleVar_WindowPadding.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowPos(
                ImVec2(x: 0, y: 0), Int32(ImGuiCond_Always.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(
                ImVec2(x: 1280, y: 800), Int32(ImGuiCond_Always.rawValue))
            var open = true
            if igBegin("MainWorkspace", &open, hostFlags) {
                dockID = igDockSpace(
                    igGetID_Str("MainDockSpace"), ImVec2(x: 0, y: 0),
                    Int32(ImGuiDockNodeFlags_AutoHideTabBar.rawValue), nil)
            }
            igEnd()
            ImGuiPopStyleVar(1)
        }
        func ribbonWindow() {
            var open = true
            if igBegin(
                "Ribbon", &open,
                Int32(ImGuiWindowFlags_NoTitleBar.rawValue)) {
                if let node = ImGuiDockBuilderGetNode(ImGuiGetWindowDockID()) {
                    let rect = ImGuiDockNodeRect(node)
                    nodeX = rect.Min.x
                    nodeY = rect.Min.y
                    nodeW = rect.Max.x - rect.Min.x
                }
            }
            igEnd()
            if ribbonNode != 0,
               let node = ImGuiDockBuilderGetNode(ribbonNode) {
                hidden = ImGuiDockNodeIsHiddenTabBar(node)
            }
        }
        func scene(mouse: ImVec2, down: Bool) {
            frame(mouse: mouse, down: down) {
                host()
                ribbonWindow()
            }
        }
        func click(at point: ImVec2) {
            scene(mouse: point, down: false)
            scene(mouse: point, down: true)
            scene(mouse: point, down: false)
            scene(mouse: point, down: false)
        }

        frame(mouse: ImVec2(x: 640, y: 400), down: false) {
            host()
            if dockID != 0 {
                ImGuiDockBuilderRemoveNode(dockID)
                _ = ImGuiDockBuilderAddNode(dockID, 1 << 10)
                ImGuiDockBuilderSetNodeSize(
                    dockID, ImVec2(x: 1280, y: 800))
                var main: ImGuiID = dockID
                ribbonNode = ImGuiDockBuilderSplitNode(
                    main, ImGuiDir_Up, 0.25, nil, &main)
                ImGuiDockBuilderDockWindow("Ribbon", ribbonNode)
                ImGuiDockBuilderFinish(dockID)
            }
        }
        for _ in 0..<4 {
            scene(mouse: ImVec2(x: 640, y: 400), down: false)
        }
        XCTAssertTrue(hidden, "precondition: solo tab bar auto-hidden")
        XCTAssertEqual(nodeX, 0, accuracy: 1)
        XCTAssertEqual(nodeY, 0, accuracy: 1)

        let centerX = nodeX + nodeW * 0.5

        // The stock corner spot is inside the resize border and must
        // no longer be the button.
        click(at: ImVec2(x: 3, y: 3))
        XCTAssertTrue(
            hidden,
            "clicking the corner must not unhide (triangle moved to "
                + "top-center)")

        // Top-center within the top resize strip: the drawn triangle
        // reaches the edge, but the hit rect starts 12px down.
        click(at: ImVec2(x: centerX, y: 3))
        XCTAssertTrue(
            hidden,
            "clicking the triangle tip inside the resize strip must "
                + "not unhide")

        // Top-center below the resize strip unhides.
        click(at: ImVec2(x: centerX, y: 16))
        XCTAssertFalse(
            hidden,
            "clicking the top-center triangle must show the tab bar")
    }

    /// A floating ribbon keeps its title bar, which also lives inside
    /// the window rect: a fixed window height of content+padding is
    /// short by the title bar (the Menu-mode half-text when floating).
    func testFloatingTitleBarStealsHeightFromContent() {
        let io = makeContext()
        defer { ImGuiDestroyContext(nil) }

        var availY: Float = 0
        var windowY: Float = 0
        for _ in 0..<3 {
            io.pointee.DisplaySize = ImVec2(x: 1280, y: 800)
            ImGuiNewFrame()
            ImGuiSetNextWindowSize(
                ImVec2(x: 400, y: 100), Int32(ImGuiCond_Always.rawValue))
            var open = true
            if igBegin("Floaty", &open, 0) {
                availY = ImGuiGetContentRegionAvail().y
                windowY = ImGuiGetWindowSize().y
            }
            igEnd()
            ImGuiRender()
        }
        XCTAssertEqual(windowY, 100, accuracy: 1)
        XCTAssertLessThan(
            availY, windowY - 20,
            "title bar + padding must consume a visible slice: avail "
                + "\(availY) of window \(windowY)")
    }
}
