# KOReader.patches

A small collection of user patches for [KOReader](https://github.com/koreader/koreader).

Each patch is a single `.lua` file. You don't need to install a plugin or change KOReader itself. Just drop the file in, restart, and it works.

## Patches

| Patch | What it does | Requires |
|---|---|---|
| [`2-simpleui-library-count.lua`](2-simpleui-library-count.lua) | Adds a minimalist home screen module showing how many books are in your library, with optional read / unread counts | [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) |
| [`2-sort-authors-by-lastname.lua`](2-sort-authors-by-lastname.lua) | Sorts authors by last name, even when the metadata is "FirstName LastName" | Nothing. Works with or without [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) |
| [`2-smart-collections.lua`](2-smart-collections.lua) | Adds smart collections that fill themselves with books matching rules you set, like *Tags contains "fantasy"* or *Status is not Finished* | Nothing |
| [`2-collections-mosaic.lua`](2-collections-mosaic.lua) | Shows your collections list as a mosaic. Each collection is drawn as one cover made from the covers of its first 4 books | The Cover browser plugin (built into KOReader) |

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

## Sort Authors by Last Name

`2-sort-authors-by-lastname.lua`

Most books store the author as "FirstName LastName", so author lists end up sorted by first name. This patch sorts them by last name instead. Names still show up exactly as they're written. Only the order changes.

```
Before                          After

  Albert Camus                    Isaac Asimov
  Émile Zola                      Albert Camus
  Isaac Asimov                    Neil Gaiman
  Neil Gaiman                     Terry Pratchett
  Terry Pratchett                 Émile Zola
```

**Where it works**

- **With SimpleUI:** Library → *Browse by Author*
- **Without SimpleUI (stock KOReader):**
  - Collections → menu → filter by *Author(s)*
  - Bookmark browser → *Filters* → *Author(s)*
  - *Sort by: Authors* in book lists (collections, history)

**How the last name is found**

- **"First Middle Last"**: the last word is the last name.
- **"Last, First"**: if the name already has a comma, it's used as is.
- **Suffixes** like Jr., Sr., III or PhD are ignored ("Martin Luther King Jr." sorts under K).
- **Titles** like Dr., Prof. or Mr. are ignored ("Dr. Seuss" sorts under S).
- **Single names** like "Homer" or "Colette" sort by that name.
- **Accents** like "É" are ignored when sorting.
- **Particles** like *van*, *von*, *de* or *la* aren't counted as part of the last name, same as Calibre: "Ludwig van Beethoven" sorts under B and "Ursula K. Le Guin" under G. You can change this (see below).

**Settings**

Open the file in a text editor and change these values at the top:

- `USE_SURNAME_PREFIXES = false`: set to `true` to sort "Ludwig van Beethoven" under V and "Ursula K. Le Guin" under L.
- `SORT_BOOKS_BY_AUTHOR = true`: set to `false` if you only want the author lists sorted and want *Sort by: Authors* to keep KOReader's default order.

**Good to know**

- If a name sorts in the wrong place (for example "Gabriel García Márquez", which sorts under M), edit that book's author metadata to "García Márquez, Gabriel". Names with a comma are always used as is.
- If your version of KOReader or SimpleUI doesn't have one of the lists above, the patch skips it. The rest still work.

**Requirements:** KOReader. [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) is optional. It was checked against SimpleUI 2.7.1.

---

## Smart Collections

`2-smart-collections.lua`

Collections that fill themselves. Instead of adding books by hand, you set a few rules and every book in your library that matches is added automatically.

```
Smart collection: Fantasy to read

  Tags contains "fantasy"
  Status is not Finished
  + Add rule
  Books must match: ALL rules
```

**Features**

- When you create a new collection, you choose **Normal collection** or **Smart collection**.
- Books come from your **home folder and all its subfolders**. You don't need to connect a folder.
- Match **ALL** rules (every rule must fit) or **ANY** rule (one is enough).
- Smart collections are marked with a small wand icon in the collections list.

**Fields you can filter on**

Tags, Author, Title, Series, Series number, Language, Description, Status, Rating, Progress (%), Pages, Has highlights, File name, File type, Folder

**Conditions**

- **Text:** contains, does not contain, equals, does not equal, starts with, is empty, is not empty
- **Numbers:** =, ≠, >, ≥, <, ≤
- **Status:** is, is not (New, Reading, On hold, Finished)
- Capital letters don't matter. For books with several tags or authors, a rule matches if any one of them fits.

**Setup**

1. Install the patch (see above) and restart KOReader.
2. Open **Collections**, tap the menu icon (top left), then **New collection**.
3. Choose **Smart collection**, give it a name, and add your rules.
4. Tap **Create**.

**Editing**

- **Long-press** a smart collection in the list to edit its rules, update it now, rename or remove it, set it as default, or turn it into a normal collection.
- Inside a smart collection, the menu has **Edit smart rules** and **Update now**.

**Good to know**

- Smart collections update when you open them. The collections list also refreshes them, at most once every 5 minutes. Tap **Update now** if you want the latest right away.
- While a collection updates, you'll briefly see *Updating smart collection…*. The collection or list opens once the update is done.
- All matching books are added, whatever their reading status. To leave out finished books, add a rule like *Status is not Finished*.
- A smart collection always matches its rules exactly. Books that stop matching (for example, once you mark them Finished) drop out. Books added by hand drop out too, unless they match.
- For books you've never opened, the tags and author are read from the file the first time. On a big library, that first update can take a while and can't be cancelled, so let it finish. The results are saved in `koreader/settings/smart_collections_cache.lua`, so later updates are fast.

**Requirements:** KOReader. It was written against KOReader v2026.07. Works with or without [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin), including opening collections from its navbar and home screen.

---

## Collections Mosaic

`2-collections-mosaic.lua`

KOReader always shows the list of collections as plain text, even when your library uses the mosaic view. This patch shows it as a mosaic too. Each collection gets a cover made from the covers of its first 4 books, and it's the same size as a normal book cover.

```
┌─────────┬─────────┐   ┌─────────┬─────────┐
│ cover 1 │ cover 2 │   │ cover 1 │ cover 2 │
├─────────┼─────────┤   ├─────────┼─────────┤
│ cover 3 │ cover 4 │   │ cover 3 │░░░░░░░░░│
│ ┌─────────────────┐   │ ┌─────────────────┐
│ │     Fantasy     │   │ │    Favorites    │
│ │       24        │   │ │        3        │
└─┴─────────────────┘   └─┴─────────────────┘
```

**Features**

- The 4 covers sit edge to edge, with no frame and no gaps. Each cover is cropped a little to fill its quarter.
- A label at the bottom shows the collection's name and how many books it has, plus markers like ★ for the default collection.
- The "first 4 books" follow each collection's own sort order (manual, title, author…).
- **Fewer than 4 books:** the empty spots are light grey. A book without a cover shows its title instead.
- Covers that haven't been loaded yet appear on their own after a moment, the same way they do in your library.
- **Tap** a collection to open it. **Long-press** it for the usual options.

**Setup**

1. Install the patch (see above) and restart KOReader.
2. That's it. If your library is in a mosaic view, your collections list is too.

**It follows your library view**

The patch uses the same view as your library (File browser → *Display mode*):

- **Mosaic with cover images:** collections are shown as cover collages.
- **Mosaic with text covers:** you get the same layout, but with book titles instead of covers.
- **List or classic view:** the normal collections list is kept.

It also uses the same grid size (columns × rows, portrait and landscape) as your library.

**Settings**

Open the file in a text editor and change this value at the top:

- `FOLLOW = "filemanager"`: set to `"collections"` to follow Cover browser's *Collections display mode* instead of your library's view.

**Good to know**

- The screen for adding a book to collections (the one with checkmarks) keeps the normal list.
- Works together with [Smart Collections](#smart-collections).

**Requirements:** KOReader with the **Cover browser** plugin turned on (it's built in, and already on if your library shows covers). It was written against KOReader v2026.07. Works with or without [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin).

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
