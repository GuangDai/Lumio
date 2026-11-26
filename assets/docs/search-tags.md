# Search tags, folder addresses and browser tabs

## Actions and folder addresses

Select an app with the arrow keys and press **Tab** to open its action page. Choose an action with the arrow keys and press **Enter**. Common app actions include opening or switching to the app, opening a new instance and showing it in Finder.

On the Finder action page, typing switches to folder results. Each result shows the directory address. **Enter** opens the selection in Finder, and **Open in Terminal** opens it in Terminal.

| Input | Folder result |
| --- | --- |
| `Telegram` | Folders matching the name |
| `Downloads/Telegram` or `D/T` | Folders at the final matching path component |
| `D/T/` | Immediate subfolders of the matched folder |
| `~/Library` | The local Library directory |
| `~/.config/settings.json` | The existing file's parent directory |
| `file:///Users/me/Documents` | The local Documents directory |

From the main search field, **cd** followed by a folder query, such as `cd D/T`, also opens the directory flow. Paste absolute or home-relative paths as written, including paths containing spaces.

The default index includes the home directory and the Desktop, Documents, Downloads and Library roots. Hidden directories, including names that start with a dot, are eligible. Settings ▸ Indexing lets you change the roots, depth, limit and exclusions.

## Search tags

Type a supported keyword, then press **Tab** to narrow the query. **Option+T** opens the tag browser.

| Keyword | Scope |
| --- | --- |
| `apps` | Applications |
| `folders` | Folders |
| `documents`, `downloads`, `desktop` | Folders under the named directory |
| `settings` | System Settings panes |
| `process` | Running processes |
| `windows` | Open app windows |
| `browser` | Local bookmarks, history and tabs |
| `bookmark` or `bm` | Saved bookmarks |
| `history` | Chromium browsing history |

A folder tag can declare an additional search scope in `~/.lumio/config`:

```ini
search_tag_work=Work|folder:~/Work
```

## Browser tabs, bookmarks and history

Open tabs from supported Chromium browsers appear in search results. **Enter** switches to the existing tab. macOS may request Automation permission the first time Lumio reads a browser's tabs. The tab list is a snapshot taken when Lumio opens.

Bookmarks and history are read from local Chromium profiles. Bookmark folders also become search tags. A directly entered URL or a saved link opens in an installed non-Safari browser.

## Suggestions on open

Settings ▸ General ▸ **Suggestions when empty** shows recently used apps alongside pins. Set `suggestions_on_open=false` to display the quick buttons on the empty field.

## Window search permissions

Window search requires Accessibility permission. Lumio distinguishes three states:

- **Working**. macOS allows access and a request succeeds.
- **Off**. Lumio is absent from the permission list or its switch is off.
- **Stale**. The system entry belongs to an older copy of Lumio.

Settings ▸ General ▸ Permissions can guide you through refreshing a stale entry. Full Disk Access lets Lumio distinguish a stale entry from one that is off. Otherwise it uses whether the permission has worked before.
