class_name PlaygroundInventory
extends Node

## What a player is carrying, over dot-inventory.
##
## [b]This is not the spawn menu and it deliberately does not replace it.[/b] The Q menu
## is a catalogue — everything this server can make, whether or not you have one — and
## `pg_shop` already charges credits for spawning from it. What was missing is the thing
## between those two: **what you have paid for and not yet used.**
##
## So the division is:
##
## | | |
## | --- | --- |
## | `PlaygroundSpawnMenu` | what exists. A catalogue, filtered by what you can afford. |
## | `PlaygroundShop` | what it costs. A price list and a purse. |
## | this | what you are carrying. A grid, with weight, that a server validates. |
##
## Buying puts a thing in here; spawning takes it out. A player who buys three crates and
## places one has two left, which the shop alone could not express — it charged per spawn,
## so nothing was ever *held*.
##
## [b]Every mutation is an op[/b], which is what makes it safe to let a client do the
## drag-and-drop: the client applies locally, sends the op, and rolls back if the server
## says no. A server that received state instead would have to diff two documents to work
## out what a player claims to have done, and a diff cannot tell "this crate moved" from
## "this crate was destroyed and an identical one appeared".

const SERVICE := &"playground_inventory"
const CHANNEL := "playground.inventory"

## The one container a player has. A grid rather than a list of slots, because the
## interesting thing about carrying a plank and a crate is that they are different shapes.
const BACKPACK := &"pg_backpack"

## Ten by six cells. Enough for a dozen things, small enough that a player has to choose.
const BACKPACK_W := 10
const BACKPACK_H := 6

## Kilograms. A sandbox's props are heavy on purpose: carrying a barrel should cost
## something, or the grid is the only limit and a grid alone rewards tidiness.
const BACKPACK_WEIGHT := 400.0

## Somebody's carried items changed.
signal changed(player_id: StringName)

## player id -> [DotInvManager].
var _managers: Dictionary = {}

## The catalogue, built once from the spawnables list.
var catalogue: DotInvCatalogue = null

@export var authoritative: bool = true


func setup(spawnables: DotPropCatalogue) -> DotResult:
	catalogue = build_catalogue(spawnables)
	var res := catalogue.validate()
	if not res.ok:
		return res.wrap("the playground's item catalogue")
	DotRegistry.register(SERVICE, self)
	return DotResult.success(null)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


## An item catalogue derived from the prop catalogue, rather than written beside it.
##
## [b]One list.[/b] A second table of what can be carried would go stale the first time
## somebody adds a prop — which is this tree's most repeated bug, and it has happened to
## `setup.sh`, two guard scripts, both bootstrap scripts and a vendoring list. The size, the
## weight and the tags all come from the prop's own definition.
static func build_catalogue(spawnables: DotPropCatalogue) -> DotInvCatalogue:
	var c := DotInvCatalogue.new()
	c.add_grid(BACKPACK, BACKPACK_W, BACKPACK_H, BACKPACK_WEIGHT)

	if spawnables == null:
		return c

	for def in spawnables.props:
		var item := DotInvItem.new()
		item.id = def.id
		# A translation key, not a name. An item document is stored and sent, and a stored
		# display name is also a stored typo -- fixing one means rewriting every save that
		# has it.
		item.name_key = StringName("item.%s" % def.id)
		# Unique rather than stackable: every prop in this game carries its own state the
		# moment it is spawned -- where it is, whether it is frozen, who owns it -- and an
		# item that stacks is one whose state cannot be told apart from its neighbour's.
		item.kind = DotInvItem.Kind.UNIQUE
		item.stack_max = 1
		# The prop's own mass, which dot-props already carries and which this family found
		# was being read by exactly one thing -- a catalogue saying 900 kg over a scene
		# saved at 20 kg gave a prop a physics gun refused for being too heavy. Carrying
		# weight is the second reader it has ever had.
		item.weight = maxf(def.mass, 1.0)
		item.size = _size_for(def)
		# The kind, as a tag a query can filter on. Taken from the same function the
		# spawner reads, so a prop that becomes a vehicle becomes one here too.
		item.tags = [_kind_tag(def)]
		c.add(item)

	return c


