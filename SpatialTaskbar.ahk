#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn

; =============================================================================
; SpatialTaskbar — Alt+Space vertical task panel (AHK v2)
;
; Alt+Space: show / hide / refocus the panel on the monitor under the cursor
; (left edge, full work-area height, ~33% width). Panel hides when any
; non-panel window becomes active. Open focuses the selected window and closes
; the panel. Single-click / focus on a row raises that window without stealing
; keyboard focus from the panel (Z-order only).
;
; Section header: click the name to select that section (highlight). Click the
; chevron (or two quick clicks on the same name within ~400 ms) to expand/collapse
; (chevron / double-name toggle is ignored while a text filter is active — sections stay expanded).
; - Section removes only the currently selected section (never Uncategorized). Drag onto a section name/chevron
; moves the window into that section (works while the section is collapsed too).
;
; No periodic window polling: the panel hides when focus leaves, so new windows
; are opened only after it closes; the next open rebuilds the list from scratch.
;
; Text filter: sections are forced expanded so matches stay visible; expand/collapse state is
; restored when the filter is cleared or the panel is reopened (search cleared on reopen).
; A "×" beside the search box clears the filter (same row as Open / + Section / - Section); always visible; extra clicks when empty do nothing.
;
; No disk persistence: everything is in memory until you exit or #Reload.
; Middle-click a row: same Z-order bump as left click, then WM_CLOSE is posted.
; Many Explorer windows still feel “easy” because each row is one HWND and close
; is usually one step. Word/Excel/etc. often show save or other modals per window;
; there is no safe silent close without risking data — we only ask WM_CLOSE, and
; for listed exes you get a confirm dialog first (edit g_CloseConfirmExes).
; =============================================================================

global g_Gui := 0
global g_MidPane := 0 ; child GUI: section headers + custom-painted window rows, clipped + single V scroll
global g_ScrollY := 0
global g_ScrollContentH := 0
global g_ScrollViewportH := 0
global g_Search := 0
global g_SearchClear := 0 ; Text "×" beside filter (same row); always visible; no-op when filter empty
global g_Filter := ""
global g_FilterExpandBackup := 0 ; Map(secIdx -> expanded) while filter text active; restored when filter cleared
global g_SelectedHwnd := 0
global g_ActiveSec := 1
global g_SelectedSection := 0 ; section index for header selection (- Section); 0 = none
global g_PanelVisible := false
global g_SuppressFocusHide := false ; keep panel visible while activating windows from list click
global g_Drag := 0
global g_SkipClickUntil := 0 ; suppress click-activate right after drag release
global g_RebuildingGui := false ; true while section controls are being destroyed/recreated
global g_Sections := []
global g_HwndToSection := Map()
global g_Order := Map() ; section index -> [hwnd, ...] display order
global g_LastListSig := "" ; skip full mid-pane repaint when nothing changed (stops timer flicker)
global g_RowModel := [] ; unified logical rows: section headers + window rows (single custom list)
global g_WindowRowIndexByHwnd := Map() ; hwnd -> row index in g_RowModel
global g_RowModelIndexBySecRow := Map() ; "sec:row" -> row index in g_RowModel
global g_RowHwndsBySection := Map() ; sec idx -> [hwnd,...] in current visible row-model order
global g_MidClickRow := 0 ; pending row click / drag threshold {sec,row,hwnd,mx,my}
global g_SectionHeaderClientRects := Map() ; sec idx -> {l,t,r,b} in mid-pane client coords
global g_WindowRowClientRects := [] ; [{sec,row,hwnd,l,t,r,b}, ...] in mid-pane client coords
global g_SectionListBands := Map() ; sec idx -> {l,t,r,b,rows} in mid-pane client coords
global g_MidPaneSubclassCb := 0 ; SetWindowSubclass proc (must stay alive)
global MID_PANE_SUBCLASS_ID := 1001

global WM_PAINT := 0x000F
global WM_LBUTTONDOWN := 0x0201
global WM_LBUTTONUP := 0x0202
global WM_MOUSEMOVE := 0x0200
global WM_ACTIVATE := 0x0006
global WM_ACTIVATEAPP := 0x001C
global WM_VSCROLL := 0x0115
global WM_MOUSEWHEEL := 0x020A
global VK_LBUTTON := 0x01

global g_IconList := 0
global g_HwndIconIdx := Map() ; hwnd -> small-icon index in g_IconList

; VS Code / Cursor–style dark UI (approx. Dark+ / default dark theme)
global THEME_BG := "1E1E1E"       ; editor background
global THEME_PANEL := "252526"    ; side bar / inputs
global THEME_HDR := "2D2D30"      ; section header idle
global THEME_SEL := "264F78"      ; list / header selection
global THEME_TEXT := "CCCCCC"
global THEME_BTN_BG := "303033"
global THEME_BTN_HOVER := "3E3E42" ; slightly lighter for Text-as-button hover
global THEME_BTN_TEXT := "D4D4D4"
global THEME_CLOSE_BTN_BG := "4A1E1E"
global THEME_CLOSE_BTN_HOVER := "7A2B2B"
global g_HoverBtnName := "" ; v-name of Text button under cursor (hover polish)
global g_FocusBtnName := "" ; v-name of Text button with keyboard focus (focus ring polish)
global THEME_LV_BG := 0x252526
global THEME_LV_TEXT := 0xCCCCCC
global ICON_SIZE := 24 ; 50% bigger than 16px

; Custom list row text: ~30% larger than main UI (s10 → s13); row pitch matches so text is not clipped.
global FONT_LV_PT := Round(10 * 1.3)        ; 13
global LV_ROW_HEIGHT := Round(22 * 1.3)   ; was 22 px/row at smaller text
global MID_PANE_HDR_H := 30
global MID_PANE_CHEV_W := 28

; Middle-click close: ask before WM_CLOSE for apps that usually prompt (add/remove exe names).
global g_CloseConfirmExes := Map(
    "WINWORD.EXE", true,
    "EXCEL.EXE", true,
    "POWERPNT.EXE", true,
    "MSACCESS.EXE", true,
    "OUTLOOK.EXE", true,
    "ONENOTE.EXE", true,
)

CloseNeedsUserConfirm(hwnd) {
    global g_CloseConfirmExes
    try exe := StrUpper(WinGetProcessName("ahk_id " hwnd))
    catch
        return false
    return g_CloseConfirmExes.Has(exe)
}

; --- Sections ----------------------------------------------------------------
InitSections() {
    global g_Sections, g_HwndToSection, g_Order, g_LastListSig
    g_Sections := [
        { name: "Section 1", expanded: true, locked: false, lv: 0, hdrChev: 0, hdrName: 0, btnUp: 0, btnDn: 0 },
        { name: "Section 2", expanded: true, locked: false, lv: 0, hdrChev: 0, hdrName: 0, btnUp: 0, btnDn: 0 },
        { name: "Section 3", expanded: true, locked: false, lv: 0, hdrChev: 0, hdrName: 0, btnUp: 0, btnDn: 0 },
        { name: "Uncategorized", expanded: true, locked: true, lv: 0, hdrChev: 0, hdrName: 0, btnUp: 0, btnDn: 0 }
    ]
    g_HwndToSection := Map()
    g_Order := Map()
    g_LastListSig := ""
}

UncatIdx() => g_Sections.Length

SecOrder(i) {
    global g_Order
    if !g_Order.Has(i)
        g_Order[i] := []
    return g_Order[i]
}

RemoveHwndFromOrders(hwnd) {
    global g_Order
    for i, arr in g_Order
        g_Order[i] := RemoveVal(arr, hwnd)
}

RemoveVal(arr, val) {
    o := []
    for x in arr
        if x != val
            o.Push(x)
    return o
}

InsertAt(arr, idx, val) {
    o := []
    Loop arr.Length {
        if A_Index = idx
            o.Push(val)
        o.Push(arr[A_Index])
    }
    if idx > arr.Length
        o.Push(val)
    return o
}

CloneArr(arr) {
    o := []
    for x in arr
        o.Push(x)
    return o
}

; --- Shared small icons (image list for custom row paint + Win32 icon cache) ---
EnsureIconList() {
    global g_IconList, ICON_SIZE
    if !g_IconList
        g_IconList := DllCall("Comctl32\ImageList_Create", "int", ICON_SIZE, "int", ICON_SIZE, "uint", 0x21
            , "int", 16, "int", 128, "ptr")
}

ResetIconList() {
    global g_IconList, g_HwndIconIdx
    if g_IconList {
        try DllCall("Comctl32\ImageList_Destroy", "ptr", g_IconList)
        g_IconList := 0
    }
    g_HwndIconIdx := Map()
    EnsureIconList()
}

TryProcessPath(hwnd) {
    try return WinGetProcessPath("ahk_id " hwnd)
    catch {
        try {
            pid := WinGetPID("ahk_id " hwnd)
            return ProcessPathFromPid(pid)
        }
    }
    return ""
}

ProcessPathFromPid(pid) {
    if !pid
        return ""
    hProc := DllCall("OpenProcess", "uint", 0x1000, "int", 0, "uint", pid, "ptr") ; PROCESS_QUERY_LIMITED_INFORMATION
    if !hProc
        return ""
    sz := 32767
    buf := Buffer(sz * 2 + 2, 0)
    if !DllCall("kernel32\QueryFullProcessImageNameW", "ptr", hProc, "uint", 0, "ptr", buf, "uint*", &sz) {
        DllCall("CloseHandle", "ptr", hProc)
        return ""
    }
    DllCall("CloseHandle", "ptr", hProc)
    return StrGet(buf, "UTF-16")
}

GetWindowIconHandle(hwnd) {
    WM_GETICON := 0x007F
    for v in [2, 0, 1] { ; ICON_SMALL2, ICON_SMALL, ICON_BIG
        h := DllCall("user32\SendMessage", "ptr", hwnd, "uint", WM_GETICON, "ptr", v, "ptr", 0, "ptr")
        if h
            return h
    }
    h := DllCall("user32\GetClassLongPtrW", "ptr", hwnd, "int", -34, "ptr") ; GCLP_HICONSM
    if h
        return h
    return DllCall("user32\GetClassLongPtrW", "ptr", hwnd, "int", -14, "ptr") ; GCLP_HICON
}

IconFromExePath(path) {
    global g_IconList
    if !path || !g_IconList
        return -1
    shfi := Buffer(800, 0)
    if !DllCall("shell32\SHGetFileInfoW", "str", path, "uint", 0, "ptr", shfi, "uint", shfi.Size
        , "uint", 0x101) ; SHGFI_ICON | SHGFI_SMALLICON
        return -1
    hIcon := NumGet(shfi, 0, "ptr")
    if !hIcon
        return -1
    idx := DllCall("Comctl32\ImageList_ReplaceIcon", "ptr", g_IconList, "int", -1, "ptr", hIcon, "int")
    DllCall("DestroyIcon", "ptr", hIcon)
    return idx
}

