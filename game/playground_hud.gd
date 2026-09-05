class_name PlaygroundHud
extends Control

## The playground's HUD: the timer, the speedometer, the strafe statistics, and a
## line saying what just happened.
##
## [b]Composed from dot-timer's HUD rather than replacing it.[/b] `DotTimerHud` draws
## the clock, the split and the speed and ships no art, which is exactly the division
## the family wants; this adds the things that are the game's — a notice line, a prop
## count, the current map — and lays the whole out. A game that wanted a different
## clock would subclass `DotTimerHud`; this one does not.

## How long a notice stays up, in seconds.
const NOTICE_SECONDS := 4.0

var timer_hud: DotTimerHud = null

var _notice: Label = null
var _status: Label = null
var _tools: Label = null
var _crosshair: DotCrosshair = null
var _notice_until: float = 0.0

var playground: Playground = null
var player_id: StringName = &"local"

## What the client says is in the player's hands, and what the menu last armed.
##
## Pushed in by [method set_tool] rather than read off the client, because the HUD is
## bound to the SIMULATION — it is built the same way for a spectator and for a
## replay, neither of which has a client holding anything.
##
## A NAME rather than an id: what is in hand may be one of the two built-in guns or
## any weapon the server offers, and the client is the only thing that can say which
## and what it is called.
var tool_name: String = ""
var armed_prop: StringName = &""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Offsets as well as the preset. `set_anchors_preset` does NOT set them, so a
	# Control built in code keeps the zero size it was created with — the whole
	# interface then lays out inside nothing and is invisible while being, by every
	# property, correctly configured. This cost the family a day in dot-ui.
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

	mouse_filter = Control.MOUSE_FILTER_IGNORE

	timer_hud = DotTimerHud.new()
	timer_hud.name = "Timer"
	timer_hud.position = Vector2(24.0, 24.0)
	timer_hud.size = Vector2(360.0, 200.0)
	timer_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(timer_hud)

	_notice = Label.new()
	_notice.name = "Notice"
	_notice.position = Vector2(24.0, 240.0)
	_notice.size = Vector2(700.0, 32.0)
	add_child(_notice)

	_status = Label.new()
	_status.name = "Status"
	_status.position = Vector2(24.0, 276.0)
	_status.size = Vector2(700.0, 32.0)
	add_child(_status)

	_tools = Label.new()
	_tools.name = "Tools"
	_tools.position = Vector2(24.0, 312.0)
	_tools.size = Vector2(700.0, 32.0)
	add_child(_tools)

	# A crosshair, because every tool here is aimed. A physics gun with nothing to
	# aim by is one that picks up whatever happens to be near the middle of the
	# screen, and "why did it grab that one" is the commonest complaint in a sandbox.
	_crosshair = DotCrosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Offsets as well as the preset. See the note in the block above: without them
	# the crosshair draws inside a zero-sized rect in the top-left corner.
	_crosshair.offset_left = 0.0
	_crosshair.offset_top = 0.0
	_crosshair.offset_right = 0.0
	_crosshair.offset_bottom = 0.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_crosshair)

	set_process(true)


## Wires the HUD to a playground and a player.
func bind(p_playground: Playground, p_player: StringName) -> void:
	playground = p_playground
	player_id = p_player

	playground.run_filed.connect(_on_run_filed)
	playground.map_ready.connect(_on_map_ready)

	playground.timers.player_staged.connect(
		func(id: StringName, number: int, split: float) -> void:
			if id == player_id:
				notice("Stage %d — %s" % [
					number, DotTimerRun.format_time(split)
				])
	)
	playground.props.refused.connect(
		func(id: StringName, _prop: StringName, reason: String) -> void:
			if id == player_id:
				notice(reason)
	)


## Told by the client what is in the player's hands.
func set_tool(p_tool: String, p_prop: StringName) -> void:
	tool_name = p_tool
	armed_prop = p_prop


func notice(text: String) -> void:
	if _notice == null:
		return

	_notice.text = text
	# Simulated time is not available here and does not need to be: a notice is
	# presentation, and nothing about it is recorded, compared or ranked.
	_notice_until = Time.get_ticks_msec() / 1000.0 + NOTICE_SECONDS


func _process(_delta: float) -> void:
	if playground == null:
		return

	if _notice != null and Time.get_ticks_msec() / 1000.0 > _notice_until:
		_notice.text = ""

	var player: PlaygroundPlayer = playground.players.get(player_id)

	if player == null:
		return

	timer_hud.style_name = (
		player.timer_style.display_name if player.timer_style != null else ""
	)
	timer_hud.show_run(
		player.timer.run if player.timer != null else null,
		player.speed(),
		player.controller.stats.to_dictionary()
	)

	if _status != null:
		var map := playground.maps.current
		var checkpoints := playground.timers.checkpoints_for(player_id)

		var parts := PackedStringArray([
			map.name_or_id() if map != null else "-",
			playground.maps.time_limit.formatted_remaining(),
			"%d props" % playground.props.world_count(),
			player.movement_style.display_name if player.movement_style else "-",
		])

		if checkpoints != null and not checkpoints.is_empty():
			parts.append("cp %d/%d" % [
				checkpoints.index + 1, checkpoints.count()
			])

		# Said on the HUD, not only in a log: a run that used a checkpoint cannot be
		# recorded, and finding that out at the finish line after four minutes is the
		# worst possible moment to be told.
		if player.timer != null and player.timer.run.used_checkpoints:
			parts.append("PRACTICE")

		# The track, always, and not only when it is a bonus. On a map that is a
		# sandbox on one track and a course on another, "which one am I on" is the
		# difference between a timer that is broken and a timer that is not running
		# because you asked it not to.
		if player.timer != null:
			parts.append(DotTimerTrack.name_of(player.timer.track))

		_status.text = "   ·   ".join(parts)

	if _tools != null:
		_tools.text = "   ·   ".join(PackedStringArray([
			tool_name.capitalize() if tool_name != "" else "Nothing",
			"%s armed" % _armed_name(),
			"%d/%d props" % [
				playground.props.player_cost(player_id),
				playground.props.limits.per_player_budget,
			],
			"hold Q to spawn",
		]))


func _armed_name() -> String:
	if armed_prop == &"" or playground.props.catalogue == null:
		return "nothing"

	var def := playground.props.catalogue.get_prop(armed_prop)

	return def.name_or_id() if def != null else String(armed_prop)


func _on_run_filed(
	id: StringName, run: DotTimerRun, rank: int, reason: String
) -> void:
	if id != player_id:
		return

	if reason != "":
		notice("%s — not recorded: %s" % [run.formatted_time(), reason])
		return

	notice("%s — rank %d" % [run.formatted_time(), rank])


func _on_map_ready(map: DotMapDef) -> void:
	notice("Now playing %s" % map.name_or_id())

	# The comparison the clock shows. Read once per map rather than per frame,
	# because it only changes when the map, the track or the style does.
	_refresh_comparison()


func _refresh_comparison() -> void:
	var player: PlaygroundPlayer = playground.players.get(player_id)

	if player == null or playground.timers.store == null:
		return

	var map := playground.maps.current

	if map == null:
		return

	var mine := playground.timers.store.best_for(
		map.id, player.timer.track, player.timer.style.id if player.timer.style else &"normal",
		player_id
	)
	var top := playground.timers.store.top(
		map.id, player.timer.track,
		player.timer.style.id if player.timer.style else &"normal", 1
	)

	var personal := 0.0
	var record := 0.0

	if mine.ok and mine.value is DotTimerRecord:
		personal = (mine.value as DotTimerRecord).time

	if top.ok and (top.value as Array).size() > 0:
		record = ((top.value as Array)[0] as DotTimerRecord).time

	timer_hud.set_comparisons(personal, record)
