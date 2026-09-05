class_name PlaygroundSpawnMenu
extends DotScreen

## The spawn menu: hold Q, pick something, click it.
##
## [b]The sandbox Q menu, and the behaviour is the part that matters.[/b] Holding the
## key opens it and releasing closes it; a quick tap pins it open so both hands are
## free. Clicking a prop [i]spawns[/i] it rather than arming a separate spawn key,
## because a menu that only selects means every prop costs two actions and building
## anything is twice the clicks. The menu stays open afterwards, so a wall is nine
## clicks rather than nine open-and-closes.
##
## [b]Three tabs, two systems.[/b] Props and entities are one [DotPropCatalogue] split
## by [method PlaygroundSpawnables.kind_of]; weapons are their own registry, because a
## weapon is never spawned and dot-props' catalogue requires a scene path. The player
## sees three kinds of thing; underneath, one of them is a different system, and it is
## different for a reason rather than by accident.
##
## [b]dot-props deliberately ships no menu[/b] — "a menu of four hundred props with
## icons and a search box is a game's own design", which is right, and this is that
## design for this game. What the addon provides is everything the menu needs
## **without loading a single scene**: `categories()`, `in_category()` and `search()`
## all read fields of a [DotPropDef], so a four-hundred-prop catalogue costs four
## hundred dictionary lookups rather than four hundred `load()` calls. The icons are
## drawn from the same fields — see [PlaygroundIcons] — so opening the menu still
## loads nothing.
##
## The menu never spawns anything itself. It emits, and [PlaygroundClient] asks the
## server — the same division the tools make, and the reason this file works unchanged
## when a dot-net bridge arrives and a spawn becomes a message.

const CHANNEL := "playground.menu"

## The pseudo-category that shows everything on a tab. Not a real category.
const ALL := &"__all"

## Card size. Wide enough for "Large crate" on one line at the default font.
const CARD := Vector2(146.0, 92.0)

## The key that puts the caret in the search box.
##
## [b]Not "any letter", and not focused on open.[/b] Focusing the search box by default
## sends W, A, S and D into it — the player stands still typing "wasd" while the menu
## looks exactly as it should — and this is a menu you can walk around with. A slash is
## the convention every search-in-a-list uses and it is not a movement key.
const SEARCH_KEY := KEY_SLASH

enum Tab {
	PROPS,
	ENTITIES,
	WEAPONS,
}

## A prop or an entity was clicked. The client turns this into a spawn request.
signal prop_chosen(prop_id: StringName)

## A weapon was clicked. The client equips it.
signal weapon_chosen(weapon_id: StringName)

## One of the two built-in tools was clicked: the physics gun, the gravity gun.
signal tool_chosen(tool_id: StringName)

## Something that is neither — undo, unfreeze everything, clear my props.
signal action_requested(action: StringName)

## What the props and entities tabs are built from. Set before the first push.
var catalogue: DotPropCatalogue = null

## What the weapons tab is built from.
var weapons: Array[PlaygroundWeaponDef] = []

## Which prop is armed, so the spawn key and the launcher repeat it.
var selected: StringName = &""

## What is in the player's hands, for the footer.
var tool: StringName = &""

var _tab: Tab = Tab.PROPS
var _category: StringName = ALL
var _search: String = ""

var _tabs: TabBar = null
var _categories: VBoxContainer = null
var _grid: GridContainer = null
var _search_box: LineEdit = null
var _footer: Label = null
var _empty: Label = null
var _first_card: Button = null


func _screen_id() -> StringName:
	return &"spawn_menu"


