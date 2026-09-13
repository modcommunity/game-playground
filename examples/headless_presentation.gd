extends Node

const PlaygroundInventory := preload("../game/playground_inventory.gd")
const PlaygroundParty := preload("../game/playground_party.gd")
const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
const PlaygroundWorldGen := preload("../game/playground_worldgen.gd")

## The five addons this game gained at once: settings, randomness, audio, effects and a
## console — plus the generated map, the carried inventory, and the party.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]This is the only game in the family that holds all eight[/b], and the checks worth
## having are the ones about them meeting: one seed behind the map and the audio, one list
## behind the spawn menu and the backpack, and a generated map that is refused rather than
## shipped when nobody could cross it.
##
## Exits non-zero on any failure.

const CHECKS := 80

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-playground: the presentation layer")

	_test_one_seed()
	_test_generated_map_is_walkable()
	_test_generation_refuses_rather_than_ships()
	_test_the_backpack_is_the_prop_catalogue()
	_test_carrying_is_a_refusal()
	_test_sounds_and_effects()
	_test_console()
	_test_party_does_not_migrate()
	await _test_escape_menu()
	_test_chat_box()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _make() -> PlaygroundPresentation:
	var p := PlaygroundPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_one_seed() -> void:
	_section("One seed behind the map, the props and the noises")

	var p := _make()
	_check(p.rng != null, "there is a randomness manager")
	_check(p.rng.current_seed() != 0, "with a seed, picked and announced")
	_check(
		DotRegistry.has(DotRandomManager.SERVICE),
		"published, which is how a generated map finds it without naming the addon"
	)

	# The property that makes one seed usable by four things: two named streams never
	# disturb each other, so adding a fourth consumer cannot change the map.
	var map_a := p.rng.stream(&"map")
	var audio_a := p.rng.stream(&"audio")
	var expected: Array[float] = []
	for _i in range(4):
		expected.append(map_a.unit_at(_i))
	for _i in range(500):
		audio_a.next()
	var same := true
	for i in range(4):
		if not is_equal_approx(map_a.unit_at(i), expected[i]):
			same = false
	_check(same, "500 draws for audio leave the map's stream exactly where it was")

	_check(
		p.rng.seed_for(&"map") != p.rng.seed_for(&"waves"),
		"and two subsystems derive different seeds from the one number"
	)
	_check(
		p.audio.roll_source != null,
		"the audio takes its variation from the session's seed, so two people watching "
		+ "the same sandbox hear the same thing"
	)

	p.queue_free()
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_generated_map_is_walkable() -> void:
	_section("A generated sandbox nobody could cross is not shipped")

	var res := PlaygroundWorldGen.generate(4242)
	_check(res.ok, "a sandbox generates")
	if not res.ok:
		_done()
		return

	var doc := res.value as DotProcGenDoc
	_check(doc.rooms.size() >= 5, "with rooms in it (%d)" % doc.rooms.size())
	_check(
		doc.links.size() > doc.rooms.size() - 1,
		"and more corridors than a spanning tree, so it has loops rather than being a "
		+ "sequence (%d links for %d rooms)" % [doc.links.size(), doc.rooms.size()]
	)

	var spawns := doc.markers_of(&"spawn")
	_check(spawns.size() == 1, "there is a spawn")
	var spawn: Vector2i = spawns[0]["cell"]

	# The check that matters, and the one every other kind passes without: everything
	# placed can actually be walked to.
	var reached := doc.reachable_from(spawn)
	var reachable := {}
	for idx in reached:
		reachable[idx] = true

	var stranded := 0
	for m in doc.markers:
		var cell: Vector2i = m.get("cell", Vector2i.ZERO)
		if not reachable.has(cell.y * doc.width + cell.x):
			stranded += 1
	_check(stranded == 0, "and every prop point can be reached from it")

	# Two runs of one seed are one map, which is what lets a server and a client agree
	# without sending a map.
	var again := PlaygroundWorldGen.generate(4242)
	_check(
		(again.value as DotProcGenDoc).fingerprint() == doc.fingerprint(),
		"two runs of one seed produce the same map, to the byte"
	)
	var other := PlaygroundWorldGen.generate(4243)
	_check(
		(other.value as DotProcGenDoc).fingerprint() != doc.fingerprint(),
		"and a different seed a different one"
	)

	_done()


