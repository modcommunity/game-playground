class_name PlaygroundDowns
extends Node

## Down rather than dead, and the five seconds somebody spends picking you up.
##
## [b]The wave mode is the only co-operative thing in this family, and this is what makes
## it one.[/b] Until now a player killed by a wave respawned on a timer, which means the
## other players carried on shooting and nothing about the wave was harder for having
## dropped somebody. The co-operative survival shooters' answer is the one every
## co-operative shooter since has copied: at zero health you go **down** rather than
## dying, you bleed out over ninety
## seconds, and picking you up costs somebody five seconds of not shooting.
##
## [b]Only while the waves are on.[/b] A sandbox where nobody dies is a very confusing
## bug, and the arena is a deathmatch where being revived by the person who shot you
## would be nonsense. `pg_waves` is what turns it on, which is the same cvar that put
## something in the map to be killed by.

const CHANNEL := "playground.downs"

## Somebody went down. The module tells the clients.
signal went_down(player_id: StringName, incaps: int)

## Somebody is being picked up.
signal reviving(player_id: StringName, by: StringName, fraction: float)

## …and is back up.
signal revived(player_id: StringName, by: StringName, health: float)

## …or did not make it.
signal died(player_id: StringName, reason: StringName)

var game: Playground = null

## The arena, when the module has built one. See [PlaygroundSpectate.arena].
var arena: PlaygroundArena = null

var effects: DotEffectManager = null

## Whether being downed happens at all.
var enabled: bool = false

var _reviving: Dictionary = {}


func setup(p_game: Playground) -> DotResult:
	game = p_game

	effects = DotEffectManager.new()
	effects.name = "Effects"
	effects.authoritative = game.authoritative
	effects.rules = _rules()
	effects.position_fn = _position_of
	# No sides in a sandbox, so anybody may pick anybody up — which is what a
	# co-operative mode means and is worth saying rather than leaving to a default.
	effects.allies_fn = func(_a: int, _b: int) -> bool: return true
	add_child(effects)

	var res := effects.setup(table(game.tick_rate))
	if not res.ok:
		return res.wrap("playground downs")

	effects.downed.connect(func(entity: int, incaps: int) -> void:
		went_down.emit(_player_of(entity), incaps))
	effects.revived.connect(func(entity: int, by: int, health: float) -> void:
		revived.emit(_player_of(entity), _player_of(by), health))
	effects.died.connect(func(entity: int, reason: StringName) -> void:
		died.emit(_player_of(entity), reason))
	effects.damaged.connect(_on_damaged)

	return DotResult.success(null)


func _rules() -> DotEffectRules:
	var rules := DotEffectRules.new()
	rules.downed_enabled = true
	rules.downed_health = 300.0
	# 300 over about ninety seconds at this game's rate, which is the genre's number
	# rather than a round one: it is long enough that a rescue is worth attempting and
	# short enough that it is a decision.
	rules.downed_bleed_per_tick = 300.0 / (90.0 * float(game.tick_rate))
	rules.downed_revive_ticks = 5 * game.tick_rate
	rules.downed_revive_health = 30.0
	rules.downed_revive_radius = 2.0
	rules.downed_revive_scales = false
	rules.downed_max_incaps = 2
	rules.downed_defib_health = 0.0
	return rules


## The effects a downed player carries. One, and it does the whole job.
static func table(rate: int) -> Array[DotEffectDef]:
	var down := DotEffectDef.make(&"pg_downed", 0)
	down.display_name = "Incapacitated"
	down.label = "DOWN"
	down.tags = PackedStringArray(["debuff"])
	down.no_attack = true
	down.no_move = true
	down.no_capture = true
	down.clear_on_death = true
	var _unused := rate
	return [down]


func set_enabled(on: bool) -> void:
	if enabled == on:
		return
	enabled = on
	if not on:
		# Everybody back on their feet. Leaving somebody down while the mode that can
		# revive them is switched off is leaving them down for ever.
		for id: Variant in game.players.keys():
			effects.stand_up(_entity_of(StringName(id)), true)
		_reviving.clear()
	DotLog.info(CHANNEL, "downs are %s" % ("on" if on else "off"))


func is_down(player_id: StringName) -> bool:
	return enabled and effects != null and effects.is_down(_entity_of(player_id))


