class_name PlaygroundEvents
extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, because they have to be exact inverses and nothing
## checks that for you — the headless net suite round-trips every one of them. This
## family has already shipped a serialisation whose two ends never met: dot-moderation
## wrote [code]"voice muted"[/code] and read back a warning, and the one thing that
## addon existed for silently did nothing.
##
## [b]A prop is announced, not spawned by a factory.[/b] The server sends a PROP event
## carrying the catalogue id and the net id it registered, and the client builds the
## same prop and mirrors that id — the same shape [PlaygroundEvents.Kind.JOIN] uses for
## players. A spawner factory would have to name a script, and this game's props are
## named by PATH in the catalogue precisely so a dot-cloud pack can deliver them.

enum Kind {
	## Tick rate, who you are, the map, the server tick.
	HELLO,
	## A player joined, or changed: name, net id, style.
	JOIN,
	LEAVE,
	## The map changed. Clients load it from their own build.
	MAP,
	## A prop or an entity now exists: net id, catalogue id, owner.
	PROP,
	## It is gone. Net id and why.
	PROP_GONE,
	## A player's held prop changed — what the physics gun has, for the beam.
	HELD,
	## What a player is carrying, so the client draws the right viewmodel.
	WEAPON,
	## A player's run state changed: started, stopped, paused.
	TIMER,
	## A player finished. Time and rank.
	FINISH,
	## Text for everyone, or for one player: a refusal, a budget, a vote result.
	NOTICE,
	## A player got into or out of a vehicle.
	SEAT,
}

enum Ask {
	## I have loaded and can receive. Tell me everything.
	READY,
	## Spawn this prop from the catalogue, in front of me.
	SPAWN_PROP,
	## Give me this weapon.
	GIVE_WEAPON,
	## Select this tool — physics gun, gravity gun, remover.
	SELECT_TOOL,
	## Remove the last thing I spawned.
	UNDO,
	## Remove everything I spawned.
	CLEAR_MINE,
	## Put me back at the start of the course.
	RESTART,
	## Save a checkpoint (0), teleport to it (1), clear them (2).
	CHECKPOINT,
	## Rock the vote.
	RTV,
	## Put me on this style (index into the server's ordered table).
	STYLE,
	## Get me into whatever I am standing next to, or out of what I am in.
	##
	## [b]One ask for both, because the player pressed one key.[/b] Two asks would put a
	## client in charge of deciding which it is, and a client that guesses wrong asks to
	## get into the car it is already sitting in — which the server then refuses, so the
	## symptom is a use key that stops working once you are in something.
	USE_VEHICLE,
}

## Every decoder returns an `ok` alongside its fields, and every caller checks it.
##
## [b]A reader past its end returns plausible zeros rather than failing.[/b] dot-net
## shipped with exhaustion that was not sticky, so a decoder that skipped this check got
## a believable value for the field AFTER the overrun — and a truncated packet decodes
## as a valid message about nothing. dot-timer's replay format had the same hole:
## a replay truncated inside its header parsed as a valid replay of zero frames.
const NAME_BYTES := 64
const ID_BYTES := 64
const TEXT_BYTES := 256

## Where a prop may be, in metres. Generous: a punted barrel leaves any sane map.
const WORLD_EXTENT := 8192.0
const POS_BITS := 26


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func ask_name(ask: int) -> String:
	var names := Ask.keys()
	return String(names[ask]) if ask >= 0 and ask < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


# --- Hello -----------------------------------------------------------------

