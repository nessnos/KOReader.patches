# KOReader.patches

A small collection of user patches for [KOReader](https://github.com/koreader/koreader).

Each patch is a single `.lua` file. You don't need to install a plugin or change KOReader itself. Just drop the file in, restart, and it works.

## Patches

| Patch | What it does | Requires |
|---|---|---|
| [`2-simpleui-library-count.lua`](2-simpleui-library-count.lua) | Adds a minimalist home screen module showing how many books are in your library, with optional read / unread counts | [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) |

---

## Installation

1. Download the `.lua` file of the patch you want.
2. Connect your e-reader and open the `koreader` folder:
   - **Kobo:** `.adds/koreader/`
   - **Kindle:** `koreader/`
   - **PocketBook:** `applications/koreader/`
   - **Android:** `koreader/` in internal storage
3. Create a folder named `patches` inside it if it doesn't exist yet.
4. Copy the `.lua` file into `koreader/patches/`.
5. Restart KOReader.

> Keep the file name as it is. The number at the start (`2-`) tells KOReader *when* to load the patch.

**To remove a patch**, delete its file from `koreader/patches/` and restart.

---

## Library Count (SimpleUI)

`2-simpleui-library-count.lua`

A clean, text-only module for the SimpleUI home screen that shows how many books you have.

```
Stacked                         Row

  1245                          1245   │  412  │  833
  books                         books  │  read │  unread
  412 read · 833 unread
```

**Features**

- Always shows the **total** number of books in your library. That's every book in your home folder, including subfolders.
- Optionally also shows:
  - **Read** – books marked as *Finished*
  - **Unread** – books not started yet **plus** books *On hold*
  - **In progress** – books you've started but not finished
- Two styles: **Stacked** or **Row**
- Left or centered alignment (Stacked), adjustable scale, optional "Library" heading
- All text is solid black for good contrast on e-ink
- **Tap** the module to recount. **Long-press** to open its settings.

**Setup**

1. Install the patch (see above) and restart KOReader.
2. On the SimpleUI home screen, open the module settings (*Arrange / Add module*).
3. Turn on **Library Count**.
4. Open its settings to choose which counts to show and pick a style.

**Good to know**

- Counts update by themselves when you close a book, change a book's status, or add or remove books. If a number ever looks off, tap the module or use *Recount now*.
- If *In progress* is hidden, *read + unread* won't add up to the total. Turn it on to see every book accounted for.

**Requirements:** KOReader with the [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) plugin, version 2.5 or newer.

---

## Troubleshooting

- **The patch doesn't seem to do anything.** Check that the file is directly inside `koreader/patches/` (not in a subfolder) and that its name still ends in `.lua`.
- **KOReader shows "Error applying patch".** The patch may not be compatible with your version of KOReader or the plugin it depends on. Remove the file and [open an issue](../../issues) with your KOReader and plugin versions.
- **Logs:** KOReader writes errors to `crash.log` in the `koreader` folder. Patch messages there start with the patch name.

## Contributing

Found a bug or have an idea? Feel free to [open an issue](../../issues).

## License

[MIT](LICENSE). You're free to use, modify, and share these patches.

These patches aren't affiliated with the KOReader or SimpleUI projects.