# --- 3 ----------------------------------------------------------------------

func _test_generation_refuses_rather_than_ships() -> void:
	_section("What a map that cannot be generated leaves behind")

	# Too small for the rooms the pipeline asks for. A generator that shipped this anyway
	# would produce one room and call it a sandbox.
	var tiny := PlaygroundWorldGen.pipeline(12, 12)
	tiny.max_attempts = 2
	var res := tiny.generate(1)
	_check(not res.ok, "a map too small to satisfy the pipeline fails rather than shipping")
	_check(
		res.error.message != "",
		"saying which step refused it, rather than producing something unplayable"
	)

	# And what the map does about it: a plate with walls, and a spawn on it. A partially
	# generated sandbox is a room with no way out, which is worse than an empty plate.
	var map := load("res://maps/pg_generated.gd").new() as Node3D
	add_child(map)
	map.call("configure", 4242, null)
	_check(
		map.get("document") != null,
		"a generated map that succeeded holds its document, for a console command"
	)
	var spawn: Vector3 = map.get("fallback_spawn")
	_check(spawn.y > 0.0, "and a spawn above the floor")
	# The lesson from the surf maps: a capsule that starts within a unit or two of a seam
	# is a coin toss whichever way the collision backend rounds.
	_check(spawn.y >= 1.0, "clear of the floor rather than resting exactly on it")
	_check(map.get_child_count() > 2, "with geometry under it")
	map.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_the_backpack_is_the_prop_catalogue() -> void:
	_section("What you can carry is what this server can make")

	var props := PlaygroundSpawnables.catalogue()
	var items := PlaygroundInventory.build_catalogue(props)
	_check(items.validate().ok, "the item catalogue validates")

	# One list. A second table of what can be carried would go stale the first time
	# somebody added a prop, which is this tree's most repeated bug.
	_check(
		items.ids().size() == props.props.size(),
		"one item per prop (%d against %d)" % [items.ids().size(), props.props.size()]
	)

	var heavy: DotPropDef = null
	for d in props.props:
		if heavy == null or d.mass > heavy.mass:
			heavy = d
	var item := items.find(heavy.id)
	_check(item != null, "the heaviest prop has an item")
	_check(
		is_equal_approx(item.weight, maxf(heavy.mass, 1.0)),
		"whose weight is the prop's own mass, which until now exactly one thing read"
	)
	_check(
		item.kind == DotInvItem.Kind.UNIQUE,
		"and which does not stack, because every prop carries its own state once spawned"
	)

	_done()


# --- 5 ----------------------------------------------------------------------