func state_of(player_id: StringName) -> DotDowned:
	return effects.downed_state(_entity_of(player_id)) if effects != null else null


## Somebody reached zero health. Answers "down" or "dead".
##
## [b]One place decides, and that is the point of routing through here.[/b] A game that
## asks "are we in a mode with incapacitation" at every damage site has as many copies of
## the rule as it has damage sites, and the copies drift.
func report_zero_health(player_id: StringName) -> StringName:
	if not enabled or effects == null:
		return &"dead"
	var res := effects.report_zero_health(_entity_of(player_id), game.current_tick())
	return StringName(str(res.value_or("dead")))


## Start picking somebody up. What holding the use key on a downed player does.
func begin_revive(player_id: StringName, by: StringName) -> DotResult:
	if not enabled or effects == null:
		return DotResult.fail(DotError.CODE_STATE, "Nobody goes down here.")

	# **Both have to be real players.** dot-effects tests the distance between two
	# positions, and `_position_of` answers with a sentinel far away for somebody it
	# does not know — so two unknown ids are at the SAME sentinel, zero apart, and
	# every distance check between them passes. A rescuer who does not exist then
	# revives a casualty who does not exist, and the only symptom is that a player who
	# should have bled out is standing up.
	if not game.players.has(player_id):
		return DotResult.fail(
			DotError.CODE_INVALID, "There is no player '%s' here." % player_id
		)
	if not game.players.has(by):
		return DotResult.fail(
			DotError.CODE_INVALID, "There is no player '%s' here." % by
		)

	return effects.begin_revive(_entity_of(player_id), _entity_of(by))


func cancel_revive(player_id: StringName) -> void:
	if effects != null:
		effects.cancel_revive(_entity_of(player_id))


func stand_up(player_id: StringName, reset_incaps: bool = false) -> void:
	if effects != null:
		effects.stand_up(_entity_of(player_id), reset_incaps)


func tick(_delta: float) -> void:
	if effects == null:
		return

	effects.advance(game.current_tick())

	if not enabled:
		return

	# A downed player cannot move, and the enforcement is here rather than in the
	# controller because the controller is predicted on a client and this is not:
	# a client that decided for itself when it was incapacitated is a client that
	# decided it was not.
	for id: Variant in game.players.keys():
		var player_id := StringName(id)
		if not is_down(player_id):
			continue
		var player: PlaygroundPlayer = game.players[player_id]
		if player == null or player.controller == null:
			continue
		player.controller.state.velocity = Vector3.ZERO

		var state := state_of(player_id)
		if state != null and state.state == DotDowned.State.REVIVING:
			reviving.emit(
				player_id, _player_of(state.reviver), state.revive_fraction(effects.rules)
			)


func _position_of(entity: int) -> Vector3:
	var player: PlaygroundPlayer = game.players.get(_player_of(entity), null)
	if player == null or player.controller == null:
		return Vector3(1e9, 1e9, 1e9)
	return player.controller.state.position


func _on_damaged(entity: int, amount: float, _type: StringName, _source: int) -> void:
	if arena == null:
		return
	var health := arena.health_of(_player_of(entity))
	if health == null:
		return
	var _took := health.heal(-amount)


## A stable entity id for a player name.
##
## [b]The arena's id when there is one, and a hash otherwise.[/b] The arena mints entity
## ids for dot-combat and the waves mode can be on without it — so this has to answer in
## both, and answering differently in the two is how a player who is down in one system
## is up in the other.
func _entity_of(player_id: StringName) -> int:
	if player_id == &"":
		return 0
	if arena != null:
		var entity := arena.entity_id_of(player_id)
		if entity != 0:
			return entity
	return abs(String(player_id).hash())


func _player_of(entity: int) -> StringName:
	if entity == 0:
		return &""
	if arena != null:
		var id := arena.player_for_entity(entity)
		if id != &"":
			return id
	for candidate: Variant in game.players.keys():
		if abs(String(candidate).hash()) == entity:
			return StringName(candidate)
	return &""


func on_player_removed(player_id: StringName) -> void:
	if effects != null:
		effects.forget(_entity_of(player_id))


func describe() -> Dictionary:
	return {"enabled": enabled, "effects": effects.describe() if effects != null else {}}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("downs        %s" % ("on" if enabled else "off"))
	if effects != null and enabled:
		out.append_array(effects.describe_lines())
	return out
