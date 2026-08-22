# SpatialTaskbar

A vertical, keyboard-friendly window switcher for Windows. Press **Alt+Space**
to slide a panel onto the left edge of whichever monitor your cursor is on,
listing every open window grouped into sections you can rearrange. Pick one,
hit Enter, and the panel closes.

Written in [AutoHotkey v2](https://www.autohotkey.com/). Single-file script,
no installer, no settings file, nothing written to disk.

## Requirements

- Windows 10 or 11
- AutoHotkey **v2.0+**

## Install / run

1. Install AutoHotkey v2.
2. Download `SpatialTaskbar.ahk`.
3. Double-click it. (Optional: drop a shortcut in
   `shell:startup` to launch on login.)

## Hotkeys

### Global

| Key | Action |
| --- | --- |
| `Alt+Space` | Show / hide the panel on the monitor under the cursor |

> Note: `Alt+Space` normally opens the active window's system menu in
> Windows. This script reclaims it.

### While the panel is open

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move selection (preview-activates the window) |
| `Enter` | Open the selected window and close the panel |
| `Delete` | Send `WM_CLOSE` to the selected window |
| `Tab` / `Shift+Tab` | Cycle focus through search box, buttons, list |
| `Esc` | Hide the panel |
| Click outside the panel | Hide the panel |
| Middle-click a row | Close that window (`WM_CLOSE`) |

## Sections

- Drag any window row onto a section header (name or chevron) to move it
  there. Works while the section is collapsed.
- **+ Section** adds a new section above *Uncategorized*.
- **- Section** removes the currently selected section (click the section
  name to select it). *Uncategorized* cannot be removed.
- Click the chevron, or click the section name twice within ~400 ms, to
  expand / collapse.
- Click the pencil on the right of a section header to rename it in place.
  Enter or clicking elsewhere commits; Esc cancels. *Uncategorized* cannot
  be renamed.

## Search

- Typing in the search box filters the list by window title (falls back to
  process name).
- Sections stay expanded while a filter is active so matches remain visible;
  the previous expand / collapse state is restored when the filter is
  cleared.
- Click `×` next to the search box (or just clear the text) to drop the
  filter.

## Closing windows

Middle-click or `Delete` posts `WM_CLOSE` to the window — the same thing
clicking the X in its title bar does. For programs that commonly throw up a
"Save changes?" dialog when a window closes (Word, Excel, PowerPoint,
Access, Outlook, OneNote), a confirmation prompt is shown first. Edit
`g_CloseConfirmExes` near the top of the script to adjust that list.

## What it does *not* do

- No disk persistence. Sections, ordering, and filters live in memory until
  you exit or reload. Reopening the panel rebuilds the window list from
  scratch.
- No network access, no telemetry, no registry writes.
- No periodic polling — the panel hides as soon as focus leaves it, and the
  next open re-enumerates windows.

## License

[MIT](LICENSE)