func _test_carrying_is_a_refusal() -> void:
	_section("Buying holds something; spawning takes it out")

	var inv := PlaygroundInventory.new()
	inv.name = "Inventory"
	add_child(inv)
	var res := inv.setup(PlaygroundSpawnables.catalogue())
	_check(res.ok, "the inventory sets up")
	if not res.ok:
		_done()
		return

	var who := &"player_one"
	var id := inv.catalogue.ids()[0]

	# The whole feature: before this, the shop charged per spawn and nothing was ever
	# held, so "buy three crates" and "buy one crate three times" were the same thing.
	_check(
		not inv.take(who, id).ok,
		"taking something you are not carrying is refused"
	)
	_check(inv.give(who, id).ok, "buying puts one in the bag")
	_check(inv.carries(who, id) == 1, "and you are carrying it")
	_check(inv.take(who, id).ok, "spawning takes it out")
	_check(inv.carries(who, id) == 0, "leaving nothing")
	_check(not inv.take(who, id).ok, "and a second spawn is refused")

	# The grid and the weight are two different limits, and a refusal has to say which.
	var given := 0
	for _i in range(60):
		if inv.give(who, id).ok:
			given += 1
		else:
			break
	_check(given > 0, "a bag holds several")
	_check(given < 60, "and stops (%d), rather than being a list with no end" % given)

	var q := inv.query(who)
	_check(q.size() > 0, "and what is in it can be listed")
	_check(
		q.size() == inv.carries(who, id),
		"with the query agreeing with the count, because both read one document"
	)

	inv.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_sounds_and_effects() -> void:
	_section("Somebody else's building, and the switch for it")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	p.audio.listener_position = Vector3.ZERO

	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(sink.count_of(&"prop_spawn") == 1, "a prop you spawned makes a noise")

	sink.forget()
	for _i in range(10):
		p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(
		sink.count_of(&"prop_spawn") <= 3,
		"and ten in one tick make at most three (%d), because a dozen people emptying a "
		% sink.count_of(&"prop_spawn") + "spawn menu is a building site rather than a fault"
	)

	# The sandbox's own setting, and it is about somebody else's work rather than yours.
	p.settings.set_value(&"prop_sounds", false)
	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), false)
	_check(
		sink.count_of(&"prop_spawn") == 0,
		"somebody else's prop is silent for a player who turned that off"
	)
	# Past the cooldown the burst above used. A check that measures a sound while it is
	# being refused for a cooldown measures the cooldown, and reads as the setting being
	# broken in the other direction.
	OS.delay_msec(100)
	sink.forget()
	p.on_prop_spawned(Vector3(4, 0, 4), true)
	_check(
		sink.count_of(&"prop_spawn") == 1,
		"while your own still is, because it is the answer to something you just did"
	)

	sink.forget()
	p.on_refused()
	var refused := p.audio.catalogue.find(&"refused")
	var landed := p.audio.catalogue.find(&"prop_land")
	_check(sink.count_of(&"refused") == 1, "a refusal makes a noise")
	_check(
		refused.priority > landed.priority,
		"and outranks a crate hitting the floor, because it answers something you did"
	)

	p.settings.set_value(&"shake_scale", 0.0)
	p.on_tool_punt(Vector3.ZERO, true)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"and a player who turned shake off gets exactly none of it"
	)

	p.queue_free()
	_done()


# --- 7 ----------------------------------------------------------------------

func _test_console() -> void:
	_section("The console, and the command this game needs most")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")
	_check(
		p.console.all_names().has("seed"),
		"with `seed` in it -- a generated map nobody can name the seed of is a map "
		+ "nobody can share"
	)

	var missing := PackedStringArray()
	for key in PlaygroundPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(missing.is_empty(), "every setting is reachable (%s)" % ", ".join(missing))

	var res := p.console.submit("seed")
	_check(res.ok, "asking for the seed works")

	p.console.submit("fx_quality 0")
	_check(p.fx.config.quality == 0, "a console line reaches the effects config")

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential never reaches the scrollback"
	)

	p.queue_free()
	_done()


# --- 8 ----------------------------------------------------------------------

func _test_party_does_not_migrate() -> void:
	_section("A host leaving a sandbox takes the sandbox with them")

	DotP2PSignallerLoopback.reset_all()

	var party := PlaygroundParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The decision only this game makes, and it follows from one fact: the world IS the
	# host's physics state, so electing a new host hands everybody an empty room.
	_check(
		not party.session.config.migrate_host,
		"a sandbox does not migrate its host, because the world does not move with it"
	)
	_check(
		party.session.config.trust == DotP2PConfig.Trust.HOST_AUTHORITATIVE,
		"while the host decides, which in a sandbox is what a friend hosting should do"
	)

	_check(party.reporting_allowed(), "an ordinary session files what it likes")
	party.session._state = &"hosting"
	_check(
		not party.reporting_allowed(),
		"and a live one files nothing, asked in one place rather than by four reporters"
	)

	var lines := party.describe_lines()
	var says := false
	for l in lines:
		if l.contains("does not survive"):
			says = true
	_check(says, "and it says so when asked, rather than leaving it to be discovered")

	party.queue_free()
	_done()