# --- Building ---------------------------------------------------------------

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	# A dim backdrop, so the menu reads as something in front of the world rather
	# than as a panel floating in it. It is also what stops a click in the margin
	# reaching the physics gun — the client guards that too, and both are cheap next
	# to punting a crate while reaching for the search box.
	var scrim := ColorRect.new()
	scrim.name = "Scrim"
	scrim.color = Color(0.02, 0.03, 0.05, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	# `set_anchors_and_offsets_preset`, not `set_anchors_preset`: the second sets the
	# anchors and leaves the offsets alone, so a Control built in code keeps the zero
	# size it was created with and the whole menu lays out inside nothing while being,
	# by every property, correctly configured. dot-ui had five of these.
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 96.0
	panel.offset_top = 64.0
	panel.offset_right = -96.0
	panel.offset_bottom = -96.0
	add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 14)
	panel.add_child(margin)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 10)
	margin.add_child(rows)

	rows.add_child(_build_header())
	rows.add_child(HSeparator.new())

	var body := HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	rows.add_child(body)

	body.add_child(_build_sidebar())
	body.add_child(_build_grid())

	rows.add_child(HSeparator.new())

	_footer = Label.new()
	_footer.name = "Footer"
	rows.add_child(_footer)


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 14)

	var title := Label.new()
	title.text = "Spawn"
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)

	_tabs = TabBar.new()
	_tabs.name = "Tabs"
	# `clip_tabs` off, and it is not cosmetic: on — which is the default — a TabBar
	# reports a minimum width of about one tab, hides the rest behind scroll arrows,
	# and lets the HBox lay the title out underneath it. Two of the three tabs were
	# unreachable and the heading was drawn through. Only a screenshot shows it.
	_tabs.clip_tabs = false
	_tabs.add_tab("Props")
	_tabs.add_tab("Entities")
	_tabs.add_tab("Weapons")
	_tabs.tab_changed.connect(_on_tab_changed)
	header.add_child(_tabs)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_search_box = LineEdit.new()
	_search_box.name = "Search"
	_search_box.placeholder_text = "Search  ( / )"
	_search_box.custom_minimum_size = Vector2(260.0, 0.0)
	_search_box.clear_button_enabled = true
	_search_box.text_changed.connect(_on_search_changed)
	# Enter puts the keyboard back where the player expects it. Without it there is no
	# way out of the search box that is not the mouse, and W still types a W.
	_search_box.text_submitted.connect(
		func(_text: String) -> void: _search_box.release_focus()
	)
	header.add_child(_search_box)

	return header


func _build_sidebar() -> Control:
	var side := VBoxContainer.new()
	side.name = "Sidebar"
	side.custom_minimum_size = Vector2(184.0, 0.0)
	side.add_theme_constant_override("separation", 4)

	_categories = VBoxContainer.new()
	_categories.name = "Categories"
	_categories.add_theme_constant_override("separation", 4)
	side.add_child(_categories)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)

	var heading := Label.new()
	heading.text = "In hand"
	side.add_child(heading)

	# Ids rather than indices, because the client matches on them and a reordering
	# here would otherwise silently swap two tools.
	side.add_child(_flat_button(
		"Physics gun",
		"Hold to carry, scroll for distance, right click to freeze",
		func() -> void: tool_chosen.emit(&"phys")
	))
	side.add_child(_flat_button(
		"Gravity gun",
		"Left click punts, right click pulls and carries",
		func() -> void: tool_chosen.emit(&"grav")
	))

	side.add_child(HSeparator.new())

	side.add_child(_flat_button(
		"Undo last",
		"Removes the last prop you spawned",
		func() -> void: action_requested.emit(&"undo")
	))
	side.add_child(_flat_button(
		"Unfreeze mine",
		"Thaws every prop you have frozen",
		func() -> void: action_requested.emit(&"unfreeze")
	))
	side.add_child(_flat_button(
		"Remove mine",
		"Removes every prop you own",
		func() -> void: action_requested.emit(&"clear")
	))

	return side