## The tag a query filters on, from the kind the spawner already derives.
static func _kind_tag(def: DotPropDef) -> StringName:
	match PlaygroundSpawnables.kind_of(def):
		PlaygroundSpawnables.Kind.ENTITY:
			return &"entity"
		PlaygroundSpawnables.Kind.VEHICLE:
			return &"vehicle"
		_:
			return &"prop"


## How many cells a prop takes, from the size band its own definition declares.
##
## Derived rather than authored, for the same reason the rest of it is: a prop that is
## re-declared LARGE takes more room in a bag without anybody remembering to say so. A
## vehicle is three by three whatever its band says -- a car in a backpack is a joke the
## grid should not have to make twice.
static func _size_for(def: DotPropDef) -> Vector2i:
	if PlaygroundSpawnables.kind_of(def) == PlaygroundSpawnables.Kind.VEHICLE:
		return Vector2i(3, 3)
	match def.size:
		DotPropDef.Size.LARGE:
			return Vector2i(3, 2)
		DotPropDef.Size.SMALL:
			return Vector2i(1, 1)
		_:
			return Vector2i(2, 2)


## The manager for one player, made on demand.
func for_player(player_id: StringName) -> DotInvManager:
	if _managers.has(player_id):
		return _managers[player_id]

	var m := DotInvManager.new()
	m.name = "Inv_%s" % player_id
	m.catalogue = catalogue
	m.authoritative = authoritative
	m.register_as_service = false
	# Thirty a second per player. An inventory is the cheapest denial of service a client
	# has -- a move is a validation, a weight sum and a redraw -- and the bucket is per
	# actor, so one player flooding does not throttle everybody else's bag.
	m.ops_per_second = 30
	add_child(m)

	var res := m.setup([BACKPACK])
	if not res.ok:
		DotLog.warn(CHANNEL, "an inventory could not be made", {
			"player": String(player_id), "why": res.error.message
		})

	m.applied.connect(func(_op: DotInvOp, _r: DotResult) -> void: changed.emit(player_id))
	_managers[player_id] = m
	return m


func forget(player_id: StringName) -> void:
	var m: DotInvManager = _managers.get(player_id)
	if m != null:
		m.queue_free()
	_managers.erase(player_id)


## Puts a bought item in somebody's bag. Returns what it could not fit.
func give(player_id: StringName, item_id: StringName, count: int = 1) -> DotResult:
	var m := for_player(player_id)
	return m.apply(DotInvOp.add(item_id, count, BACKPACK), player_id)


## Takes one out, for spawning it. Refuses when they do not have one.
##
## [b]The refusal is the whole feature.[/b] Before this, `pg_shop` charged on every spawn
## and nothing was ever held — so "buy three crates" and "buy one crate three times" were
## the same thing, and a player could not carry anything anywhere.
func take(player_id: StringName, item_id: StringName) -> DotResult:
	var m := for_player(player_id)
	var container := m.doc.get_container(BACKPACK)
	if container == null:
		return DotResult.fail(DotError.CODE_STATE, "no backpack")

	for uid in container.entries.keys():
		if str((container.entries[uid] as Dictionary).get("item", "")) == String(item_id):
			return m.apply(DotInvOp.drop(BACKPACK, uid, 1), player_id)

	return DotResult.fail(
		DotError.CODE_STATE, "you are not carrying a %s" % item_id
	)


func carries(player_id: StringName, item_id: StringName) -> int:
	var m := for_player(player_id)
	return m.doc.count_of(item_id)


## What somebody is carrying, filtered and sorted the way they asked.
##
## [b]Locally, always.[/b] dot-browser's rule and dot-inventory's: the server owns what is
## in the bag and the client owns how it is shown. A filter sent to a server makes it
## responsible for a preference and costs a round trip per keystroke.
func query(player_id: StringName, text: String = "", tag: StringName = &"") -> Array[Dictionary]:
	var m := for_player(player_id)
	var q := DotInvQuery.new()
	q.text = text
	if tag != &"":
		q.tags = [tag]
	q.sort_by = DotInvQuery.Sort.WEIGHT
	return q.run(m.doc, catalogue)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("inventories: %d" % _managers.size())
	for id in _managers.keys():
		var m: DotInvManager = _managers[id]
		out.append("  %s" % id)
		for line in m.doc.describe_lines(catalogue):
			out.append("    %s" % line)
	return out