func _test_chat_box() -> void:
	_section("A sandbox where you can be talked to and can talk back")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds a chat box at all")

	if window == null:
		_done()
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)

	# The channels are the server's own definitions rather than a second list here.
	var ids := PackedStringArray()
	for entry in window.channels:
		ids.append(String(entry.get("id", "")))
	_check(
		Array(ids).has(String(PlaygroundServices.CHANNEL_ALL))
			and Array(ids).has(String(PlaygroundServices.CHANNEL_NEAR)),
		"offering the channels the server actually routes (%s)" % [ids]
	)
	_check(
		not Array(ids).has(String(PlaygroundServices.CHANNEL_ADMIN)),
		"and not the admin one, which a player cannot send on anyway"
	)

	_check(window.enabled, "drawn by default, on a server that said nothing")

	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes it away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.settings.set_value(&"chat_window", &"auto")
	p.set_chat_relayed(false)
	_check(window.enabled, "and auto gives it back")

	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does, so a typed key is not a tool being fired")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	_done()


# --- Harness ---------------------------------------------------------------

func _test_escape_menu() -> void:
	_section("Escape reaches a setting, which it could not before")

	var p := PlaygroundPresentation.new()
	p.name = "MenuP"
	add_child(p)
	if not _check(p.setup().ok, "a presentation layer to read the settings from"):
		_done()
		return

	var stack := DotScreenStack.new()
	stack.name = "Stack"
	stack.register_service = false
	stack.manage_mouse = false
	add_child(stack)
	stack.setup()

	var pause := DotPauseScreen.new()
	pause.name = "Pause"
	_check(
		pause.build(PackedStringArray(["Resume", "Settings", "Servers", "Leave"])).ok,
		"a pause menu builds"
	)
	stack.register(pause)

	var screen := DotSettingsScreen.new()
	screen.name = "Settings"
	_check(screen.build(p.settings).ok, "and a settings screen onto the real settings")
	stack.register(screen)

	stack.push(&"pause")
	await get_tree().process_frame
	await get_tree().process_frame

	# THAT THE PUSH LANDED, which is the check this section shipped without.
	#
	# `DotScreen`'s default id is the NODE NAME, so a screen called `Pause` registered as
	# `&"Pause"` and `push(&"pause")` answered "no such screen" -- reported, not fatal, so
	# this game's pause menu never opened at all. Every check below passed anyway: a
	# REGISTERED screen is sized and focusable whether or not it is on screen. A rendered
	# frame in dot-ui is what found it, and this is the assertion that would have.
	_check(stack.top_id() == &"pause", "the menu OPENS, rather than registering under its node name")
	_check(pause.visible, "so it is actually on screen")

	# The one thing an assertion reaches about a Control, and this family has shipped a
	# 0 x 0 one twice.
	_check(pause.size.x > 0.0 and pause.size.y > 0.0, "the menu has a size")
	_check(
		pause.get_node_or_null(pause.initial_focus) != null,
		"and something focused, or it cannot be used with a gamepad at all"
	)
	_check(pause.button(&"settings") != null, "with a way to reach the settings")

	stack.push(&"settings")
	await get_tree().process_frame

	# The check this section exists for: `to_config()` is a SNAPSHOT and
	# `absorb_config()` is the way back. A screen that called only the panel's apply would
	# report success and change nothing, for ever, and every check above passes either way.
	p.settings.set_value(&"master_volume", 0.9)
	screen._on_push()
	screen.panel._edited("master_volume", 0.15)
	screen.apply()
	_check(
		is_equal_approx(p.settings.get_float(&"master_volume"), 0.15),
		"Apply reaches the settings manager rather than the snapshot it was bound to"
	)
	_check(
		is_equal_approx(p.audio.mixer.master, 0.15),
		"and carries on to the mixer, which is what a player actually hears"
	)

	stack.clear()
	stack.queue_free()
	p.queue_free()
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition
