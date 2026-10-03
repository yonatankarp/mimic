# Keyboard shortcuts and menus

What Mimic's own menus hold, and the keys that work where you are. macOS's usual items, like
those in the Window menu, work as in any Mac app. Items marked *(when …)*
only show, or only work, at those times. A menu item with **…** in its name asks you something
before it acts.

## Keyboard shortcuts

| Keys | What it does |
|---|---|
| ++cmd+n++ | **New Mini…** |
| ++shift+cmd+n++ | **New Project…** |
| ++shift+cmd+i++ | **Import Model…** |
| ++cmd+o++ | **Open in …** your slicer, or **Open Together in …** for several minis |
| ++cmd+r++ | **Resize This Mini…**, or resize the selected minis together |
| ++opt+cmd+r++ | **Show in Finder** |
| ++shift+cmd+e++ | **Export for Virtual Tabletop…** |
| ++cmd+"Delete"++ | **Move to Trash** |
| ++cmd+z++ | **Undo**: puts minis moved to the Trash back, among other things |
| ++cmd+f++ | **Find**: the search field at the top of the list *(when you have more than six minis)* |
| ++ctrl+cmd+i++ | **Show Details** / **Hide Details**: the panel on the right of a mini's page |
| ++ctrl+cmd+s++ | **Show Sidebar** / **Hide Sidebar**: the list of minis |
| ++cmd+0++ | **Face Front**: turns the 3D view back to face you |
| ++opt+cmd+up++ / ++opt+cmd+down++ | **Move Up** / **Move Down** in the queue *(when the selected mini is waiting)* |
| ++cmd+comma++ | **Settings…** |
| ++cmd+w++ | Closes the window. A mini being made carries on (see [The queue](queue.md)) |
| ++cmd+q++ | Quits Mimic. While a mini is being made or the 3D engine downloads, it asks first |

### In the list of minis

| Keys | What it does |
|---|---|
| ++up++ / ++down++ | Picks the mini above or below |
| ++cmd++-click | Adds a mini to the selection, or takes it out |
| ++shift++-click | Selects every mini from the last one picked to this one |
| ++cmd+a++ | Selects every mini in view |
| ++space++ | Shows the mini's print file in Quick Look; ++space++ again closes it |
| ++"Delete"++ or ++cmd+"Delete"++ | **Move to Trash** |

### In the 3D view

Click the 3D view first, so it has the keyboard.

| Keys | What it does |
|---|---|
| ++left++ / ++right++ | Turns the mini |
| ++up++ / ++down++ | Tilts the mini |
| ++cmd+"="++ / ++cmd+"-"++ | Zooms in and out |
| ++cmd+0++, or double-click | Turns it back to face you and zooms back out |

With a mouse or trackpad: drag to turn it, and scroll or pinch to zoom toward the pointer.

### In a mini's previews and Quick Look

Click a preview in the details panel first.

| Keys | What it does |
|---|---|
| ++left++ / ++right++ | The previous or next preview, on the page and in Quick Look |
| ++up++ / ++down++ | Up and down the grid of previews |
| ++space++ or ++"Return"++ | Opens Quick Look on the preview, and closes it again |

### In New Mini, sheets and questions

| Keys | What it does |
|---|---|
| ++cmd+v++ | In New Mini, a copied picture becomes the mini's picture. In a text field, it pastes the text |
| ++"Return"++ | Presses the blue button: **Make Mini**, **Rename**, **Create**, **Duplicate**, **Build Shape** and so on |
| ++esc++ | **Cancel**, or **Done** in Compare Side by Side. In a question, it's always the way out |

### In the tour

| Keys | What it does |
|---|---|
| ++"Return"++ | **Next**, or **Done** on the last stop |
| ++esc++ | **Skip Tour** |

## The menus

### Mimic

| Item | What it does |
|---|---|
| **About Mimic** | Which Mimic you have, with its exact build |
| **Check for Updates…** | Looks for a newer Mimic *(in the downloaded app)* |
| **Settings…** ++cmd+comma++ | Everything Mimic needs, the 3D model, Draw Things and more (see [Settings](settings.md)) |
| **Install Command-Line Tool…** | Shows how to add `mimic` to Terminal (see [Mimic from a terminal](cli.md)) |
| **Quit Mimic** ++cmd+q++ | Asks first while a mini is being made or the 3D engine downloads |

### File

| Item | What it does |
|---|---|
| **New Mini…** ++cmd+n++ | Make a mini from a picture or a description (see [Making a mini](making-a-mini.md)) |
| **Import Model…** ++shift+cmd+i++ | Make a 3D model you already have print-ready (see [Importing a model](importing.md)) |
| **New Project…** ++shift+cmd+n++ | A folder to group minis in (see [Your minis and projects](organizing.md)) |
| Import from iPhone or iPad | Take a photo with your iPhone for New Mini's picture. macOS adds this item, named after your devices |

### Edit

| Item | What it does |
|---|---|
| **Undo** ++cmd+z++ | Puts back minis you moved to the Trash, and undoes **Rename…**, **Keep This One…** (and the rename after it) and **Duplicate…** |
| **Find** ++cmd+f++ | Puts the cursor in the list's search field *(when you have more than six minis)* |

### View