func _flat_button(text: String, tip: String, on_press: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(on_press)
	return button


func _build_grid() -> Control:
	var holder := VBoxContainer.new()
	holder.name = "Holder"
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder.add_child(scroll)

	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = 5
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(_grid)

	# Said, rather than left as an empty rectangle. A search with no results and a tab
	# with nothing on it look identical when both are blank, and the player's next
	# move is different in each case.
	_empty = Label.new()
	_empty.name = "Empty"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.visible = false
	holder.add_child(_empty)

	return holder


# --- Lifecycle --------------------------------------------------------------

func _on_push() -> void:
	# Rebuilt on every open rather than once. The catalogue is replaced outright when
	# an operator points `props_path` somewhere else and reloaded on a map change, and
	# a menu built once shows a list the server has stopped offering — every click on
	# which is refused with "no such prop".
	refresh()

	# A card takes focus, not the search box: see SEARCH_KEY.
	if _first_card != null and _first_card.is_inside_tree():
		_first_card.grab_focus()


func _on_pop() -> void:
	# The search does not survive being put away. Coming back to a menu still filtered
	# to "boul" from a minute ago reads as a menu with one prop in it.
	_search = ""

	if _search_box != null:
		_search_box.text = ""


## Rebuilds the category list, the grid and the footer.
func refresh() -> void:
	_rebuild_categories()
	_rebuild_grid()
	_rebuild_footer()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_top or not (event is InputEventKey):
		return

	var key := event as InputEventKey

	if not key.pressed or key.is_echo() or key.physical_keycode != SEARCH_KEY:
		return

	if _search_box != null:
		_search_box.grab_focus()
		_search_box.select_all()

	# Marked handled so the slash does not also arrive as text in the box it just
	# focused, and so the client's own key handling never sees it.
	get_viewport().set_input_as_handled()


# --- Tabs and categories ----------------------------------------------------

func _on_tab_changed(index: int) -> void:
	_tab = index as Tab
	# The category and the search are per tab. Carrying "containers" onto the weapons
	# tab would show nothing and read as the tab being broken.
	_category = ALL
	_search = ""

	if _search_box != null:
		_search_box.text = ""

	refresh()


func _rebuild_categories() -> void:
	for child in _categories.get_children():
		child.queue_free()

	_add_category(ALL, "All (%d)" % _all_in_tab().size())

	for category_name in _categories_for_tab():
		var id := StringName(category_name)
		_add_category(
			id, "%s (%d)" % [category_name.capitalize(), _count_in_category(id)]
		)


func _categories_for_tab() -> PackedStringArray:
	if _tab == Tab.WEAPONS:
		return PlaygroundWeapons.categories(weapons)

	var seen := {}

	for entry in _all_in_tab():
		seen[String(_category_of(entry))] = true

	var out := PackedStringArray(seen.keys())
	out.sort()

	return out


func _add_category(id: StringName, text: String) -> void:
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.button_pressed = id == _category
	button.pressed.connect(func() -> void:
		_category = id
		# The search and the category are one filter, not two: a search that survived
		# a category click would show results from a category the player has just
		# navigated away from, which reads as the click doing nothing.
		_search = ""
		if _search_box != null:
			_search_box.text = ""
		_rebuild_categories()
		_rebuild_grid()
	)
	_categories.add_child(button)


# --- The grid ---------------------------------------------------------------

func _rebuild_grid() -> void:
	for child in _grid.get_children():
		child.queue_free()

	_first_card = null

	var visible_now := _visible()

	for entry in visible_now:
		var card: Button = (
			_weapon_card(entry as PlaygroundWeaponDef)
			if _tab == Tab.WEAPONS
			else _prop_card(entry as DotPropDef)
		)

		_grid.add_child(card)

		if _first_card == null:
			_first_card = card

	if _empty != null:
		_empty.visible = visible_now.is_empty()
		_empty.text = (
			"Nothing matches '%s'." % _search if _search != "" else "Nothing here."
		)


## One card. A [Button] rather than a container, deliberately.
##
## [b]A Button is focusable and a VBoxContainer is not.[/b] Godot's own focus
## neighbours then make the whole grid navigable with a gamepad or the arrow keys for
## free — and a menu that cannot be used without a mouse is the failure dot-ui's
## `initial_focus` exists to prevent. Icon above text is `vertical_icon_alignment`,
## which is exactly what that property is for.
func _card(icon: Texture2D, text: String, tip: String) -> Button:
	var button := Button.new()
	button.icon = icon
	button.text = text
	button.tooltip_text = tip
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = CARD
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.clip_text = true
	return button


func _prop_card(def: DotPropDef) -> Button:
	var card := _card(
		PlaygroundIcons.for_def(def),
		def.name_or_id(),
		"%s\n%s · %.0f kg · costs %d" % [
			def.name_or_id(),
			DotPropDef.Size.keys()[def.size].capitalize(),
			def.mass,
			def.cost,
		]
	)

	card.pressed.connect(_on_prop_pressed.bind(def.id))
	# The id on the button, so `shown()` and `card_for()` read what is actually on
	# screen rather than re-running the filter. A second copy of a filter is a second
	# thing that can disagree with the first, and the one that would be wrong is the
	# one nobody is looking at.
	card.set_meta(&"entry", def.id)

	return card


func _weapon_card(def: PlaygroundWeaponDef) -> Button:
	var card := _card(
		PlaygroundIcons.for_weapon(def),
		def.name_or_id(),
		"%s\n%s" % [def.name_or_id(), def.description]
	)

	card.pressed.connect(_on_weapon_pressed.bind(def.id))
	card.set_meta(&"entry", def.id)

	return card


# --- What is on screen ------------------------------------------------------

## Everything on the current tab, before the category and the search are applied.
func _all_in_tab() -> Array:
	if _tab == Tab.WEAPONS:
		return weapons

	if catalogue == null:
		return []

	var wanted := (
		PlaygroundSpawnables.Kind.ENTITY
		if _tab == Tab.ENTITIES
		else PlaygroundSpawnables.Kind.PROP
	)

	var out: Array = []

	for def in catalogue.props:
		if PlaygroundSpawnables.kind_of(def) == wanted:
			out.append(def)

	return out


func _count_in_category(category: StringName) -> int:
	var count := 0

	for entry in _all_in_tab():
		if _category_of(entry) == category:
			count += 1

	return count


func _category_of(entry: Variant) -> StringName:
	return (
		(entry as PlaygroundWeaponDef).category
		if entry is PlaygroundWeaponDef
		else (entry as DotPropDef).category
	)


func _name_of(entry: Variant) -> String:
	return (
		(entry as PlaygroundWeaponDef).name_or_id()
		if entry is PlaygroundWeaponDef
		else (entry as DotPropDef).name_or_id()
	)


func _id_of(entry: Variant) -> StringName:
	return (
		(entry as PlaygroundWeaponDef).id
		if entry is PlaygroundWeaponDef
		else (entry as DotPropDef).id
	)


## The entries the grid should show: the search if there is one, else the category.
##
## [b]The search reaches across the whole tab, not the selected category.[/b] A player
## typing "barrel" wants the barrel, and telling them it does not exist because they
## last clicked "Toys" is the wrong answer to the question they asked. It does not
## reach across tabs, because the tabs are three different kinds of thing and a weapon
## turning up in a prop search is not a result, it is a surprise.
func _visible() -> Array:
	var pool := _all_in_tab()

	if _search != "":
		var needle := _search.to_lower()
		var found: Array = []

		for entry in pool:
			if (
				_name_of(entry).to_lower().contains(needle)
				or String(_id_of(entry)).to_lower().contains(needle)
			):
				found.append(entry)

		return found

	if _category == ALL:
		return pool

	var out: Array = []

	for entry in pool:
		if _category_of(entry) == _category:
			out.append(entry)

	return out


## The ids the grid is currently showing, in order. Read off the buttons themselves.
func shown() -> Array[StringName]:
	var out: Array[StringName] = []

	if _grid == null:
		return out

	for child in _grid.get_children():
		if child.has_meta(&"entry"):
			out.append(child.get_meta(&"entry"))

	return out


## The card for one entry on the current tab, or null when it is not on screen.
func card_for(id: StringName) -> Button:
	if _grid == null:
		return null

	for child in _grid.get_children():
		if child.has_meta(&"entry") and child.get_meta(&"entry") == id:
			return child as Button

	return null


## Switches tab from code, as a click on the tab bar would.
func show_tab(tab: Tab) -> void:
	if _tabs != null:
		# Through the TabBar rather than by setting `_tab`, so the bar and the grid
		# cannot disagree about which tab is open.
		_tabs.current_tab = int(tab)
	else:
		_on_tab_changed(int(tab))


# --- Clicks -----------------------------------------------------------------

func _on_search_changed(text: String) -> void:
	_search = text.strip_edges()
	_rebuild_grid()


func _on_prop_pressed(prop_id: StringName) -> void:
	selected = prop_id
	prop_chosen.emit(prop_id)
	_rebuild_footer()


func _on_weapon_pressed(weapon_id: StringName) -> void:
	weapon_chosen.emit(weapon_id)
	_rebuild_footer()


func _rebuild_footer() -> void:
	if _footer == null:
		return

	# The verb follows the tab. "Click to spawn" over a grid of weapons is wrong in
	# the one place a player looks to find out what a click will do — and clicking a
	# weapon really does something different from clicking a prop.
	_footer.text = "   ·   ".join(PackedStringArray([
		"Click to equip" if _tab == Tab.WEAPONS else "Click to spawn",
		"E spawns %s again" % _armed_name(),
		"%s in hand" % name_of_tool(tool),
		"/ to search",
		"release Q to close, tap Q to pin",
	]))


func _armed_name() -> String:
	if selected == &"" or catalogue == null:
		return "nothing"

	var def := catalogue.get_prop(selected)

	return def.name_or_id() if def != null else String(selected)


## What is in the player's hands, for the footer and the HUD.
##
## Static and shared, because the HUD says the same thing in its own corner and two
## spellings of "gravity gun" is the sort of difference nobody notices until a
## screenshot puts them side by side.
static func name_of_tool(tool_id: StringName) -> String:
	match tool_id:
		&"phys":
			return "physics gun"
		&"grav":
			return "gravity gun"
		&"":
			return "nothing"
		_:
			return String(tool_id)


func describe() -> Dictionary:
	var out := super.describe()
	out["tab"] = Tab.keys()[_tab]
	out["category"] = String(_category)
	out["shown"] = shown().size()
	out["selected"] = String(selected)
	return out