GetIconIndexForHwnd(hwnd) {
    global g_IconList, g_HwndIconIdx
    if g_HwndIconIdx.Has(hwnd)
        return g_HwndIconIdx[hwnd]
    EnsureIconList()
    idxRaw := -1
    hSrc := GetWindowIconHandle(hwnd)
    if hSrc {
        hCpy := DllCall("user32\CopyIcon", "ptr", hSrc, "ptr")
        if hCpy {
            idxRaw := DllCall("Comctl32\ImageList_ReplaceIcon", "ptr", g_IconList, "int", -1, "ptr", hCpy, "int")
            ; ImageList_ReplaceIcon copies the icon; caller must always destroy CopyIcon() handle.
            DllCall("DestroyIcon", "ptr", hCpy)
        }
    }
    if idxRaw < 0 {
        pth := TryProcessPath(hwnd)
        idxRaw := IconFromExePath(pth)
    }
    ; Stored index is 1-based for legacy LV compat; ImageList_Draw uses 0-based.
    ah := (idxRaw >= 0) ? (idxRaw + 1) : 1
    g_HwndIconIdx[hwnd] := ah
    return ah
}

; 0xRRGGBB (AHK style) → Win32 COLORREF 0x00bbggrr.
ColorRefFromRgb(rgb) {
    r := (rgb >> 16) & 0xFF
    g := (rgb >> 8) & 0xFF
    b := rgb & 0xFF
    return r | (g << 8) | (b << 16)
}

; Dark non-client title (Win10 1809+ dark mode; Win11 22H2+ caption / border colors).
ApplyGuiTitlebarTheme(hwnd) {
    global THEME_BG, THEME_TEXT
    if !hwnd
        return
    if !DllCall("GetModuleHandle", "str", "dwmapi", "ptr")
        if !DllCall("LoadLibrary", "str", "dwmapi", "ptr")
            return
    DWMWA_USE_IMMERSIVE_DARK_MODE := 20
    DWMWA_BORDER_COLOR := 34
    DWMWA_CAPTION_COLOR := 35
    DWMWA_TEXT_COLOR := 36
    on := Buffer(4, 0)
    NumPut("int", 1, on, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", DWMWA_USE_IMMERSIVE_DARK_MODE, "ptr", on, "int", 4, "int")
    bg := ColorRefFromRgb(Integer("0x" THEME_BG))
    tx := ColorRefFromRgb(Integer("0x" THEME_TEXT))
    col := Buffer(4, 0)
    NumPut("uint", bg, col, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", DWMWA_CAPTION_COLOR, "ptr", col, "int", 4, "int")
    NumPut("uint", tx, col, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", DWMWA_TEXT_COLOR, "ptr", col, "int", 4, "int")
    NumPut("uint", bg, col, 0)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", DWMWA_BORDER_COLOR, "ptr", col, "int", 4, "int")
}

ThemeStyleButton(btn) {
    global THEME_BTN_BG, THEME_BTN_TEXT
    ; Use Text controls as buttons so dark background is reliable on Win11 themes.
    try btn.Opt("+Background" THEME_BTN_BG " +c" THEME_BTN_TEXT " +0x100 +0x200 Center")
}

ThemeStyleButtonHover(btn) {
    global THEME_BTN_HOVER, THEME_BTN_TEXT
    try btn.Opt("+Background" THEME_BTN_HOVER " +c" THEME_BTN_TEXT " +0x100 +0x200 Center")
}

ThemeStyleCloseButton(btn) {
    global THEME_CLOSE_BTN_BG, THEME_BTN_TEXT
    try btn.Opt("+Background" THEME_CLOSE_BTN_BG " +c" THEME_BTN_TEXT " +0x100 +0x200 Center")
}

ThemeStyleCloseButtonHover(btn) {
    global THEME_CLOSE_BTN_HOVER, THEME_BTN_TEXT
    try btn.Opt("+Background" THEME_CLOSE_BTN_HOVER " +c" THEME_BTN_TEXT " +0x100 +0x200 Center")
}

; Focus indicator: Text controls don't paint a Win32 focus rectangle, so we tint the background
; with the same selection blue used for list rows. Applies to all Text-as-button controls.
ThemeStyleButtonFocus(btn) {
    global THEME_SEL, THEME_BTN_TEXT
    try btn.Opt("+Background" THEME_SEL " +c" THEME_BTN_TEXT " +0x100 +0x200 Center")
}

; Names of Text controls that use ThemeStyleButton / hover / focus (Edit and mid-pane excluded).
HoverButtonNames() => [
    "BtnSearchClear", "BtnOpen", "BtnAdd", "BtnDel", "BtnClosePanel",
    "BtnStart", "BtnExplorer", "BtnDownloads", "BtnDesktop",
]

; Apply correct visual state to a single button. Priority: focus > hover > idle.
ApplyButtonVisual(name) {
    global g_Gui, g_HoverBtnName, g_FocusBtnName
    if !g_Gui || !name
        return
    c := g_Gui[name]
    if !c
        return
    try {
        if name = g_FocusBtnName
            ThemeStyleButtonFocus(c)
        else if name = g_HoverBtnName {
            if name = "BtnClosePanel"
                ThemeStyleCloseButtonHover(c)
            else
                ThemeStyleButtonHover(c)
        } else {
            if name = "BtnClosePanel"
                ThemeStyleCloseButton(c)
            else
                ThemeStyleButton(c)
        }
    }
}

ClearButtonHoverHighlight() {
    global g_HoverBtnName
    if !g_HoverBtnName
        return
    nm := g_HoverBtnName
    g_HoverBtnName := ""
    ApplyButtonVisual(nm)
}

ClearButtonFocusHighlight() {
    global g_FocusBtnName
    if !g_FocusBtnName
        return
    nm := g_FocusBtnName
    g_FocusBtnName := ""
    ApplyButtonVisual(nm)
}

HoverButtonPoll(*) {
    global g_PanelVisible, g_Gui, g_HoverBtnName, g_FocusBtnName
    if !g_PanelVisible || !g_Gui {
        SetTimer(HoverButtonPoll, 0)
        ClearButtonHoverHighlight()
        ClearButtonFocusHighlight()
        return
    }

    ; Resolve current focused button (if any).
    fh := DllCall("user32\GetFocus", "ptr")
    newFocus := ""
    if fh
        for nm in HoverButtonNames() {
            c := g_Gui[nm]
            if c && Integer(c.Hwnd) = Integer(fh) {
                newFocus := nm
                break
            }
        }

    ; Resolve current hovered button (if any).
    MouseGetPos(,,, &ctlHwnd, 2) ; Flag 2: OutputVarControl = HWND
    newHover := ""
    if ctlHwnd
        for nm in HoverButtonNames() {
            c := g_Gui[nm]
            if c && Integer(c.Hwnd) = Integer(ctlHwnd) {
                newHover := nm
                break
            }
        }

    if newFocus = g_FocusBtnName && newHover = g_HoverBtnName
        return

    oldFocus := g_FocusBtnName
    oldHover := g_HoverBtnName
    g_FocusBtnName := newFocus
    g_HoverBtnName := newHover

    ; Restyle every button whose effective state could have changed.
    affected := Map()
    if oldFocus
        affected[oldFocus] := true
    if oldHover
        affected[oldHover] := true
    if newFocus
        affected[newFocus] := true
    if newHover
        affected[newHover] := true
    for nm in affected
        ApplyButtonVisual(nm)
}

; --- Section header selection / highlight --------------------------------------
SecHdrSelect(i, *) {
    global g_SelectedSection
    g_SelectedSection := i
    UpdateSectionHighlights()
}

UpdateSectionHighlights() {
    global g_Gui
    if !g_Gui
        return
    MidPaneInvalidate()
}

; --- Monitor under mouse → work area (excludes taskbar; x/y are usable desktop left/top) ---
MonitorWorkAreaFromMouse(&l, &t, &r, &b, &w, &h) {
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "ptr", pt)
    mx := NumGet(pt, 0, "int"), my := NumGet(pt, 4, "int")
    mon := MonitorGetCount()
    Loop mon {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (mx >= ml && mx <= mr && my >= mt && my <= mb) {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            w := r - l, h := b - t
            return A_Index
        }
    }
    MonitorGetWorkArea(1, &l, &t, &r, &b)
    w := r - l, h := b - t
    return 1
}

BringToFrontNoActivate(hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd)
        return false
    ; SW_SHOWNOACTIVATE = 4 — show without activating (helps minimized/hidden targets)
    DllCall("user32\ShowWindow", "ptr", hwnd, "int", 4)
    return DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0
        , "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13, "int")
}

IsOurGuiWindow(hwnd) {
    global g_Gui
    if !g_Gui || !hwnd
        return false
    root := DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
    return root = g_Gui.Hwnd
}

; Hide panel when focus truly leaves (no periodic timer — WM_ACTIVATE on main GUI).
FocusCheck(*) {
    global g_PanelVisible, g_Gui, g_Drag, g_SuppressFocusHide, g_RebuildingGui
    if g_RebuildingGui ; mid-pane destroy/recreate — focus can leave briefly; do not auto-hide
        return
    if g_Drag ; drag: foreground flickers; never hide mid-drag
        return
    if g_SuppressFocusHide
        return
    if !g_PanelVisible || !g_Gui
        return
    try active := WinGetID("A")
    catch
        return
    if !active
        return
    if IsOurGuiWindow(active)
        return
    HidePanel()
}

PanelGuiActivate(wParam, lParam, msg, hwnd, *) {
    global g_Gui, WM_ACTIVATE
    if msg != WM_ACTIVATE || !g_Gui || Integer(hwnd) != Integer(g_Gui.Hwnd)
        return
    if (wParam & 0xFFFF) != 0 ; WA_INACTIVE = 0
        return
    FocusCheck()
}

PanelAppActivate(wParam, lParam, msg, hwnd, *) {
    global g_PanelVisible, WM_ACTIVATEAPP
    if msg != WM_ACTIVATEAPP || !g_PanelVisible
        return
    if wParam != 0 ; nonzero means app activated
        return
    FocusCheck()
}

IsWindowCloaked(hwnd) {
    cloaked := 0
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14
        , "int*", &cloaked, "uint", 4, "uint")
    return hr = 0 && cloaked != 0
}

EnumerateWindows() {
    global g_Gui
    list := WinGetList()
    myHwnd := g_Gui.Hwnd
    out := []
    for hwnd in list {
        hwnd := Integer(hwnd)
        if hwnd = myHwnd
            continue
        if !WinExist("ahk_id " hwnd)
            continue
        if !DllCall("IsWindowVisible", "ptr", hwnd)
            continue
        ex := WinGetExStyle("ahk_id " hwnd)
        if (ex & 0x80) ; WS_EX_TOOLWINDOW
            continue
        if IsWindowCloaked(hwnd)
            continue
        out.Push(hwnd)
    }
    return out
}

HwndInArr(arr, hwnd) {
    for x in arr
        if x = hwnd
            return true
    return false
}

SyncMaps(allOpen) {
    global g_HwndToSection, g_Order
    u := UncatIdx()
    for h in allOpen {
        if !g_HwndToSection.Has(h) {
            g_HwndToSection[h] := u
            secOrd := SecOrder(u)
            if !HwndInArr(secOrd, h)
                secOrd.Push(h)
        }
    }
    toDel := []
    for hwnd in g_HwndToSection {
        found := false
        for h in allOpen
            if h = hwnd {
                found := true
                break
            }
        if !found
            toDel.Push(hwnd)
    }
    for hwnd in toDel {
        g_HwndToSection.Delete(hwnd)
        RemoveHwndFromOrders(hwnd)
    }
}

