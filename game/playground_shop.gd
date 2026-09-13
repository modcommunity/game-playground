extends Node

const Playground := preload("playground.gd")

## A sandbox with a price list.
##
## [b]Off by default, and that is the whole argument for it being a cvar.[/b] A sandbox
## where everything is free is a sandbox; a sandbox where a jeep costs four hundred
## credits is a *game*, and turning one into the other because an addon was installed is
## exactly what this family's own rule about cvars exists to prevent. `pg_shop 1` is a
## decision an operator makes.
##
## [b]What it is for.[/b] A free spawn menu has no pacing: the first thing anybody does
## is fill the map with the most expensive thing in it. A price list makes the wave mode
## worth playing — a wave pays, a jeep costs, and a player who spent everything on
## turrets has to earn the next one — and it does it without a single new mechanic,
## because everything it needs is already here: a prop catalogue with fourteen entries,
## three weapons, four vehicles, and a wave director that knows when something died.
##
## [b]It sells ids and grants nothing.[/b] `DotEconomyManager.bought` carries an id and
## this layer answers "yes, spawn it" — the spawn itself stays where it already was, in
## `Playground` and `DotPropSpawner`. dot-economy has never heard of a `DotPropDef` and
## does not need to.

const CHANNEL := "playground.shop"

## What everybody starts with, and what the wave mode pays.
##
## Deliberately not the round-based shooters' 800/16000. A sandbox's numbers are about
## how long
## you wait for the next crate, not about a pistol round, and the ceiling is high because
## saving up for the expensive thing IS the mode.
const START_CREDITS := 1200
const MAX_CREDITS := 25000

## Paid for killing something the director sent.
const WAVE_KILL := 60

## Paid for an arena kill.
const ARENA_KILL := 100

## Paid every minute, so a player who is building rather than fighting still earns.
const STIPEND := 40

## A player bought something and it should now be spawned.
signal purchased(player_id: StringName, id: StringName)

var game: Playground = null

var economy: DotEconomyManager = null

## Whether prices apply at all. `pg_shop`.
var enabled: bool = false

var _stipend_ticks: int = 0


func setup(p_game: Playground) -> DotResult:
	game = p_game

	economy = DotEconomyManager.new()
	economy.name = "Economy"
	economy.authoritative = game.authoritative
	economy.rules = _rules()
	# A sandbox has no sides, no buy zones and nobody dead for long. Every one of these
	# would refuse a purchase for a reason that does not exist here, and dot-economy
	# asks rather than assuming precisely so a game can say so.
	economy.team_fn = func(_key: String) -> int: return 1
	economy.alive_fn = func(_key: String) -> bool: return true
	economy.in_buy_zone_fn = func(_key: String) -> bool: return true
	add_child(economy)

	var res := economy.setup(catalogue(game))
	if not res.ok:
		return res.wrap("playground shop")

	# One round, for ever. A sandbox has no rounds and the buy window would otherwise
	# never open — `on_round_start` is what opens it, and a shop that is shut is a shop
	# whose every refusal correctly says the window is closed.
	economy.on_round_start(game.current_tick())

	return DotResult.success(null)


func _rules() -> DotEconomyRules:
	var rules := DotEconomyRules.new()
	rules.start_money = START_CREDITS
	rules.max_money = MAX_CREDITS
	rules.buy_time_ticks = 0        # Always open. A sandbox has no buy phase.
	rules.require_buy_zone = false
	rules.allow_buying_while_dead = true
	rules.refund_ticks = 10 * game.tick_rate
	rules.refund_within_buy_time = false
	rules.kill_award = ARENA_KILL
	rules.teamkill_penalty = 0      # No teams, so nothing is a team kill.
	rules.win_award = 0
	rules.loss_bonus_base = 0
	rules.loss_bonus_step = 0
	rules.loss_bonus_max = 0
	return rules


## The price list, built from what the game already ships.
##
## [b]Derived rather than authored, and it is the same argument as everywhere else in
## this family:[/b] a hand-written list of fourteen props and three weapons is a list
## that goes stale the first time somebody adds a fifteenth, and this tree has shipped
## that bug four times in shell scripts alone. A price comes from what a thing *is* —
## its mass and its size for a prop, a flat rate for a weapon, more for a vehicle.
static func catalogue(game: Playground) -> Array[DotShopItem]:
	var out: Array[DotShopItem] = []

	if game == null:
		return out

	var props: DotPropCatalogue = game.props.catalogue if game.props != null else null

	if props != null:
		for def in props.props:
			var item := DotShopItem.make(def.id, price_of(def), def.display_name)
			item.tags = PackedStringArray(["prop"])
			out.append(item)

	for weapon in game.weapons:
		var item := DotShopItem.make(weapon.id, 350, weapon.display_name)
		item.tags = PackedStringArray(["weapon"])
		# One each. A second physics gun is not a second physics gun, and paying for
		# one is the sort of refund request an operator does not want.
		item.per_life_limit = 1
		out.append(item)

	return out