| Item | What it does |
|---|---|
| **Sort By** ▸ | **Date Made**, **Name** or **Size** |
| **Show** ▸ | **All Minis**, **Characters**, **Objects** or **Unfinished Minis** |
| **Show Sidebar** ++ctrl+cmd+s++ | Shows or hides the list of minis |
| **Show Details** ++ctrl+cmd+i++ | Shows or hides the details panel. It says **Hide Details** while the panel is open |
| **Face Front** ++cmd+0++ | Turns the 3D view back to face you |
| **Size Reference** ▸ | **None**, **25 mm Base**, **32 mm Person** or **Millimetre Grid** beside the mini (see [Printing and exporting](printing.md#see-how-big-it-really-is)) |

### Mini

What you can do to the selected mini, or minis. The same items are in a mini's right-click menu.
While New Mini or another sheet is open, everything here except **Pause After This One** (or
**Pause Queue**, **Resume Queue**) waits until you close it.

| Item | What it does |
|---|---|
| **Open in …** ++cmd+o++ | Opens the mini in your slicer. With several selected, it's **Open Together in …**: all of them on one bed |
| **Copies…** | Several of each on the plate, in one print file |
| **Show in Finder** ++opt+cmd+r++ | Shows the print file, or the mini's folder if it isn't made yet |
| **Export for Virtual Tabletop…** ++shift+cmd+e++ | A small 3D model of the mini to drag into a virtual tabletop (see [Printing and exporting](printing.md#export-for-a-virtual-tabletop)) |
| **Resize This Mini…** ++cmd+r++ | Makes the print file again at new sizes *(when it isn't waiting or being made)*. With several selected, it's **Resize 3 Minis…** (or however many) |
| **Build Shape** | Makes the 3D shape from a redrawn picture *(when its picture waits to be checked)* |
| **Try Again** | Makes a mini that didn't finish, from the step that failed *(when it didn't finish)* |
| **Report a Problem…** | Gathers what a bug report needs *(when it didn't finish)* |
| **Rename…** | Gives the mini a new name *(when it isn't waiting or being made)* |
| **Make Another Version…** | Makes it again with a new variation number (see [Versions](versions.md)) |
| **New 3D Shape…** | Keeps its picture and makes only the 3D shape again |
| **Edit & Make Again…** | Opens New Mini filled in from this mini |
| **Duplicate…** | A copy of the same shape, to make at another size *(when it isn't waiting or being made)* |
| **Move to Project** ▸ | **Unsorted**, any project, or **New Project…** |
| **Show Progress** | Opens the progress popover *(while a mini is being made)* |
| **Stop Making…** | Stops the mini being made. **Stop Resizing…** for a resize |
| **Move in Queue** ▸ | **Move to Front**, **Move Up** ++opt+cmd+up++, **Move Down** ++opt+cmd+down++, **Move to End**, and **Remove from Queue…** (**Cancel Resize…** for a resize) *(when the mini is waiting)* |
| **Pause After This One** | Lets the mini being made finish and starts no more. It's **Pause Queue** when nothing is being made, and **Resume Queue** while paused |
| **Move to Trash** ++cmd+"Delete"++ | Moves it to the Trash. **Edit → Undo** puts it back |

### Help

| Item | What it does |
|---|---|
| **Mimic Help** | Opens Mimic's guide on the web |
| **Show Tour** | The five-stop tour of Mimic again |
| **Report a Problem…** | Gathers what a bug report needs, with your private details taken out (see [Report a problem or an idea](report.md)) |

## Right-click menus

### A mini

**Open in …**, **Copies…**, **Show in Finder**, **Export for Virtual Tabletop…**,
**Resize This Mini…**, then **Make Another Version…**, **New 3D Shape…**, **Edit & Make Again…**,
**Duplicate…**, **Move to Project** ▸ and, while it waits, **Move in Queue** ▸. Then
**Build Shape**, or **Try Again** and **Report a Problem…** when they apply, and **Rename…** and
**Move to Trash**.

### Several selected minis

**Open Together in …**, **Copies…**, **Show in Finder**, **Resize 3 Minis…** (or however many),
**Move to Project** ▸ and **Move to Trash**.

### A project's name

**New Mini in This Project…**, **Open Together in …**, **Show in Finder**, **Resize All…**,
**Rename Project…** and **Delete Project…**.

### A waiting mini, in the progress popover

**Move to Front**, **Move Up**, **Move Down**, **Move to End** and **Remove from Queue…** (**Cancel
Resize…** for a resize).

## The toolbar

| Item | What it does |
|---|---|
| The progress | The mini being made, or how the last one went. Click it for the steps, the queue and **Stop…** |
| **Needs Setup** | Shows when something needs setting up, and opens Settings at it |
| **New Mini** (+) | ++cmd+n++ |
| **More** (…) | On a mini's page: **Copies…**, **Resize This Mini…**, **Edit & Make Again…**, **Export for Virtual Tabletop…** and **Show in Finder** |
| **Open in …** | On a mini's page: opens it in your slicer |
| **Show Details** / **Hide Details** | On a mini's page: the details panel, ++ctrl+cmd+i++ |

A note about a new version of Mimic also appears in the toolbar when there is one.

## The Dock icon's menu

Right-click Mimic's Dock icon for **New Mini…** and, when they apply, **Show Progress**,
**Stop Making…** (or **Stop Resizing…**) and, while minis wait in the queue,
**Pause After This One** (or **Pause Queue**, **Resume Queue**). The window comes back first,
even if you closed it.
