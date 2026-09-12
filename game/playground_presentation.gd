class_name PlaygroundPresentation
extends Node

## Settings, randomness, audio, effects and a console.
##
## [b]This is the only game in the family that holds dot-randomness as well[/b], and the
## reason is the generated map: a sandbox whose layout, whose scattered props and whose
## wave composition all come out of **one** seed is a sandbox two people can compare notes
## about. Three separate generators would be three numbers, and "what seed are you on"
## would stop meaning anything.
##
## The manager is here rather than in `Playground` because it is the thing that owns the
## session's seed, and because `Playground` should be able to run without it — a server
## with no randomness manager falls back to a fixed seed and says so, which is better than
## a sandbox that is a different shape on every boot and cannot say why.

const CHANNEL := "playground.presentation"

const SCHEMA_VERSION := 1
const SOUND_DIR := "res://audio"
const FX_DIR := "res://scenes/fx"

var settings: DotSettingsManager = null
var rng: DotRandomManager = null
var audio: DotAudioManager = null
var fx: DotFxManager = null
var console: DotConsoleController = null
var console_panel: DotConsolePanel = null

## The in-game chat box. See [method _build_chat].
var chat_window: DotChatWindow = null

var client: Node = null

var _layer: CanvasLayer = null
var _chat_layer: CanvasLayer = null

## Whether the server said something else is carrying chat. See [method set_chat_relayed].
var _chat_relayed: bool = false


func setup() -> DotResult:
	# Randomness first, and the order is load-bearing in the same way `RoomServices`'
	# moderation-before-chat is: the map generator asks `DotRegistry` for a seed source,
	# and a manager registered after the map has been built is a manager the map did not
	# use -- with nothing erroring, because falling back to a fixed seed is a legitimate
	# configuration and therefore indistinguishable from the bug.
	var seeded := _build_randomness()
	if not seeded.ok:
		return seeded

	var settled := _build_settings()
	if not settled.ok:
		return settled
	var heard := _build_audio()
	if not heard.ok:
		return heard
	var drawn := _build_fx()
	if not drawn.ok:
		return drawn
	var consoled := _build_console()
	if not consoled.ok:
		return consoled

	_build_chat()

	apply_all()
	return DotResult.success(null)


func apply_all() -> void:
	for key in settings.schema.keys():
		_on_setting_changed(key, settings.get_value(key), &"applied")


# --- Randomness -------------------------------------------------------------

func _build_randomness() -> DotResult:
	rng = DotRandomManager.new()
	rng.name = "Random"
	rng.config = DotRandomConfig.new()
	# Zero picks one and logs it, which is what "what seed are you on" needs an answer to.
	rng.config.master_seed = 0
	rng.config.announce_seed = true
	# The scope keeps two games on one seed from being one world. A launcher handing the
	# same number to the sandbox and to the arena should produce two different places.
	rng.config.scope = &"playground"
	add_child(rng)

	var res := rng.setup()
	if not res.ok:
		return res.wrap("the playground's randomness")
	return DotResult.success(null)


# --- Settings ---------------------------------------------------------------