## What a client needs before it can build anything, in one message.
##
## [b]The tick rate is in here and it is not decoration.[/b] game-g2gfast shipped
## without reading the one HELLO already carried, so a browser client counted at the 60
## its export declared against a server running 128: correction rate 0.96, and every
## replicated time wrong by 128/60. A client adopts this or it is wrong about
## everything.
static func write_hello(
	player_id: int, tick_rate: int, server_tick: int, map_id: StringName
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_uint(tick_rate, 9)
	w.write_varint(server_tick)
	w.write_string(String(map_id), ID_BYTES)
	return w.to_bytes()


static func read_hello(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var tick_rate := r.read_uint(9)
	var server_tick := r.read_varint()
	var map_id := r.read_string(ID_BYTES)
	return {
		"player_id": player_id,
		"tick_rate": tick_rate,
		"server_tick": server_tick,
		"map_id": StringName(map_id),
		"ok": r.ok(),
	}


# --- Players ---------------------------------------------------------------

static func write_join(
	player_id: int, net_id: int, display_name: String, style_index: int
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_string(display_name, NAME_BYTES)
	w.write_uint(maxi(style_index, 0), 8)
	return w.to_bytes()


static func read_join(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var display_name := r.read_string(NAME_BYTES)
	var style_index := r.read_uint(8)
	return {
		"player_id": player_id,
		"net_id": net_id,
		"name": display_name,
		"style_index": style_index,
		"ok": r.ok(),
	}


static func write_player(player_id: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	return w.to_bytes()


static func read_player(r: DotNetReader) -> int:
	return r.read_varint()


# --- Props and entities ----------------------------------------------------

## A prop the authority has created. [param kind_id] is the catalogue id, which is how
## the client knows what to build; [param net_id] is what the snapshot will move.
static func write_prop(
	net_id: int, kind_id: StringName, owner_id: int, is_entity: bool, at: Vector3
) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(kind_id), ID_BYTES)
	w.write_varint(owner_id)
	w.write_bool(is_entity)
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return w.to_bytes()


static func read_prop(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var kind_id := r.read_string(ID_BYTES)
	var owner_id := r.read_varint()
	var is_entity := r.read_bool()
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return {
		"net_id": net_id,
		"kind_id": StringName(kind_id),
		"owner_id": owner_id,
		"is_entity": is_entity,
		"position": at,
		"ok": r.ok(),
	}


static func write_prop_gone(net_id: int, reason: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(reason), ID_BYTES)
	return w.to_bytes()


static func read_prop_gone(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var reason := r.read_string(ID_BYTES)
	return {"net_id": net_id, "reason": StringName(reason), "ok": r.ok()}


## What a player's physics gun is holding, or 0 for nothing. The beam is drawn from
## this: a client cannot see a server-side grab any other way, and a physics gun with
## no visible beam reads as a broken gun.
static func write_held(player_id: int, net_id: int, frozen: bool) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_bool(frozen)
	return w.to_bytes()


static func read_held(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var frozen := r.read_bool()
	return {"player_id": player_id, "net_id": net_id, "frozen": frozen, "ok": r.ok()}


static func write_weapon(player_id: int, weapon_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_string(String(weapon_id), ID_BYTES)
	return w.to_bytes()


static func read_weapon(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var weapon_id := r.read_string(ID_BYTES)
	return {"player_id": player_id, "weapon_id": StringName(weapon_id), "ok": r.ok()}


## Who is in what, and where. Sent to everybody, because a client draws other people
## sitting in cars and has to stop drawing them walking.
##
## [param seat_index] is the index into the vehicle definition's own seat list rather
## than the seat's id: the client has the same catalogue and a byte is a byte, where an
## id is up to sixty-four of them per player per journey.
static func write_seat(
	player_id: int, vehicle_net_id: int, seat_index: int, seated: bool
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(vehicle_net_id)
	w.write_uint(clampi(seat_index, 0, 255), 8)
	w.write_bool(seated)
	return w.to_bytes()


static func read_seat(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var vehicle_net_id := r.read_varint()
	var seat_index := r.read_uint(8)
	var seated := r.read_bool()
	return {
		"player_id": player_id,
		"vehicle_net_id": vehicle_net_id,
		"seat_index": seat_index,
		"seated": seated,
		"ok": r.ok(),
	}


# --- Maps ------------------------------------------------------------------

static func write_map(map_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_string(String(map_id), ID_BYTES)
	return w.to_bytes()


static func read_map(r: DotNetReader) -> StringName:
	return StringName(r.read_string(ID_BYTES))


# --- The timer -------------------------------------------------------------

## Run state, through dot-timer's own [DotTimerNet.RunState].
##
## [b]Not a hand-rolled encoding, and the first draft of this file was one.[/b] A run is
## a tick count plus two sub-tick fractions — that is dot-timer's whole design, and it
## is what makes a 64 Hz run comparable with a 128 Hz one. An encoder here that sent a
## start tick and forgot the fractions would quantise every mirrored time back to the
## tickrate, silently, on the client only.
static func write_timer(player_id: int, state: DotTimerNet.RunState) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	state.write(w)
	return w.to_bytes()


static func read_timer(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var state := DotTimerNet.RunState.new()
	state.read(r)
	return {"player_id": player_id, "state": state, "ok": r.ok()}


static func write_finish(player_id: int, finish: DotTimerNet.Finish) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	finish.write(w)
	return w.to_bytes()


static func read_finish(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var finish := DotTimerNet.Finish.new()
	finish.read(r)
	return {"player_id": player_id, "finish": finish, "ok": r.ok()}


# --- Notices ---------------------------------------------------------------

## [param player_id] 0 means everybody.
static func write_notice(player_id: int, text: String) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_string(text, TEXT_BYTES)
	return w.to_bytes()


static func read_notice(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var text := r.read_string(TEXT_BYTES)
	return {"player_id": player_id, "text": text, "ok": r.ok()}


# --- Asks ------------------------------------------------------------------

static func write_id(id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_string(String(id), ID_BYTES)
	return w.to_bytes()


static func read_id(r: DotNetReader) -> StringName:
	return StringName(r.read_string(ID_BYTES))


static func write_index(index: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(maxi(index, 0), 8)
	return w.to_bytes()


static func read_index(r: DotNetReader) -> int:
	return r.read_uint(8)