SectionIndexOf(hwnd) {
    global g_HwndToSection
    u := UncatIdx()
    return g_HwndToSection.Has(hwnd) ? Integer(g_HwndToSection[hwnd]) : u
}

TitleOk(hwnd) {
    global g_Filter
    try t := WinGetTitle("ahk_id " hwnd)
    catch
        t := ""
    if t != ""
        return InStr(StrLower(t), g_Filter) != 0
    try exe := WinGetProcessName("ahk_id " hwnd)
    catch
        exe := ""
    return InStr(StrLower(exe), g_Filter) != 0
}

WinRowTitle(hwnd) {
    try title := WinGetTitle("ahk_id " hwnd)
    catch
        title := ""
    if title = ""
        try title := WinGetProcessName("ahk_id " hwnd)
        catch
            title := ""
    if title = ""
        title := "(untitled)"
    return title
}

JoinHwnds(arr) {
    s := ""
    for h in arr
        s .= (s ? "," : "") h
    return s
}

BuildRowModelFromPlan(plan) {
    global g_Sections, g_RowModel, g_WindowRowIndexByHwnd, g_RowModelIndexBySecRow, g_RowHwndsBySection
    rows := []
    idxByHwnd := Map()
    idxBySecRow := Map()
    bySec := Map()
    for i, s in g_Sections {
        bySec[i] := []
        rows.Push({ type: "section", sec: i, name: s.name, expanded: s.expanded, locked: s.locked })
        if !s.expanded
            continue
        planOrd := plan.Has(i) ? plan[i] : []
        for wi, hwnd in planOrd {
            r := {
                type: "window",
                sec: i,
                hwnd: hwnd,
                row: wi,
                title: WinRowTitle(hwnd),
                icon: GetIconIndexForHwnd(hwnd)
            }
            rows.Push(r)
            idxByHwnd[hwnd] := rows.Length
            idxBySecRow[i ":" wi] := rows.Length
            bySec[i].Push(hwnd)
        }
    }
    g_RowModel := rows
    g_WindowRowIndexByHwnd := idxByHwnd
    g_RowModelIndexBySecRow := idxBySecRow
    g_RowHwndsBySection := bySec
}

FingerprintSortedOpen(allOpen) {
    a := []
    for h in allOpen
        a.Push(h)
    n := a.Length
    if n < 2
        return JoinHwnds(a)
    Loop n {
        swapped := false
        Loop n - 1 {
            j := A_Index
            if a[j] > a[j + 1] {
                t := a[j], a[j] := a[j + 1], a[j + 1] := t
                swapped := true
            }
        }
        if !swapped
            break
    }
    return JoinHwnds(a)
}

RefreshLists(*) {
    global g_Sections, g_Gui, g_Search, g_Filter, g_HwndToSection, g_Order
    global g_Drag, g_PanelVisible, g_LastListSig, g_SelectedHwnd, g_RebuildingGui, g_FilterExpandBackup
    if !g_Gui
        return
    if g_Drag || g_RebuildingGui
        return
    prevFilter := g_Filter
    g_Filter := StrLower(Trim(g_Search.Value))
    if prevFilter != "" && g_Filter = "" {
        if Type(g_FilterExpandBackup) = "Map" {
            for i, s in g_Sections {
                if g_FilterExpandBackup.Has(i)
                    s.expanded := g_FilterExpandBackup[i]
            }
        }
        g_FilterExpandBackup := 0
        g_LastListSig := "" ; expanded state is not in list sig — force relayout after restore
    } else if prevFilter = "" && g_Filter != "" {
        g_FilterExpandBackup := Map()
        for i, s in g_Sections {
            g_FilterExpandBackup[i] := s.expanded
            s.expanded := true
        }
    } else if g_Filter != "" {
        for i, s in g_Sections
            s.expanded := true
    }
    allOpen := EnumerateWindows()
    SyncMaps(allOpen)

    plan := Map()
    for i, s in g_Sections {
        newOrd := []
        secOrd := SecOrder(i)
        for hwnd in secOrd {
            if !WinExist("ahk_id " hwnd)
                continue
            if SectionIndexOf(hwnd) != i
                continue
            if g_Filter != "" && !TitleOk(hwnd)
                continue
            newOrd.Push(hwnd)
        }
        for hwnd in allOpen {
            if SectionIndexOf(hwnd) != i
                continue
            if HwndInArr(newOrd, hwnd)
                continue
            if g_Filter != "" && !TitleOk(hwnd)
                continue
            newOrd.Push(hwnd)
        }
        plan[i] := newOrd
    }

    sig := g_Filter "`n" FingerprintSortedOpen(allOpen) "`n"
    for i, s in g_Sections
        sig .= i ":" JoinHwnds(plan.Has(i) ? plan[i] : []) "`n"
    expandForced := false
    if g_Filter != "" {
        for i, s in g_Sections {
            if !s.expanded {
                s.expanded := true
                expandForced := true
            }
        }
    }
    if g_PanelVisible && (sig = g_LastListSig) && !expandForced
        return
    g_LastListSig := sig

    for i, s in g_Sections {
        if !plan.Has(i)
            continue

        newOrd := plan[i]

        ; Only canonicalize order when not filtering.
        ; Filtering must never destroy the user's saved section/window order.
        if g_Filter = ""
            g_Order[i] := newOrd

    }
    BuildRowModelFromPlan(plan)
    ; Apply selection before LayoutPanel so one paint shows the correct highlight (no extra MidPaneInvalidate).
    rows := VisibleWindowRows()
    if rows.Length {
        keepIdx := 0
        if g_SelectedHwnd {
            for i, r in rows
                if Integer(r.hwnd) = Integer(g_SelectedHwnd) {
                    keepIdx := i
                    break
                }
        }
        if keepIdx > 0
            SelectPanelWindowByIndex(keepIdx, false, false)
        else if !SearchHasFocus()
            SelectPanelWindowByIndex(1, false, false)
    } else
        g_SelectedHwnd := 0
    if g_Gui && g_MidPane
        LayoutPanel()
}

SearchHasFocus() {
    global g_Search
    if !g_Search
        return false
    fh := DllCall("user32\GetFocus", "ptr")
    return fh && (Integer(fh) = Integer(g_Search.Hwnd) || DllCall("user32\IsChild", "ptr", g_Search.Hwnd, "ptr", fh))
}

SearchChanged(*) {
    ; Debounce text filtering so quick typing does not trigger jittery rebuilds.
    SetTimer(RefreshLists, -80)
}

SearchClearClick(*) {
    global g_Search
    if !g_Search
        return
    if Trim(g_Search.Value) = ""
        return
    SetTimer(RefreshLists, 0)
    try g_Search.Value := ""
    RefreshLists()
    try g_Search.Focus()
}

MidPaneInvalidate() {
    global g_MidPane
    if !g_MidPane
        return
    DllCall("user32\InvalidateRect", "ptr", g_MidPane.Hwnd, "ptr", 0, "int", 0)
}

FocusMidPaneRows() {
    global g_MidPane
    if !g_MidPane
        return
    try DllCall("user32\SetFocus", "ptr", g_MidPane.Hwnd, "ptr")
}

FontPx(pt) {
    dpi := A_ScreenDPI ? A_ScreenDPI : 96
    return -Round(pt * dpi / 72.0)
}

CreateUiFont(weight, pt) {
    h := DllCall("gdi32\CreateFontW"
        , "int", FontPx(pt), "int", 0, "int", 0, "int", 0
        , "int", weight, "uint", 0, "uint", 0, "uint", 0, "uint", 0, "uint", 0, "uint", 5, "uint", 0, "uint", 0
        , "str", "Segoe UI Variable Text", "ptr")
    if !h
        h := DllCall("gdi32\CreateFontW"
            , "int", FontPx(pt), "int", 0, "int", 0, "int", 0
            , "int", weight, "uint", 0, "uint", 0, "uint", 0, "uint", 0, "uint", 0, "uint", 5, "uint", 0, "uint", 0
            , "str", "Segoe UI", "ptr")
    return h
}

MidPaneUiFont() {
    static hFont := 0
    if !hFont
        hFont := CreateUiFont(400, 10.5)
    return hFont
}

MidPaneHitTestWindowRow(cx, cy, &sec, &row, &wh) {
    global g_WindowRowClientRects
    sec := 0, row := 0, wh := 0
    for rr in g_WindowRowClientRects {
        if cx >= rr.l && cx <= rr.r && cy >= rr.t && cy <= rr.b {
            sec := rr.sec, row := rr.row, wh := rr.hwnd
            return true
        }
    }
    return false
}

RowModelIndexFromSecRow(sec, row) {
    global g_RowModelIndexBySecRow
    return g_RowModelIndexBySecRow.Has(sec ":" row) ? g_RowModelIndexBySecRow[sec ":" row] : 0
}

; Visible window HWNDs per section in row-model order (matches layout/hit-test when filter narrows the list).
RowModelSecWindowHwnds(secIdx) {
    global g_RowHwndsBySection
    return g_RowHwndsBySection.Has(secIdx) ? g_RowHwndsBySection[secIdx] : []
}

ActivateHwndFromPanel(hwnd, closePanel := true) {
    global g_SuppressFocusHide
    if !hwnd || !WinExist("ahk_id " hwnd)
        return
    if !closePanel
        g_SuppressFocusHide := true
    WinActivate("ahk_id " hwnd)
    if !closePanel
        KeepPanelTopNoActivate()
    if closePanel
        HidePanel()
}

PanelOutsideClickClose(*) {
    global g_PanelVisible, g_Gui, g_Drag, g_MidClickRow
    if !g_PanelVisible || g_Drag || g_MidClickRow
        return
    if !g_Gui
        return
    ; Any click inside the panel's outer window rect (including empty client area) must not dismiss.
    pt := Buffer(8, 0)
    DllCall("user32\GetCursorPos", "ptr", pt)
    mx := NumGet(pt, 0, "int"), my := NumGet(pt, 4, "int")
    WinGetPos(&gx, &gy, &gww, &ghh, "ahk_id " g_Gui.Hwnd)
    if mx >= gx && mx < gx + gww && my >= gy && my < gy + ghh
        return
    HidePanel()
}