## What a prop costs: heavier and bigger is dearer, and its own budget cost counts.
##
## The curve is deliberately shallow. A price list whose top entry is forty times its
## bottom one is a list where thirteen of the fourteen entries are noise.
##
## `DotPropDef.cost` is the prop's weight against a player's *budget*, which is a
## separate limit from money and stays one: a shop that replaced the budget would let
## somebody with credits fill the map, and the budget exists because a filled map is a
## server nobody else can play on.
static func price_of(def: DotPropDef) -> int:
	var mass := maxf(def.mass, 1.0)
	var bulk := float(int(def.size) + 1)
	var weight := float(maxi(def.cost, 1))
	return int(clampf(40.0 + mass * 0.35 + bulk * 60.0 + weight * 25.0, 40.0, 900.0))


func set_enabled(on: bool) -> void:
	if enabled == on:
		return
	enabled = on
	DotLog.info(CHANNEL, "the shop is %s" % ("on" if on else "off"))


func balance(player_id: StringName) -> int:
	return economy.balance(String(player_id)) if economy != null else 0


## Whether somebody can have a thing, and why not when they cannot.
##
## [b]Answers yes for everything while the shop is off[/b], which is what makes this a
## layer a caller can consult unconditionally rather than a branch every call site has
## to remember. The spawn menu asks this to grey a card out; `Playground` asks it before
## spawning; neither of them knows whether the shop is on.
func may_have(player_id: StringName, id: StringName) -> DotResult:
	if not enabled or economy == null:
		return DotResult.success(null)
	return economy.may_buy(String(player_id), id)


## Take the money. Call it when the thing is actually going to appear.
##
## Ordered that way deliberately: charging first and spawning second means a spawn
## refused by the prop budget has already been paid for, and "it took my credits and
## nothing appeared" is the one bug report a shop must not produce.
func charge(player_id: StringName, id: StringName) -> DotResult:
	if not enabled or economy == null:
		return DotResult.success(null)

	var res := economy.buy(String(player_id), id)

	if res.ok:
		purchased.emit(player_id, id)

	return res


## Give it back. What an undo is worth.
func refund(player_id: StringName, id: StringName) -> DotResult:
	if not enabled or economy == null:
		return DotResult.success(null)
	return economy.refund(String(player_id), id)


func award(player_id: StringName, amount: int, reason: StringName) -> int:
	if economy == null:
		return 0
	return economy.award(String(player_id), amount, reason)


func on_player_added(player_id: StringName) -> void:
	if economy == null:
		return
	# Opens the account at the starting balance. Reading it is what creates it, which
	# is why this is a call rather than a comment.
	var _opened := economy.balance(String(player_id))


func on_player_removed(player_id: StringName) -> void:
	if economy != null:
		economy.forget(String(player_id))


## Something the director sent has died.
func on_wave_kill(player_id: StringName) -> void:
	if player_id == &"":
		return
	var _paid := award(player_id, WAVE_KILL, &"wave")


func on_arena_kill(killer: StringName, victim: StringName) -> void:
	if economy == null or killer == &"" or killer == victim:
		return
	var _paid := economy.on_kill(String(killer), String(victim), &"")


func tick(_delta: float) -> void:
	if economy == null:
		return

	economy.advance(game.current_tick())

	if not enabled:
		return

	_stipend_ticks += 1

	if _stipend_ticks < 60 * game.tick_rate:
		return

	_stipend_ticks = 0

	# Everybody, including the player who has spent the last minute building a bridge.
	# A shop that only pays for violence is a shop that has decided what the sandbox is
	# for.
	for id: Variant in game.players.keys():
		var _paid := award(StringName(id), STIPEND, &"stipend")


func describe() -> Dictionary:
	return {
		"enabled": enabled,
		"economy": economy.describe() if economy != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("shop         %s" % ("on" if enabled else "off"))
	if economy != null and enabled:
		out.append_array(economy.describe_lines())
	return out