static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"sfx_volume", 1.0, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.number(&"voice_volume", 1.0, 0.0, 1.0, &"audio"))

	s.add(DotSettingsDef.number(&"sensitivity", 2.5, 0.05, 20.0, &"controls").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.boolean(&"hold_to_open_menu", true, &"controls").with_description(
		"Hold Q for the spawn menu, or press it to pin it open."
	).with_scope(DotSettingsDef.Scope.ACCOUNT))

	s.add(DotSettingsDef.integer(&"field_of_view", 100, 70, 130, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.integer(&"fx_quality", 3, 0, 3, &"video"))

	s.add(DotSettingsDef.number(&"shake_scale", 1.0, 0.0, 2.0, &"accessibility")
		.with_description("Zero turns camera shake off entirely."))
	s.add(DotSettingsDef.boolean(&"allow_flashes", true, &"accessibility"))

	# Chat. ACCOUNT scope for all three: which key opens chat and whether a player wants
	# the box at all is about the person, not about this machine.
	s.add(DotSettingsDef.choice(
		&"chat_window",
		&"auto",
		[&"auto", &"on", &"off"] as Array[StringName],
		&"chat"
	).with_scope(DotSettingsDef.Scope.ACCOUNT).with_description(
		"auto hides the box on a server already carrying chat somewhere the player can "
		+ "see it; on always draws it; off never does."
	))
	s.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.binding(&"chat_near_key", "U", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Opens chat on the proximity channel rather than on all."))

	# A sandbox's own: how much of somebody else's building you want to be told about.
	s.add(DotSettingsDef.boolean(&"prop_sounds", true, &"sandbox").with_description(
		"Whether other people's props make a noise when they land."
	))
	return s


func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	settings.schema = schema()
	settings.local_store = DotSettingsStoreFile.new("user://playground_settings")
	settings.app_namespace = &"game_playground"
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("the playground's settings")
	settings.changed.connect(_on_setting_changed)
	return DotResult.success(null)


func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	match key:
		&"master_volume":
			audio.mixer.master = float(value)
			audio.mixer.apply_to_buses()
		&"sfx_volume":
			audio.mixer.sfx = float(value)
			audio.mixer.apply_to_buses()
		&"voice_volume":
			audio.mixer.voice = float(value)
			audio.mixer.apply_to_buses()
		&"shake_scale":
			fx.config.shake_scale = float(value)
		&"allow_flashes":
			fx.config.allow_flashes = bool(value)
		&"fx_quality":
			fx.config.quality = int(value)
		&"chat_window":
			_apply_chat_visibility()
		&"chat_open_key":
			_bind_chat(chat_window.open_action if chat_window != null else &"", str(value))
		&"chat_near_key":
			_bind_chat(chat_window.team_action if chat_window != null else &"", str(value))
		_:
			pass


# --- Audio ------------------------------------------------------------------

## What a sandbox makes a noise about, which is mostly other people building.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	var spawn := DotAudioDef.new()
	spawn.id = &"prop_spawn"
	spawn.path = "%s/prop_spawn.ogg" % SOUND_DIR
	spawn.kind = DotAudioDef.Kind.POSITIONAL_3D
	spawn.bus = &"SFX"
	spawn.max_distance = 60.0
	# A player emptying a Q menu spawns several a second, and a sandbox server has a
	# dozen people doing it. Three at once is a building site; twelve is a fault.
	spawn.max_concurrent = 3
	spawn.cooldown_ms = 80
	spawn.priority = 40
	spawn.pitch_min = 0.92
	spawn.pitch_max = 1.08
	c.add(spawn)

	var land := DotAudioDef.new()
	land.id = &"prop_land"
	land.path = "%s/prop_land.ogg" % SOUND_DIR
	land.kind = DotAudioDef.Kind.POSITIONAL_3D
	land.bus = &"SFX"
	land.max_distance = 45.0
	land.max_concurrent = 4
	land.cooldown_ms = 50
	land.priority = 30
	c.add(land)

	var grab := DotAudioDef.new()
	grab.id = &"tool_grab"
	grab.path = "%s/tool_grab.ogg" % SOUND_DIR
	grab.bus = &"UI"
	grab.cooldown_ms = 120
	grab.priority = 60
	c.add(grab)

	var punt := DotAudioDef.new()
	punt.id = &"tool_punt"
	punt.path = "%s/tool_punt.ogg" % SOUND_DIR
	punt.bus = &"SFX"
	punt.kind = DotAudioDef.Kind.POSITIONAL_3D
	punt.max_distance = 70.0
	punt.priority = 70
	c.add(punt)

	var buy := DotAudioDef.new()
	buy.id = &"buy"
	buy.path = "%s/buy.ogg" % SOUND_DIR
	buy.bus = &"UI"
	buy.priority = 80
	c.add(buy)

	var refused := DotAudioDef.new()
	refused.id = &"refused"
	refused.path = "%s/refused.ogg" % SOUND_DIR
	refused.bus = &"UI"
	refused.cooldown_ms = 200
	# Above a prop landing, because a refusal is the answer to something the player just
	# did and a crate hitting the floor is not.
	refused.priority = 85
	c.add(refused)

	var wave := DotAudioDef.new()
	wave.id = &"wave_incoming"
	wave.path = "%s/wave.ogg" % SOUND_DIR
	wave.bus = &"UI"
	wave.priority = 100
	c.add(wave)

	return c


func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = settings.get_float(&"master_volume", 0.8)
	audio.voices = 24
	# Deterministic: the pitch of a crate landing comes out of the session's own seed, so
	# two people watching the same sandbox hear the same thing. It costs nothing and it is
	# what makes an audio bug reproducible.
	audio.roll_source = rng.stream(&"audio")
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("the playground's audio")
	return DotResult.success(null)


# --- Effects ----------------------------------------------------------------

static func fx_catalogue() -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var puff := DotFxDef.new()
	puff.id = &"prop_spawn"
	puff.scene_path = "%s/spawn_puff.tscn" % FX_DIR
	puff.lifetime_ms = 450
	puff.cost = 2
	puff.priority = 40
	puff.max_distance = 60.0
	puff.max_concurrent = 8
	puff.min_quality = 1
	c.add(puff)

	var beam := DotFxDef.new()
	beam.id = &"tool_beam"
	beam.kind = DotFxDef.Kind.BEAM
	beam.scene_path = "%s/tool_beam.tscn" % FX_DIR
	beam.lifetime_ms = 100
	beam.cost = 1
	beam.priority = 75
	beam.max_distance = 0.0
	c.add(beam)

	var punt := DotFxDef.new()
	punt.id = &"punt_shake"
	punt.kind = DotFxDef.Kind.SHAKE
	punt.shake_trauma = 0.22
	c.add(punt)

	var wave := DotFxDef.new()
	wave.id = &"wave_flash"
	wave.kind = DotFxDef.Kind.SCREEN
	wave.flash_peak = 0.2
	wave.flash_colour = Color(0.95, 0.55, 0.2)
	wave.flash_decay_ms = 450
	c.add(wave)

	return c


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.quality = settings.get_int(&"fx_quality", 3)
	fx.config.shake_scale = settings.get_float(&"shake_scale", 1.0)
	fx.config.allow_flashes = settings.get_bool(&"allow_flashes", true)
	# No decals: nothing in a sandbox marks a wall, and a decal ring on a map where the
	# geometry is generated is a hole in a wall that will not exist next map.
	fx.config.max_decals = 0
	add_child(fx)

	var res := fx.setup()
	if not res.ok:
		return res.wrap("the playground's effects")
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

# --- Chat -------------------------------------------------------------------

## The box a player types in, and the three settings that decide it.
##
## [b]The channels come from [code]PlaygroundServices.chat_channels[/code], not from a
## list here.[/b] Two copies of one list is this tree's most repeated bug; the server
## routes with those definitions and the composer offers exactly what it routes. The
## admin channel is filtered out because it is admin-only and a channel a player cannot
## send on is a channel that should not be in the cycle.
func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 100
	add_child(_chat_layer)

	var offered: Array[Dictionary] = []

	for channel in PlaygroundServices.chat_channels():
		if channel.admin_only or channel.server_only:
			continue

		offered.append({
			"id": channel.id,
			"label": "Say" if channel.display_name == "" else "Say (%s)" % channel.display_name,
			"colour": channel.colour,
			# The proximity channel is what the second key opens here. A sandbox has no
			# teams; what it has is the difference between telling the server and telling
			# whoever is standing beside your build.
			"team": channel.scope == DotChatChannel.Scope.RADIUS,
		})

	chat_window = DotChatWindow.new()
	chat_window.name = "ChatWindow"
	chat_window.open_action = &"playground_chat"
	chat_window.team_action = &"playground_chat_near"
	chat_window.channels = offered
	_chat_layer.add_child(chat_window)


## Puts one binding from the settings document onto its action.
##
## Empty is left alone rather than applied: a settings file somebody cleared the field in
## would otherwise unbind chat with no way to get it back from inside the game.
func _bind_chat(action: StringName, text: String) -> void:
	if action == &"" or text.strip_edges() == "":
		return

	var bound := DotInputBinding.apply(action, text)

	if bound == "":
		DotLog.warn(CHANNEL, "a chat key was not understood", {
			"action": String(action), "binding": text
		})


## The server said whether anything else is carrying this conversation.
func set_chat_relayed(relayed: bool) -> void:
	if _chat_relayed == relayed:
		return

	_chat_relayed = relayed
	_apply_chat_visibility()


## Resolves the three-way setting against what the server said.
##
## `on` is both halves at once — a relayed server AND a box in front of the game. `off` is
## a player who chats somewhere else. `auto` draws it unless this server is already putting
## these lines somewhere this player can see them. In every case the log keeps drawing what
## other people said.
func _apply_chat_visibility() -> void:
	if chat_window == null or settings == null:
		return

	match StringName(str(settings.get_value(&"chat_window"))):
		&"on":
			chat_window.enabled = true
		&"off":
			chat_window.enabled = false
		_:
			chat_window.enabled = not _chat_relayed


func _build_console() -> DotResult:
	console = DotConsoleController.new()
	console.name = "Console"
	console.config = DotConsoleConfig.new()
	console.config.mirror_log = true
	console.config.mirror_from = DotLog.Level.INFO
	add_child(console)

	var res := console.setup()
	if not res.ok:
		return res.wrap("the playground's console")

	var local := DotConsoleLocal.new()
	local.add_command(&"help", "List what this client can do", func(_a: PackedStringArray) -> Variant:
		var lines := PackedStringArray(["Client commands:"])
		for n in console.all_names():
			lines.append("  %-22s %s" % [n, console.help_for(n)])
		return lines
	)
	local.add_command(&"quit", "Leave", func(_a: PackedStringArray) -> Variant:
		get_tree().quit()
		return null
	)
	local.add_command(&"settings", "Show every setting", func(_a: PackedStringArray) -> Variant:
		return settings.describe_lines()
	)
	local.add_command(&"seed", "Show this session's seed", func(_a: PackedStringArray) -> Variant:
		# The one command this game needs more than the others: a generated map nobody can
		# name the seed of is a map nobody can share, and "play the map I played" is the
		# most-requested feature every generated world gets.
		return rng.describe_lines()
	)
	local.add_command(&"clear", "Empty the scrollback", func(_a: PackedStringArray) -> Variant:
		console.buffer.clear()
		return null
	)
	for key in settings.schema.keys():
		var def := settings.schema.find(key)
		local.bind_setting(key, settings, def.description if def != null else "")
	console.add_source(local)

	var server: Object = DotRegistry.get_service(&"dot_server")
	if server != null and server.get("console") != null:
		console.add_source(DotConsoleBridge.wrap(server.get("console"), "server"))

	_layer = CanvasLayer.new()
	_layer.name = "ConsoleLayer"
	_layer.layer = 128
	add_child(_layer)

	console_panel = DotConsolePanel.new()
	console_panel.name = "ConsolePanel"
	console_panel.controller = console
	_layer.add_child(console_panel)
	return DotResult.success(null)


# --- What the game asks for -------------------------------------------------

func present(delta: float, eye: Vector3, forward: Vector3) -> void:
	audio.listener_position = eye
	fx.viewer_position = eye
	fx.viewer_forward = forward
	fx.advance(delta)


func camera_shake() -> Vector3:
	return fx.shake.offset()


## Whether something on screen owns the keyboard right now.
##
## [b]The chat box belongs here for the reason the console does.[/b] A client that keeps
## reading movement while somebody types walks them across the map, and in a sandbox it
## also fires whatever tool they are holding at whatever they were building.
func swallows_input() -> bool:
	if console_panel != null and console_panel.has_keyboard_focus():
		return true

	return chat_window != null and chat_window.is_open()


func on_prop_spawned(at: Vector3, mine: bool) -> void:
	if not mine and not settings.get_bool(&"prop_sounds", true):
		# The one sandbox-specific setting, and it is about somebody else's building.
		# A busy server is a permanent noise otherwise.
		return
	var t := Transform3D.IDENTITY
	t.origin = at
	audio.play_at(&"prop_spawn", at)
	fx.spawn(&"prop_spawn", t)


func on_prop_landed(at: Vector3) -> void:
	if not settings.get_bool(&"prop_sounds", true):
		return
	audio.play_at(&"prop_land", at)


func on_tool_grab() -> void:
	audio.play(&"tool_grab")


func on_tool_punt(at: Vector3, mine: bool) -> void:
	audio.play_at(&"tool_punt", at)
	if mine:
		fx.spawn(&"punt_shake", Transform3D.IDENTITY)


func on_bought() -> void:
	audio.play(&"buy")


func on_refused() -> void:
	audio.play(&"refused")


func on_wave_incoming() -> void:
	audio.play(&"wave_incoming")
	fx.flash(&"wave_flash")


func on_map_changed() -> void:
	fx.clear()


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("the playground's presentation layer")
	out.append_array(rng.describe_lines())
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	out.append_array(fx.describe_lines())

	if chat_window != null:
		out.append("chat box: %s" % str(chat_window.describe()))
	return out