KeepPanelTopNoActivate() {
    global g_Gui, g_PanelVisible
    if !g_PanelVisible || !g_Gui
        return
    ; HWND_TOPMOST(-1) + NOMOVE|NOSIZE|NOACTIVATE keeps panel above normal windows.
    DllCall("user32\SetWindowPos", "ptr", g_Gui.Hwnd, "ptr", -1
        , "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13, "int")
}

HandleMidPaneRowLeftClick(mc) {
    global g_SkipClickUntil, g_SelectedHwnd
    if A_TickCount < g_SkipClickUntil
        return
    modelIdx := RowModelIndexFromSecRow(mc.sec, mc.row)
    if modelIdx > 0
        SelectPanelWindowByRowModelIndex(modelIdx, false)
    ActivateHwndFromPanel(g_SelectedHwnd, false)
    SetTimer(RestorePanelRowFocusAfterActivate, -1)
}

RestorePanelRowFocusAfterActivate(*) {
    global g_PanelVisible, g_Drag, g_SuppressFocusHide
    if !g_PanelVisible || g_Drag {
        g_SuppressFocusHide := false
        return
    }
    FocusMidPaneRows()
    MidPaneInvalidate()
    g_SuppressFocusHide := false
}

VisibleWindowRows() {
    global g_RowModel
    out := []
    for r in g_RowModel {
        if r.type != "window"
            continue
        out.Push({ sec: r.sec, row: r.row, hwnd: r.hwnd })
    }
    return out
}

VisibleWindowRowModelIndices() {
    global g_RowModel
    idxs := []
    for i, r in g_RowModel {
        if r.type = "window"
            idxs.Push(i)
    }
    return idxs
}

; Auto-scroll the selected row into the viewport (with a small padding) when keyboard
; navigation, filter changes, or other state changes move the selection off-screen.
; Returns true when scroll position changed (caller can then skip a redundant invalidate
; because LayoutPanel already invalidates).
EnsureSelectedWindowVisible() {
    global g_SelectedHwnd, g_WindowRowClientRects
    global g_ScrollY, g_ScrollContentH, g_ScrollViewportH, LV_ROW_HEIGHT

    if !g_SelectedHwnd || g_ScrollViewportH <= 0
        return false

    for rr in g_WindowRowClientRects {
        if Integer(rr.hwnd) != Integer(g_SelectedHwnd)
            continue

        pad := Max(4, LV_ROW_HEIGHT // 4)
        maxS := Max(0, g_ScrollContentH - g_ScrollViewportH)
        newY := g_ScrollY

        if rr.t < pad
            newY := Max(0, g_ScrollY + rr.t - pad)
        else if rr.b > g_ScrollViewportH - pad
            newY := Min(maxS, g_ScrollY + rr.b - g_ScrollViewportH + pad)

        if newY != g_ScrollY {
            g_ScrollY := newY
            LayoutPanel()
            return true
        }
        return false
    }
    return false
}

SelectPanelWindowByRowModelIndex(modelIdx, focusList := true, repaint := true) {
    global g_RowModel, g_SelectedHwnd, g_ActiveSec
    if modelIdx < 1 || modelIdx > g_RowModel.Length
        return false
    r := g_RowModel[modelIdx]
    if r.type != "window"
        return false
    g_SelectedHwnd := r.hwnd
    g_ActiveSec := r.sec

    scrolled := EnsureSelectedWindowVisible()

    if repaint && !scrolled
        MidPaneInvalidate()
    if focusList
        FocusMidPaneRows()
    return true
}

SelectPanelWindowByIndex(idx, focusLv := true, repaint := true) {
    idxs := VisibleWindowRowModelIndices()
    if !idxs.Length
        return false
    if idx < 1
        idx := 1
    else if idx > idxs.Length
        idx := idxs.Length
    return SelectPanelWindowByRowModelIndex(idxs[idx], focusLv, repaint)
}

SelectFirstPanelWindow(focusLv := true) {
    return SelectPanelWindowByIndex(1, focusLv)
}

MovePanelSelection(delta) {
    global g_SelectedHwnd, g_WindowRowIndexByHwnd
    idxs := VisibleWindowRowModelIndices()
    if !idxs.Length
        return false
    cur := 0
    if g_SelectedHwnd && g_WindowRowIndexByHwnd.Has(g_SelectedHwnd) {
        m := g_WindowRowIndexByHwnd[g_SelectedHwnd]
        for i, v in idxs
            if v = m {
                cur := i
                break
            }
    }
    if !cur
        cur := 1
    nxt := cur + delta
    if nxt < 1
        nxt := 1
    else if nxt > idxs.Length
        nxt := idxs.Length
    ok := SelectPanelWindowByRowModelIndex(idxs[nxt], true)
    if ok
        ; Debounced so holding Up/Down doesn't WinActivate every intermediate row.
        SetTimer(ArrowKeyActivateSelected, -60)
    return ok
}

ArrowKeyActivateSelected(*) {
    global g_PanelVisible, g_Drag, g_SelectedHwnd
    if !g_PanelVisible || g_Drag || !g_SelectedHwnd
        return
    ActivateHwndFromPanel(g_SelectedHwnd, false)
    SetTimer(RestorePanelRowFocusAfterActivate, -1)
}

; PgUp/PgDn move by one viewport-worth of rows minus one, so the previously bottom-most
; (or top-most) row stays anchored for context after the page.
MovePanelSelectionByPage(dir) {
    global LV_ROW_HEIGHT, g_ScrollViewportH
    rows := Max(1, Floor(g_ScrollViewportH / LV_ROW_HEIGHT) - 1)
    return MovePanelSelection(dir * rows)
}

; Home/End jump-to-first/jump-to-last with the same preview-activation debounce as arrow keys.
PanelKeyboardJumpTo(idx) {
    if SelectPanelWindowByIndex(idx, true)
        SetTimer(ArrowKeyActivateSelected, -60)
}

FocusCycle(forward := 1) {
    global g_Gui, g_Search, g_MidPane
    if !g_Gui
        return
    fh := DllCall("user32\GetFocus", "ptr")
    lvFocused := false
    if g_MidPane && fh && (Integer(fh) = Integer(g_MidPane.Hwnd) || DllCall("user32\IsChild", "ptr", g_MidPane.Hwnd, "ptr", fh))
        lvFocused := true
    chain := ["SearchEdit", "BtnSearchClear", "BtnOpen", "BtnAdd", "BtnDel", "BtnClosePanel", "BtnStart", "BtnExplorer", "BtnDownloads", "BtnDesktop"]
    if lvFocused {
        if forward > 0 {
            try g_Search.Focus()
        } else
            try g_Gui["BtnDesktop"].Focus()
        return
    }
    cur := 0
    for i, nm in chain {
        c := g_Gui[nm]
        if !c
            continue
        if fh && (Integer(fh) = Integer(c.Hwnd) || DllCall("user32\IsChild", "ptr", c.Hwnd, "ptr", fh)) {
            cur := i
            break
        }
    }
    nxt := cur + (forward > 0 ? 1 : -1)
    if nxt < 1 || nxt > chain.Length {
        SelectFirstPanelWindow(true)
        return
    }
    try g_Gui[chain[nxt]].Focus()
}

PanelEnter(*) {
    global g_Gui, g_SelectedHwnd, g_Search, g_MidPane
    if !g_Gui
        return
    fh := DllCall("user32\GetFocus", "ptr")
    if !fh
        return

    ; Mid-pane list surface has focus: Enter opens the selected window and closes the panel.
    if g_MidPane && (Integer(fh) = Integer(g_MidPane.Hwnd) || DllCall("user32\IsChild", "ptr", g_MidPane.Hwnd, "ptr", fh)) {
        if !g_SelectedHwnd
            SelectFirstPanelWindow(true)
        ActivateHwndFromPanel(g_SelectedHwnd, true)
        return
    }

    ; If search has focus, Enter applies current filter and jumps back to first row.
    if g_Search && (Integer(fh) = Integer(g_Search.Hwnd) || DllCall("user32\IsChild", "ptr", g_Search.Hwnd, "ptr", fh)) {
        RefreshLists()
        SelectFirstPanelWindow(true)
        return
    }

    ; Button focus -> execute action directly.
    for nm in ["BtnSearchClear", "BtnOpen", "BtnAdd", "BtnDel", "BtnClosePanel", "BtnStart", "BtnExplorer", "BtnDownloads", "BtnDesktop"] {
        c := g_Gui[nm]
        if !c
            continue
        if Integer(fh) = Integer(c.Hwnd) || DllCall("user32\IsChild", "ptr", c.Hwnd, "ptr", fh) {
            if nm = "BtnSearchClear"
                SearchClearClick()
            else if nm = "BtnOpen"
                BtnOpen()
            else if nm = "BtnAdd"
                BtnAddSection()
            else if nm = "BtnDel"
                BtnDelSection()
            else if nm = "BtnClosePanel"
                HidePanel()
            else if nm = "BtnStart"
                BtnStart()
            else if nm = "BtnExplorer"
                BtnExplorer()
            else if nm = "BtnDownloads"
                BtnDownloads()
            else if nm = "BtnDesktop"
                BtnDesktop()
            return
        }
    }
}

; While capture is on g_Gui: drag threshold + button-up without 10 ms polling.
DragTrackMouseMove(wParam, lParam, msg, hwnd, *) {
    global g_Gui, g_MidClickRow, g_Drag, WM_MOUSEMOVE, VK_LBUTTON
    ; Message hwnd may be a child (e.g. mid-pane); capture is still on g_Gui.
    if msg != WM_MOUSEMOVE || !g_Gui || !IsOurGuiWindow(hwnd)
        return
    if !g_MidClickRow && !g_Drag
        return
    cap := DllCall("user32\GetCapture", "ptr")
    if !cap || Integer(cap) != Integer(g_Gui.Hwnd)
        return
    if !(DllCall("user32\GetAsyncKeyState", "int", VK_LBUTTON) & 0x8000) {
        if g_Drag {
            DragFinishFromCursor()
        } else if g_MidClickRow {
            mc := g_MidClickRow
            g_MidClickRow := 0
            DllCall("user32\ReleaseCapture")
            HandleMidPaneRowLeftClick(mc)
        }
        return
    }
    if g_MidClickRow && !g_Drag {
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "ptr", pt)
        mx := NumGet(pt, 0, "int"), my := NumGet(pt, 4, "int")
        dx := mx - g_MidClickRow.mx, dy := my - g_MidClickRow.my
        if (dx * dx + dy * dy) > 36 {
            g_Drag := { fromIdx: g_MidClickRow.sec, hwnd: g_MidClickRow.hwnd, fromRow: g_MidClickRow.row }
            g_MidClickRow := 0
        }
    }
}

MidPaneLButtonDown(wParam, lParam, msg, hwnd, *) {
    static hdrDblSec := 0, hdrDblTick := 0
    global g_MidPane, g_Drag, g_MidClickRow, g_Gui, WM_LBUTTONDOWN
    if msg != WM_LBUTTONDOWN || !g_MidPane || Integer(hwnd) != Integer(g_MidPane.Hwnd)
        return
    if g_Drag || g_MidClickRow
        return
    cx := lParam & 0xFFFF
    cy := (lParam >> 16) & 0xFFFF
    if cx > 32767
        cx -= 65536
    if cy > 32767
        cy -= 65536
    sec := 0, inChev := false
    if MidPaneHitTestSectionHeader(cx, cy, &sec, &inChev) {
        if inChev {
            hdrDblSec := 0, hdrDblTick := 0
            ToggleExpand(sec)
            return
        }
        if sec = hdrDblSec && (A_TickCount - hdrDblTick) < 400 {
            hdrDblSec := 0
            hdrDblTick := 0
            ToggleExpand(sec)
            return
        }
        hdrDblSec := sec
        hdrDblTick := A_TickCount
        SecHdrSelect(sec)
        return
    }
    sec := 0, row := 0, wh := 0
    if !MidPaneHitTestWindowRow(cx, cy, &sec, &row, &wh)
        return
    hdrDblSec := 0, hdrDblTick := 0
    pt := Buffer(8, 0)
    DllCall("user32\GetCursorPos", "ptr", pt)
    g_MidClickRow := { sec: sec, row: row, hwnd: wh, mx: NumGet(pt, 0, "int"), my: NumGet(pt, 4, "int") }
    DllCall("user32\SetCapture", "ptr", g_Gui.Hwnd)
}

DragDropFindTarget(mx, my, &tgtIdx, &tgtRow) {
    local cx, cy
    global g_SectionHeaderClientRects, g_WindowRowClientRects, g_SectionListBands
    tgtIdx := 0
    tgtRow := 0
    if !MidPaneClientPointFromScreen(mx, my, &cx, &cy)
        return false
    for si, rc in g_SectionHeaderClientRects {
        if cx >= rc.l && cx <= rc.r && cy >= rc.t && cy <= rc.b {
            tgtIdx := si
            tgtRow := SecOrder(si).Length + 1
            return true
        }
    }
    for rr in g_WindowRowClientRects {
        if cx >= rr.l && cx <= rr.r && cy >= rr.t && cy <= rr.b {
            tgtIdx := rr.sec
            tgtRow := rr.row
            return true
        }
    }
    for si, band in g_SectionListBands {
        if cx < band.l || cx > band.r || cy < band.t || cy > band.b
            continue
        rows := []
        for rr in g_WindowRowClientRects
            if rr.sec = si
                rows.Push(rr)
        if !rows.Length {
            tgtIdx := si
            tgtRow := 1
            return true
        }
        ins := rows.Length + 1
        for rr in rows {
            mid := (rr.t + rr.b) // 2
            if cy < mid {
                ins := rr.row
                break
            }
        }
        tgtIdx := si
        tgtRow := ins
        return true
    }
    return false
}

MidPaneClientPointFromScreen(mx, my, &cx, &cy) {
    global g_MidPane
    cx := 0, cy := 0
    if !g_MidPane
        return false
    pt := Buffer(8, 0)
    NumPut("int", mx, pt, 0)
    NumPut("int", my, pt, 4)
    if !DllCall("user32\ScreenToClient", "ptr", g_MidPane.Hwnd, "ptr", pt)
        return false
    cx := NumGet(pt, 0, "int")
    cy := NumGet(pt, 4, "int")
    return true
}

MButtonOverPanelRows() {
    local mx, my, cx, cy, sec, row, wh
    global g_PanelVisible, g_MidPane
    if !g_PanelVisible || !g_MidPane
        return false
    MouseGetPos(&mx, &my)
    if !WinRectContainsScreen(g_MidPane.Hwnd, mx, my)
        return false
    if !MidPaneClientPointFromScreen(mx, my, &cx, &cy)
        return false
    sec := 0, row := 0, wh := 0
    return MidPaneHitTestWindowRow(cx, cy, &sec, &row, &wh)
}

MidPaneMiddleClickClose(*) {
    local mx, my, cx, cy, sec, row, wh
    global g_MidPane, g_ActiveSec
    if !g_MidPane
        return
    MouseGetPos(&mx, &my)
    if !MidPaneClientPointFromScreen(mx, my, &cx, &cy)
        return
    sec := 0, row := 0, wh := 0
    if !MidPaneHitTestWindowRow(cx, cy, &sec, &row, &wh)
        return
    g_ActiveSec := sec
    modelIdx := RowModelIndexFromSecRow(sec, row)
    if modelIdx > 0
        SelectPanelWindowByRowModelIndex(modelIdx, false)
    CloseSelectedPanelWindow()
}

CloseSelectedPanelWindow(*) {
    global g_SelectedHwnd
    hwnd := g_SelectedHwnd
    if !hwnd || !WinExist("ahk_id " hwnd)
        return
    BringToFrontNoActivate(hwnd)
    if CloseNeedsUserConfirm(hwnd) {
        ttl := WinRowTitle(hwnd)
        if MsgBox(
                "This program often opens Save / Don’t save / other dialogs when a window closes.`n`n"
                ttl "`n`nSend a normal close request (WM_CLOSE) to this window?",
                "Confirm close",
                "YesNo Icon? Default2") != "Yes"
            return
    }
    PostMessage(0x10, 0, 0, hwnd) ; WM_CLOSE — async; many apps honor it
    SetTimer(RefreshLists, -750)
}

DragFinishFromCursor() {
    global g_Drag, g_Gui, g_HwndToSection, g_Order, g_SkipClickUntil
    if !g_Drag
        return
    d := g_Drag
    g_Drag := 0
    g_SkipClickUntil := A_TickCount + 250
    cap := DllCall("user32\GetCapture", "ptr")
    if cap && IsOurGuiWindow(cap)
        DllCall("user32\ReleaseCapture")

    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "ptr", pt)
    mx := NumGet(pt, 0, "int"), my := NumGet(pt, 4, "int")

    tgtIdx := 0, tgtRow := 0
    if !DragDropFindTarget(mx, my, &tgtIdx, &tgtRow) {
        RefreshLists()
        return
    }

    srcIdx := d.fromIdx
    hwnd := d.hwnd
    g_HwndToSection[hwnd] := tgtIdx

    if srcIdx = tgtIdx {
        secOrd := RemoveVal(CloneArr(SecOrder(srcIdx)), hwnd)
        pos := tgtRow
        if d.fromRow < pos ; insert index is relative to list that still included the dragged row
            pos -= 1
        if pos < 1
            pos := 1
        if pos > secOrd.Length + 1
            pos := secOrd.Length + 1
        g_Order[srcIdx] := InsertAt(secOrd, pos, hwnd)
    } else {
        g_Order[srcIdx] := RemoveVal(SecOrder(srcIdx), hwnd)
        tord := RemoveVal(CloneArr(SecOrder(tgtIdx)), hwnd)
        pos := Min(tgtRow, tord.Length + 1)
        if pos < 1
            pos := 1
        g_Order[tgtIdx] := InsertAt(tord, pos, hwnd)
    }
    if tgtIdx >= 1 && tgtIdx <= g_Sections.Length
        g_Sections[tgtIdx].expanded := true
    ; Single RefreshLists → one LayoutPanel + paint (avoid triple repaint from old PostDragVisualSync).
    RefreshLists()
}

; WM_LBUTTONUP on panel (capture may target GUI or mid-pane).
DragPanelLButtonUp(wParam, lParam, msg, hwnd, *) {
    global g_Drag, g_MidClickRow, g_Gui, WM_LBUTTONUP
    if msg != WM_LBUTTONUP || !g_Gui
        return
    if !IsOurGuiWindow(hwnd)
        return
    if g_Drag {
        DragFinishFromCursor()
        return
    }
    if g_MidClickRow {
        mc := g_MidClickRow
        g_MidClickRow := 0
        cap := DllCall("user32\GetCapture", "ptr")
        if cap && IsOurGuiWindow(cap)
            DllCall("user32\ReleaseCapture")
        HandleMidPaneRowLeftClick(mc)
    }
}

HiWordSigned(wParam) {
    u := (wParam >> 16) & 0xFFFF
    return u > 32767 ? u - 65536 : u
}

WinRectContainsScreen(hwnd, mx, my) {
    rect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", rect)
        return false
    L := NumGet(rect, 0, "int"), T := NumGet(rect, 4, "int")
    R := NumGet(rect, 8, "int"), B := NumGet(rect, 12, "int")
    return (mx >= L && mx <= R && my >= T && my <= B)
}

; Mid-pane outer width includes the v-scrollbar; header controls use the client width.
MidPaneClientW() {
    global g_MidPane
    if !g_MidPane
        return 0
    rc := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", g_MidPane.Hwnd, "ptr", rc)
        return 0
    return NumGet(rc, 8, "int") - NumGet(rc, 0, "int")
}

MidPaneApplyScrollInfo() {
    global g_MidPane, g_ScrollY, g_ScrollContentH, g_ScrollViewportH
    if !g_MidPane
        return
    h := g_MidPane.Hwnd
    if g_ScrollContentH <= g_ScrollViewportH {
        DllCall("user32\ShowScrollBar", "ptr", h, "int", 1, "int", 0)
        return
    }
    DllCall("user32\ShowScrollBar", "ptr", h, "int", 1, "int", 1)
    si := Buffer(28, 0)
    NumPut("uint", 28, si, 0)
    NumPut("uint", 0x1 | 0x2 | 0x4, si, 4) ; RANGE | PAGE | POS
    NumPut("int", 0, si, 8)
    NumPut("int", g_ScrollContentH - 1, si, 12)
    NumPut("uint", g_ScrollViewportH, si, 16)
    NumPut("int", g_ScrollY, si, 20)
    DllCall("user32\SetScrollInfo", "ptr", h, "int", 1, "ptr", si, "int", 1)
}

; After repositioning (scroll / expand / drag), invalidate mid-pane (subclass WM_PAINT draws everything).
MidPaneRefreshPaint() {
    global g_MidPane
    if !g_MidPane
        return
    h := g_MidPane.Hwnd
    DllCall("user32\InvalidateRect", "ptr", h, "ptr", 0, "int", 0)
}

MidPaneHdrBoldFont() {
    static hFont := 0
    if !hFont
        hFont := CreateUiFont(650, 10.5)
    return hFont
}

PaintMidPaneClient(hdc, hwnd) {
    global g_RowModel, g_Sections, g_SectionHeaderClientRects, g_WindowRowClientRects, g_SelectedHwnd, g_SelectedSection, g_IconList
    global THEME_PANEL, THEME_HDR, THEME_SEL, THEME_TEXT, ICON_SIZE, LV_ROW_HEIGHT, THEME_LV_BG, THEME_LV_TEXT, MID_PANE_CHEV_W
    static brPanel := 0, brHdr := 0, brSel := 0, brLv := 0
    static panelRgb := "", hdrRgb := "", selRgbRef := "", lvRgb := ""
    rc := Buffer(16, 0)
    DllCall("user32\GetClientRect", "ptr", hwnd, "ptr", rc)
    cliH := NumGet(rc, 12, "int") - NumGet(rc, 4, "int")
    panelNow := ColorRefFromRgb(Integer("0x" THEME_PANEL))
    hdrNow := ColorRefFromRgb(Integer("0x" THEME_HDR))
    selNow := ColorRefFromRgb(Integer("0x" THEME_SEL))
    lvNow := ColorRefFromRgb(THEME_LV_BG)
    if !brPanel || panelNow != panelRgb {
        if brPanel
            DllCall("gdi32\DeleteObject", "ptr", brPanel)
        brPanel := DllCall("gdi32\CreateSolidBrush", "uint", panelNow, "ptr")
        panelRgb := panelNow
    }
    if !brHdr || hdrNow != hdrRgb {
        if brHdr
            DllCall("gdi32\DeleteObject", "ptr", brHdr)
        brHdr := DllCall("gdi32\CreateSolidBrush", "uint", hdrNow, "ptr")
        hdrRgb := hdrNow
    }
    if !brSel || selNow != selRgbRef {
        if brSel
            DllCall("gdi32\DeleteObject", "ptr", brSel)
        brSel := DllCall("gdi32\CreateSolidBrush", "uint", selNow, "ptr")
        selRgbRef := selNow
    }
    if !brLv || lvNow != lvRgb {
        if brLv
            DllCall("gdi32\DeleteObject", "ptr", brLv)
        brLv := DllCall("gdi32\CreateSolidBrush", "uint", lvNow, "ptr")
        lvRgb := lvNow
    }
    DllCall("user32\FillRect", "ptr", hdc, "ptr", rc, "ptr", brPanel)
    DllCall("gdi32\SetBkMode", "ptr", hdc, "int", 1) ; TRANSPARENT
    txtRgb := ColorRefFromRgb(Integer("0x" THEME_TEXT))
    DT_LEFT := 0x0, DT_VCENTER := 0x4, DT_SINGLELINE := 0x20, DT_END_ELLIPSIS := 0x8000
    for i, s in g_Sections {
        if !g_SectionHeaderClientRects.Has(i)
            continue
        hr := g_SectionHeaderClientRects[i]
        if hr.b < 0 || hr.t > cliH
            continue
        sel := (i = g_SelectedSection)
        rrFill := Buffer(16, 0)
        NumPut("int", hr.l, rrFill, 0)
        NumPut("int", hr.t, rrFill, 4)
        NumPut("int", hr.r + 1, rrFill, 8)
        NumPut("int", hr.b + 1, rrFill, 12)
        DllCall("user32\FillRect", "ptr", hdc, "ptr", rrFill, "ptr", (sel ? brSel : brHdr))
        DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", txtRgb)
        chev := s.expanded ? "▼" : "▶"
        trChev := Buffer(16, 0)
        NumPut("int", hr.l + 2, trChev, 0)
        NumPut("int", hr.t, trChev, 4)
        NumPut("int", hr.l + MID_PANE_CHEV_W - 2, trChev, 8)
        NumPut("int", hr.b, trChev, 12)
        oldF := DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", MidPaneUiFont(), "ptr")
        DllCall("user32\DrawTextW", "ptr", hdc, "str", chev, "int", -1, "ptr", trChev, "uint", DT_LEFT | DT_VCENTER | DT_SINGLELINE)
        trNm := Buffer(16, 0)
        NumPut("int", hr.l + MID_PANE_CHEV_W + 4, trNm, 0)
        NumPut("int", hr.t, trNm, 4)
        NumPut("int", hr.r - 4, trNm, 8)
        NumPut("int", hr.b, trNm, 12)
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", MidPaneHdrBoldFont(), "ptr")
        DllCall("user32\DrawTextW", "ptr", hdc, "str", s.name, "int", -1, "ptr", trNm, "uint", DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldF, "ptr")
    }
    DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", ColorRefFromRgb(THEME_LV_TEXT))
    oldRowFont := DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", MidPaneUiFont(), "ptr")
    for rr in g_WindowRowClientRects {
        if rr.b < 0 || rr.t > cliH
            continue
        sel := g_SelectedHwnd && Integer(g_SelectedHwnd) = Integer(rr.hwnd)
        rrFill := Buffer(16, 0)
        NumPut("int", rr.l, rrFill, 0)
        NumPut("int", rr.t, rrFill, 4)
        NumPut("int", rr.r + 1, rrFill, 8)
        NumPut("int", rr.b + 1, rrFill, 12)
        DllCall("user32\FillRect", "ptr", hdc, "ptr", rrFill, "ptr", (sel ? brSel : brLv))
        modelIdx := RowModelIndexFromSecRow(rr.sec, rr.row)
        if g_IconList {
            ih := modelIdx > 0 && HasProp(g_RowModel[modelIdx], "icon") ? g_RowModel[modelIdx].icon - 1 : GetIconIndexForHwnd(rr.hwnd) - 1
            if ih < 0
                ih := 0
            iy := rr.t + (LV_ROW_HEIGHT - ICON_SIZE) // 2
            DllCall("Comctl32\ImageList_Draw", "ptr", g_IconList, "int", ih, "ptr", hdc, "int", 4, "int", iy, "uint", 1) ; ILD_TRANSPARENT
        }
        title := modelIdx > 0 && HasProp(g_RowModel[modelIdx], "title") ? g_RowModel[modelIdx].title : WinRowTitle(rr.hwnd)
        tr := Buffer(16, 0)
        NumPut("int", 8 + ICON_SIZE, tr, 0)
        NumPut("int", rr.t + 1, tr, 4)
        NumPut("int", rr.r - 4, tr, 8)
        NumPut("int", rr.b - 1, tr, 12)
        DllCall("user32\DrawTextW", "ptr", hdc, "str", title, "int", -1, "ptr", tr, "uint", DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)
    }
    DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldRowFont, "ptr")
}

MidPaneSubclassProc(hWnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) {
    global WM_PAINT ; message id
    if uMsg = WM_PAINT {
        ps := Buffer(72, 0)
        hdc := DllCall("user32\BeginPaint", "ptr", hWnd, "ptr", ps, "ptr")
        if hdc
            PaintMidPaneClient(hdc, hWnd)
        DllCall("user32\EndPaint", "ptr", hWnd, "ptr", ps)
        return 0
    }
    return DllCall("Comctl32\DefSubclassProc", "ptr", hWnd, "uint", uMsg, "ptr", wParam, "ptr", lParam, "ptr")
}

MidPaneHitTestSectionHeader(cx, cy, &secIdx, &inChevron) {
    global g_SectionHeaderClientRects, MID_PANE_CHEV_W
    secIdx := 0
    inChevron := false
    for i, hr in g_SectionHeaderClientRects {
        if cx < hr.l || cx > hr.r || cy < hr.t || cy > hr.b
            continue
        secIdx := i
        inChevron := (cx < hr.l + MID_PANE_CHEV_W)
        return true
    }
    return false
}

MidPaneOnVScroll(wParam, lParam, msg, hwnd, *) {
    global g_MidPane, g_ScrollY, g_ScrollContentH, g_ScrollViewportH, WM_VSCROLL
    if msg != WM_VSCROLL || !g_MidPane || Integer(hwnd) != Integer(g_MidPane.Hwnd)
        return
    cmd := wParam & 0xFFFF
    if cmd = 8 ; SB_ENDSCROLL
        return
    global LV_ROW_HEIGHT
    line := LV_ROW_HEIGHT
    page := Max(g_ScrollViewportH - line, line)
    maxS := Max(0, g_ScrollContentH - g_ScrollViewportH)
    if cmd = 0 ; SB_LINEUP
        g_ScrollY := Max(0, g_ScrollY - line)
    else if cmd = 1 ; SB_LINEDOWN
        g_ScrollY := Min(maxS, g_ScrollY + line)
    else if cmd = 2 ; SB_PAGEUP
        g_ScrollY := Max(0, g_ScrollY - page)
    else if cmd = 3 ; SB_PAGEDOWN
        g_ScrollY := Min(maxS, g_ScrollY + page)
    else if cmd = 6 ; SB_TOP
        g_ScrollY := 0
    else if cmd = 7 ; SB_BOTTOM
        g_ScrollY := maxS
    else if cmd = 5 || cmd = 4 { ; SB_THUMBTRACK / SB_THUMBPOSITION
        g_ScrollY := HiWordSigned(wParam)
        if g_ScrollY > maxS
            g_ScrollY := maxS
        if g_ScrollY < 0
            g_ScrollY := 0
    } else
        return
    LayoutPanel()
}

MidPaneOnWheel(wParam, lParam, msg, hwnd, *) {
    global g_MidPane, g_ScrollY, g_ScrollContentH, g_ScrollViewportH, g_PanelVisible, WM_MOUSEWHEEL
    if msg != WM_MOUSEWHEEL || !g_PanelVisible || !g_MidPane
        return
    if g_ScrollContentH <= g_ScrollViewportH
        return
    pt := Buffer(8, 0)
    DllCall("user32\GetCursorPos", "ptr", pt)
    mx := NumGet(pt, 0, "int"), my := NumGet(pt, 4, "int")
    if !WinRectContainsScreen(g_MidPane.Hwnd, mx, my)
        return
    delta := HiWordSigned(wParam)
    global LV_ROW_HEIGHT
    step := 3 * LV_ROW_HEIGHT
    maxS := Max(0, g_ScrollContentH - g_ScrollViewportH)
    if delta > 0
        g_ScrollY := Max(0, g_ScrollY - step)
    else
        g_ScrollY := Min(maxS, g_ScrollY + step)
    LayoutPanel()
}

BtnOpen(*) {
    global g_SelectedHwnd
    ActivateHwndFromPanel(g_SelectedHwnd)
}

NextSectionName() {
    global g_Sections
    mx := 0
    for s in g_Sections {
        if RegExMatch(s.name, "^Section\s+(\d+)$", &m) {
            n := Integer(m[1])
            if n > mx
                mx := n
        }
    }
    return "Section " (mx + 1)
}

BtnAddSection(*) {
    global g_Sections, g_Order, g_SelectedSection, g_HwndToSection, g_ActiveSec, g_PanelVisible
    u := UncatIdx()
    g_Sections.InsertAt(u, { name: NextSectionName(), expanded: true, locked: false, lv: 0, hdrChev: 0, hdrName: 0, btnUp: 0, btnDn: 0 })
    if g_SelectedSection >= u
        g_SelectedSection += 1
    if g_ActiveSec >= u
        g_ActiveSec += 1
    ; New section is inserted before UnCAT; every old index >= u shifts right (UnCAT was u, now u+1).
    for hwnd, sec in g_HwndToSection {
        ns := Integer(sec)
        if ns >= u
            g_HwndToSection[hwnd] := ns + 1
    }
    newOrd := Map()
    Loop g_Sections.Length {
        i := A_Index
        if i < u
            newOrd[i] := g_Order.Has(i) ? CloneArr(g_Order[i]) : []
        else if i = u
            newOrd[i] := []
        else
            newOrd[i] := g_Order.Has(i - 1) ? CloneArr(g_Order[i - 1]) : []
    }
    g_Order := newOrd
    RebuildPanel()
}

BtnDelSection(*) {
    global g_Sections, g_HwndToSection, g_Order, g_SelectedSection, g_PanelVisible
    u := UncatIdx()
    delIdx := g_SelectedSection
    if !delIdx || delIdx < 1 || delIdx > g_Sections.Length
        return
    if g_Sections[delIdx].locked || delIdx = u
        return
    if g_Sections.Length <= 2
        return
    for hwnd, sec in g_HwndToSection
        if Integer(sec) = delIdx
            g_HwndToSection[hwnd] := u
    delOrd := g_Order.Has(delIdx) ? g_Order[delIdx] : []
    for hwnd in delOrd
        if !HwndInArr(SecOrder(u), hwnd)
            SecOrder(u).Push(hwnd)
    g_Sections.RemoveAt(delIdx)
    newMap := Map()
    for hwnd, sec in g_HwndToSection {
        ns := Integer(sec)
        if ns > delIdx
            ns -= 1
        newMap[hwnd] := ns
    }
    g_HwndToSection := newMap
    newOrd := Map()
    Loop g_Sections.Length {
        i := A_Index
        oldi := i < delIdx ? i : i + 1
        newOrd[i] := g_Order.Has(oldi) ? CloneArr(g_Order[oldi]) : []
    }
    g_Order := newOrd
    if g_SelectedSection = delIdx
        g_SelectedSection := 0
    else if g_SelectedSection > delIdx
        g_SelectedSection -= 1
    RebuildPanel()
}

SectionMove(delta, secIdx, *) {
    global g_Sections, g_Order, g_HwndToSection, g_SelectedSection, g_PanelVisible
    u := UncatIdx()
    if secIdx < 1 || secIdx >= u
        return
    j := secIdx + delta
    if j < 1 || j >= u
        return
    ss := g_SelectedSection
    if ss = secIdx
        g_SelectedSection := j
    else if ss = j
        g_SelectedSection := secIdx
    tmp := g_Sections[j]
    g_Sections[j] := g_Sections[secIdx]
    g_Sections[secIdx] := tmp
    oi := g_Order.Has(secIdx) ? CloneArr(g_Order[secIdx]) : []
    oj := g_Order.Has(j) ? CloneArr(g_Order[j]) : []
    g_Order[secIdx] := oj
    g_Order[j] := oi
    for hwnd, sec in g_HwndToSection {
        ns := Integer(sec)
        if ns = secIdx
            g_HwndToSection[hwnd] := j
        else if ns = j
            g_HwndToSection[hwnd] := secIdx
    }
    RebuildPanel()
}

ToggleExpand(secIdx, *) {
    global g_Sections, g_Filter
    if secIdx < 1 || secIdx > g_Sections.Length
        return
    if g_Filter != "" ; while filtering, sections stay expanded so matches stay visible
        return
    g_Sections[secIdx].expanded := !g_Sections[secIdx].expanded
    LayoutPanel()
}

; Hide panel first so a Run / Send failure (AppLocker, GPO, missing shell verb, blocked
; SendInput) can never leave the panel stuck on screen. Action calls are wrapped in try
; for the same reason — locked-down corporate machines often refuse these silently or
; throw, and we don't want either to break the toolbar.
BtnStart(*) {
    HidePanel()
    try Send("{LWin}")
}

BtnExplorer(*) {
    HidePanel()
    try Run("explorer")
}

BtnDownloads(*) {
    HidePanel()
    try Run('explorer shell:Downloads')
}

BtnDesktop(*) {
    ; Native "Show desktop" behavior.
    HidePanel()
    try Send("#d")
}

EnsureMidPane() {
    global g_Gui, g_MidPane, THEME_PANEL, g_MidPaneSubclassCb, MID_PANE_SUBCLASS_ID
    if !g_Gui
        return
    if g_MidPane {
        if g_MidPaneSubclassCb
            try DllCall("Comctl32\RemoveWindowSubclass", "ptr", g_MidPane.Hwnd, "ptr", g_MidPaneSubclassCb, "ptr", MID_PANE_SUBCLASS_ID)
        try g_MidPane.Destroy()
        g_MidPane := 0
    }
    g_MidPane := Gui("+Parent" . g_Gui.Hwnd . " -Caption")
    g_MidPane.BackColor := THEME_PANEL
    g_MidPane.MarginX := 0, g_MidPane.MarginY := 0
    GWL_STYLE := -16
    WS_VSCROLL := 0x200000
    WS_CLIPCHILDREN := 0x02000000
    WS_TABSTOP := 0x00010000
    ws := DllCall("user32\GetWindowLongPtr", "ptr", g_MidPane.Hwnd, "int", GWL_STYLE, "ptr")
    DllCall("user32\SetWindowLongPtr", "ptr", g_MidPane.Hwnd, "int", GWL_STYLE, "ptr", ws | WS_VSCROLL | WS_CLIPCHILDREN | WS_TABSTOP)
    if !g_MidPaneSubclassCb
        g_MidPaneSubclassCb := CallbackCreate(MidPaneSubclassProc, "Fast", 6)
    DllCall("Comctl32\SetWindowSubclass", "ptr", g_MidPane.Hwnd, "ptr", g_MidPaneSubclassCb, "ptr", MID_PANE_SUBCLASS_ID, "ptr", 0)
}

DestroySectionGuiChildren() {
    global g_Sections, g_MidPane, g_MidPaneSubclassCb, MID_PANE_SUBCLASS_ID
    for s in g_Sections
        s.lv := 0, s.hdrChev := 0, s.hdrName := 0, s.btnUp := 0, s.btnDn := 0
    if g_MidPane {
        if g_MidPaneSubclassCb
            try DllCall("Comctl32\RemoveWindowSubclass", "ptr", g_MidPane.Hwnd, "ptr", g_MidPaneSubclassCb, "ptr", MID_PANE_SUBCLASS_ID)
        try g_MidPane.Destroy()
        g_MidPane := 0
    }
}

HidePanel(*) {
    global g_Gui, g_PanelVisible, g_Drag, g_MidClickRow, g_SuppressFocusHide, g_ScrollY
    SetTimer(HoverButtonPoll, 0)
    ClearButtonHoverHighlight()
    ClearButtonFocusHighlight()
    g_ScrollY := 0
    if g_Drag {
        g_Drag := 0
        cap := DllCall("user32\GetCapture", "ptr")
        if cap && IsOurGuiWindow(cap)
            DllCall("user32\ReleaseCapture")
        SetTimer(RefreshLists, -1)
    }
    if g_MidClickRow {
        g_MidClickRow := 0
        cap := DllCall("user32\GetCapture", "ptr")
        if cap && IsOurGuiWindow(cap)
            DllCall("user32\ReleaseCapture")
    }
    g_SuppressFocusHide := false
    if g_Gui
        g_Gui.Hide()
    g_PanelVisible := false
}

ShowPanel(*) {
    global g_Gui, g_PanelVisible, g_Search, g_SuppressFocusHide, g_ScrollY, g_LastListSig
    wasHidden := !g_PanelVisible
    EnsureGui()
    g_ScrollY := 0
    if wasHidden {
        SetTimer(RefreshLists, 0) ; drop pending search debounce from last open
        g_LastListSig := ""
        ResetIconList() ; avoid stale HWND/icon cache and long-session icon-list growth
        if g_Search
            try g_Search.Value := ""
    }
    g_SuppressFocusHide := false
    wl := 0, wt := 0, wr := 0, wb := 0, ww := 0, wh := 0
    MonitorWorkAreaFromMouse(&wl, &wt, &wr, &wb, &ww, &wh)
    pw := Max(200, Floor(ww * 0.33))
    ; Must activate the GUI (no "NA"): otherwise foreground stays elsewhere and
    ; open can mis-track focus / auto-hide.
    ; Snap to work-area left/top (wl), full work-area height.
    g_Gui.Show("x" wl " y" wt " w" pw " h" wh)
    ApplyGuiTitlebarTheme(g_Gui.Hwnd)
    g_PanelVisible := true
    LayoutPanel() ; client rect is valid only after Show — fixes narrow/centered content on first open
    KeepPanelTopNoActivate()
    SetTimer(HoverButtonPoll, 100)
    RefreshLists()
    if !SelectFirstPanelWindow(true)
        try g_Search.Focus()
}

ToggleHotkey(*) {
    global g_PanelVisible, g_Gui
    if !g_PanelVisible
        ShowPanel()
    else if g_Gui && WinActive("ahk_id " g_Gui.Hwnd)
        HidePanel()
    else
        ShowPanel()
}

EnsureGui() {
    global g_Gui, g_MidPane, g_Search, g_SearchClear, g_Sections, WM_VSCROLL, WM_MOUSEWHEEL, WM_LBUTTONDOWN, WM_MOUSEMOVE, WM_ACTIVATE, WM_ACTIVATEAPP
    if g_Gui
        return
    if !g_Sections.Length
        InitSections()
    ; Tool window keeps this as a lightweight panel (no taskbar button / usually not Alt+Tab).
    g_Gui := Gui("+AlwaysOnTop +ToolWindow -Caption +Border -E0x40000", "SpatialTaskbar")
    global THEME_BG, THEME_TEXT, THEME_PANEL
    g_Gui.BackColor := THEME_BG
    g_Gui.SetFont("s10 c" THEME_TEXT, "Segoe UI")
    g_Gui.MarginX := 4, g_Gui.MarginY := 6
    GWL_STYLE := -16
    WS_CLIPCHILDREN := 0x02000000
    wsMain := DllCall("user32\GetWindowLongPtr", "ptr", g_Gui.Hwnd, "int", GWL_STYLE, "ptr")
    DllCall("user32\SetWindowLongPtr", "ptr", g_Gui.Hwnd, "int", GWL_STYLE, "ptr", wsMain | WS_CLIPCHILDREN)
    g_Gui.OnEvent("Escape", HidePanel)
    g_Gui.OnEvent("Close", HidePanel)
    g_Gui.OnEvent("Size", Gui_Size)
    OnMessage(WM_LBUTTONUP, DragPanelLButtonUp)
    OnMessage(WM_LBUTTONDOWN, MidPaneLButtonDown)
    OnMessage(WM_MOUSEMOVE, DragTrackMouseMove)
    OnMessage(WM_ACTIVATE, PanelGuiActivate)
    OnMessage(WM_ACTIVATEAPP, PanelAppActivate)
    OnMessage(WM_VSCROLL, MidPaneOnVScroll)
    OnMessage(WM_MOUSEWHEEL, MidPaneOnWheel)

    EnsureMidPane()

    g_Search := g_Gui.Add("Edit", "vSearchEdit xm w100 r1", "")
    g_Search.OnEvent("Change", SearchChanged)
    try g_Search.Opt("-Theme +Background" THEME_PANEL " +c" THEME_TEXT)
    try g_Search.SetFont("s10", "Segoe UI")
    ; Flatten search edge to remove bright Win32 bevel.
    GWL_EXSTYLE := -20
    WS_EX_CLIENTEDGE := 0x00000200
    exSearch := DllCall("user32\GetWindowLongPtr", "ptr", g_Search.Hwnd, "int", GWL_EXSTYLE, "ptr")
    DllCall("user32\SetWindowLongPtr", "ptr", g_Search.Hwnd, "int", GWL_EXSTYLE, "ptr", exSearch & ~WS_EX_CLIENTEDGE)

    g_SearchClear := g_Gui.Add("Text", "vBtnSearchClear ys w24 h24 +Tabstop +0x100 +0x200 Center Border", "×")
    g_SearchClear.OnEvent("Click", SearchClearClick)

    g_Gui.Add("Text", "vBtnOpen ys w58 h28 +Tabstop +0x100 +0x200 Center Border", "Open").OnEvent("Click", BtnOpen)
    g_Gui.Add("Text", "vBtnAdd ys w78 h28 +Tabstop +0x100 +0x200 Center Border", "+ Section").OnEvent("Click", BtnAddSection)
    g_Gui.Add("Text", "vBtnDel ys w78 h28 +Tabstop +0x100 +0x200 Center Border", "- Section").OnEvent("Click", BtnDelSection)

    g_Gui.Add("Text", "vBtnClosePanel ys w24 h24 +Tabstop +0x100 +0x200 Center Border", "×").OnEvent("Click", HidePanel)

    g_Gui.Add("Text", "vBtnStart xm w70 h28 Hidden +Tabstop +0x100 +0x200 Center Border", "Start").OnEvent("Click", BtnStart)
    g_Gui.Add("Text", "vBtnExplorer ys w80 h28 Hidden +Tabstop +0x100 +0x200 Center Border", "Explorer").OnEvent("Click", BtnExplorer)
    g_Gui.Add("Text", "vBtnDownloads ys w90 h28 Hidden +Tabstop +0x100 +0x200 Center Border", "Downloads").OnEvent("Click", BtnDownloads)
    g_Gui.Add("Text", "vBtnDesktop ys w110 h28 Hidden +Tabstop +0x100 +0x200 Center Border", "Show desktop").OnEvent("Click", BtnDesktop)

    for nm in ["BtnSearchClear", "BtnOpen", "BtnAdd", "BtnDel", "BtnStart", "BtnExplorer", "BtnDownloads", "BtnDesktop"]
        ThemeStyleButton(g_Gui[nm])
    ThemeStyleCloseButton(g_Gui["BtnClosePanel"])

    RebuildPanel()

    for nm in ["BtnStart", "BtnExplorer", "BtnDownloads", "BtnDesktop"]
        g_Gui[nm].Opt("-Hidden")
    ; Layout deferred until first ShowPanel (GetClientPos is wrong while GUI never shown).
}

Gui_Size(g, MinMax, W, H) {
    global g_Gui
    if MinMax = -1
        return
    LayoutPanel()
    if g_Gui && Integer(g.Hwnd) = Integer(g_Gui.Hwnd)
        ApplyGuiTitlebarTheme(g_Gui.Hwnd)
}

; One-shot after RebuildPanel: same-thread layout right after Destroy/Ensure mid-pane can see stale
; client metrics until the next message pump tick; without this, add/remove section updates the
; model but the mid-pane may not repaint until the panel is closed and reopened.
PostRebuildRelayout(*) {
    global g_PanelVisible, g_Gui, g_MidPane
    if !g_PanelVisible || !g_Gui || !g_MidPane
        return
    LayoutPanel()
}

RebuildPanel() {
    global g_Gui, g_MidPane, g_Sections, g_LastListSig, g_RebuildingGui, g_PanelVisible
    if !g_Gui
        return
    g_RebuildingGui := true
    try {
        DestroySectionGuiChildren()
        EnsureMidPane()
        EnsureIconList()
        for i, s in g_Sections
            s.lv := 0, s.hdrChev := 0, s.hdrName := 0, s.btnUp := 0, s.btnDn := 0
        g_LastListSig := "" ; force full RefreshLists after try (see below)
    } finally {
        g_RebuildingGui := false
    }
    ; RefreshLists bails out while g_RebuildingGui is true, so it must run here: rebuilds row model, layout, paint.
    if g_Gui && g_MidPane
        RefreshLists()
    if g_PanelVisible && g_Gui && g_MidPane
        SetTimer(PostRebuildRelayout, -1)
    if g_PanelVisible && g_Gui {
        try WinActivate("ahk_id " g_Gui.Hwnd)
        KeepPanelTopNoActivate()
    }
}

LayoutPanel() {
    global g_Gui, g_MidPane, g_Search, g_SearchClear, g_Sections, g_ScrollY, g_ScrollContentH, g_ScrollViewportH
    global g_SectionHeaderClientRects, g_WindowRowClientRects, g_SectionListBands, LV_ROW_HEIGHT, MID_PANE_HDR_H, MID_PANE_CHEV_W
    if !g_Gui || !g_MidPane
        return
    ; Client size — captionless + border; client height drives mid-pane and bottom row placement.
    g_Gui.GetClientPos(, , &gw, &gh)
    if gh < 150 ; width can be 0 before first Show — still run once Show() has sized the window
        return
    marginX := 8, marginY := 6
    topGap := 4
    footerPadBottom := 6
    footerH := 36
    btnGap := 6
    clearW := 24
    closeW := 24
    openW := 58
    addW := 78
    delW := 78
    btnHTop := 28
    btnHSmall := 24

    topRowH := btnHTop
    try g_Search.GetPos(, , , &sh)
    if sh > topRowH
        topRowH := sh

    botRowH := 28
    for nm in ["BtnStart", "BtnExplorer", "BtnDownloads", "BtnDesktop"] {
        b := g_Gui[nm]
        b.GetPos(, , , &bh)
        if bh > botRowH
            botRowH := bh
    }

    innerW := gw - 2 * marginX
    footerTop := gh - footerPadBottom - footerH
    midY := marginY + topRowH + topGap
    ; Mid-pane bottom = midY + midViewportH must stay ≤ footerTop (never overlap footer strip).
    midViewportH := Max(0, footerTop - midY)

    ; Top row: place from right edge — Close, - Section, + Section, Open, SearchClear; SearchEdit fills the rest.
    xRight := gw - marginX
    xRight -= closeW
    g_Gui["BtnClosePanel"].Move(xRight, marginY + Max(0, (topRowH - btnHSmall) // 2), closeW, btnHSmall)
    xRight -= btnGap

    xRight -= delW
    g_Gui["BtnDel"].Move(xRight, marginY + Max(0, (topRowH - btnHTop) // 2), delW, btnHTop)
    xRight -= btnGap

    xRight -= addW
    g_Gui["BtnAdd"].Move(xRight, marginY + Max(0, (topRowH - btnHTop) // 2), addW, btnHTop)
    xRight -= btnGap

    xRight -= openW
    g_Gui["BtnOpen"].Move(xRight, marginY + Max(0, (topRowH - btnHTop) // 2), openW, btnHTop)
    xRight -= btnGap

    xRight -= clearW
    if g_SearchClear
        g_SearchClear.Move(xRight, marginY + Max(0, (topRowH - btnHSmall) // 2), clearW, btnHSmall)
    xRight -= btnGap

    ; Width from left margin to clear ×; do not force a minimum that would overlap the right-placed cluster.
    searchW := Max(1, xRight - marginX)
    g_Search.Move(marginX, marginY, searchW)

    hdrH := MID_PANE_HDR_H
    chevW := MID_PANE_CHEV_W
    lvPad := 2 ; tighter list padding, cleaner blocks
    ; Per-item y-advances. These MUST match the values used by the rect-building loop below;
    ; any mismatch makes maxScroll wrong and clips items at the bottom of the viewport.
    hdrAdvance := hdrH + 4
    listGap := 10 ; gap after a section's row block before the next header
    bandPad := 2  ; extra pixels added to the list-band height beyond lvPad + rows

    ; First pass: compute total content height using the SAME arithmetic the rect loop uses.
    contentH := 0
    for i, s in g_Sections {
        contentH += hdrAdvance
        if s.expanded {
            rc := RowModelSecWindowHwnds(i).Length
            if rc > 0
                contentH += lvPad + rc * LV_ROW_HEIGHT + bandPad + listGap
        }
    }
    g_ScrollContentH := contentH
    g_ScrollViewportH := midViewportH
    maxScroll := Max(0, contentH - midViewportH)
    if g_ScrollY > maxScroll
        g_ScrollY := maxScroll
    if g_ScrollY < 0
        g_ScrollY := 0

    g_MidPane.Move(marginX, midY, innerW, midViewportH)
    g_MidPane.Show("NA")
    midCw := MidPaneClientW()
    if midCw < 80
        midCw := Max(innerW - 20, 80) ; fallback if client rect not ready
    if midCw > innerW
        midCw := innerW

    DllCall("user32\LockWindowUpdate", "ptr", g_MidPane.Hwnd)
    try {
    g_SectionHeaderClientRects := Map()
    g_SectionListBands := Map()
    g_WindowRowClientRects := []
    y := 0
    for i, s in g_Sections {
        yDisp := y - g_ScrollY
        g_SectionHeaderClientRects[i] := { l: 0, t: yDisp, r: Max(midCw - 1, 0), b: yDisp + hdrH - 1 }
        y += hdrAdvance
        if s.expanded {
            secHwndOrder := RowModelSecWindowHwnds(i)
            rc := secHwndOrder.Length
            if rc > 0 {
                h := lvPad + rc * LV_ROW_HEIGHT + bandPad
                lvTop := y - g_ScrollY
                g_SectionListBands[i] := { l: 0, t: lvTop, r: Max(midCw - 1, 0), b: lvTop + h - 1, rows: rc }
                rowTop := lvTop + lvPad
                Loop rc {
                    ri := A_Index
                    rt := rowTop + (ri - 1) * LV_ROW_HEIGHT
                    rb := rt + LV_ROW_HEIGHT - 1
                    g_WindowRowClientRects.Push({ sec: i, row: ri, hwnd: secHwndOrder[ri], l: 0, t: rt, r: Max(midCw - 1, 0), b: rb })
                }
                y += h + listGap
            }
        }
    }
    UpdateSectionHighlights()
    MidPaneApplyScrollInfo()
    } finally {
        DllCall("user32\LockWindowUpdate", "ptr", 0)
    }
    MidPaneRefreshPaint()

    btnY := footerTop + (footerH - botRowH) // 2
    xb := marginX
    for nm in ["BtnStart", "BtnExplorer", "BtnDownloads", "BtnDesktop"] {
        b := g_Gui[nm]
        b.GetPos(, , &bw, &bh)
        b.Move(xb, btnY, bw, bh)
        xb += bw + 6
    }
}

InitSections()
OnExit(Cleanup)
!Space::ToggleHotkey

Cleanup(*) {
    global g_MidPane, g_MidPaneSubclassCb, MID_PANE_SUBCLASS_ID, g_IconList

    if g_MidPane && g_MidPaneSubclassCb {
        try DllCall("Comctl32\RemoveWindowSubclass", "ptr", g_MidPane.Hwnd, "ptr", g_MidPaneSubclassCb, "ptr", MID_PANE_SUBCLASS_ID)
    }

    if g_IconList {
        try DllCall("Comctl32\ImageList_Destroy", "ptr", g_IconList)
        g_IconList := 0
    }

    if g_MidPaneSubclassCb {
        try CallbackFree(g_MidPaneSubclassCb)
        g_MidPaneSubclassCb := 0
    }
}

#HotIf MButtonOverPanelRows()
MButton:: MidPaneMiddleClickClose()

#HotIf g_PanelVisible
Up:: MovePanelSelection(-1)
Down:: MovePanelSelection(1)
PgUp:: MovePanelSelectionByPage(-1)
PgDn:: MovePanelSelectionByPage(1)
Home:: PanelKeyboardJumpTo(1)
End:: PanelKeyboardJumpTo(999999)
Tab:: FocusCycle(1)
+Tab:: FocusCycle(-1)
Enter:: PanelEnter()
Delete:: CloseSelectedPanelWindow()
Esc:: HidePanel()

#HotIf g_PanelVisible
~LButton:: PanelOutsideClickClose()

#HotIf
