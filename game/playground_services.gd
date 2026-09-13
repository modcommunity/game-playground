extends Node

const Playground := preload("playground.gd")
const PlaygroundNetBridge := preload("net/playground_net_bridge.gd")
const PlaygroundPlayer := preload("playground_player.gd")

## Chat, moderation and voice, wired to this sandbox's people and this game's wire.
##
## [b]The same three addons the other two games join, and the third set of proximity
## answers.[/b] game-simple-lobby is a room you can see all of, so its voice is the whole
## room; game-hungario is an arena, so its voice is proximity. A sandbox is both at once —
## people build together in one corner and run the course in another — so **text has a
## near channel and voice is the whole server**, which is the arrangement every sandbox
## server has ever shipped with, and for the reason they all found: a builder shouting for
## a hand should be heard, and somebody in the corner reading should be able to stop
## reading the shouting.
##
## [b]dot-server's own chat is cancelled, not run beside this.[/b] [DotChatRouter] has the
## rules now, and [PlaygroundModule] cancels `player_chat` so there is exactly one path.
## Two would be two sets of rules to keep in step, and the one that skipped the filter
## would be the one that leaked admin chat.

const CHANNEL := "playground.services"

## Where the chat relay reads its own settings from, when the host assigned none.
##
## `user://` rather than `res://`: it is an operator's file on a running server, and an
## exported build cannot be written to. Absent is the normal case and costs nothing -- the
## file layer is skipped and the environment and command line still apply, which is how a
## container turns the relay on without a file at all.
const RELAY_CONFIG_PATH := "user://chat_relay.json"

const CHANNEL_ALL := &"all"
const CHANNEL_NEAR := &"near"
const CHANNEL_ADMIN := &"admin"
const CHANNEL_WHISPER := &"whisper"

## How far "near" reaches, in metres.
##
## A sandbox is measured in tens of metres and a build is a few across; twenty-five is far
## enough to include everybody working on one thing and short enough that the other corner
## is a different conversation.
const NEAR_RANGE := 25.0

const PUNISHMENTS_PATH := "user://playground_punishments.json"


signal command_entered(peer_id: int, command: String, args: PackedStringArray)


var chat: DotChatRouter = null
var moderation: DotModerationManager = null
var voice: DotVoiceRouter = null
## The website chat relay, when one is configured. See [method _build_relay].
var relay: DotChatRelay = null

## The relay's configuration. Left null, a default is built and the relay stays OFF.
##
## Off by default for the same reason every other power in this family is: a relay
## carries what your players type to a web page and back, and that is an operator's
## decision rather than a consequence of installing an addon.
@export var relay_config: DotChatRelayConfig = null

## The backbone client the relay posts through, assigned by the host BEFORE setup.
##
## [b]An [Object], not a [DotBackboneClient].[/b] The relay holds it duck-typed so that
## dot-chat need not depend on dot-auth, and keeping one spelling across the seam means
## the duck-typed contract is the only contract.
var backbone: Object = null


var bridge: PlaygroundNetBridge = null
var game: Playground = null
var server: DotServer = null

var service_scope: StringName = &""
var punishments_path: String = PUNISHMENTS_PATH
var punishments_loaded: bool = false


## Builds all three.
##
## [b]Not a coroutine.[/b] [method DotModuleHost.load_module] calls `_module_load()` with a
## bare call and reads `result.ok` on the next line, so a module whose load suspends
## returns null there and the host crashes on a module that was working.
func setup() -> DotResult:
	if bridge == null or game == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The services need a bridge and a game."
		)

	# Moderation first: it is what registers `dot_mute_source`, and
	# [method DotChatRouter.start] warns once — and then never again — when there is
	# nothing under that name.
	var punished := _build_moderation()

	if not punished.ok:
		return punished

	var talking := _build_chat()

	if not talking.ok:
		return talking

	# After chat, because it needs the router; not fatal, because a relay that cannot
	# start is a server that still runs a perfectly good match.
	var relayed := _build_relay()
	DotLog.result(CHANNEL, "the website chat relay", relayed)

	return _build_voice()


func _build_moderation() -> DotResult:
	moderation = DotModerationManager.new()
	moderation.name = "Moderation"
	moderation.store = DotPunishmentStoreFile.new(punishments_path)
	# No scope: the unconfigured case is the only case a single-server community is in,
	# and it is the one dot-moderation shipped a bug about.
	moderation.server_scope = ""
	moderation.register_mute_source = true
	moderation.register_ban_source = true
	# Zero means "no immunity to respect", not "the highest rank there is".
	moderation.equal_immunity_may_act = true
	moderation.key_for_peer = _subject_for_peer
	add_child(moderation)

	# A bare statement call: [method DotModerationManager.load_all] is a coroutine because
	# a store MAY be an HTTP one, and [DotPunishmentStoreFile] is not — so this runs to
	# completion without suspending. It cannot be awaited from a module load.
	moderation.load_all()
	punishments_loaded = true

	return DotResult.success(null)


## Who a peer is, for a punishment: the durable account uid.
##
## [b]Deliberately not the same answer [method _key_of] gives dot-chat.[/b] A punishment is
## against a person who will come back, so it is keyed by something that survives a
## reconnect — otherwise a gag lasts until the gagged player presses reconnect, which is
## the first thing anybody who has been gagged tries. A chat line is attributed to somebody
## standing in this sandbox now, which is a session.
func _subject_for_peer(peer_id: int) -> String:
	var session := _session_for(peer_id)

	if session != null:
		return DotPunishmentSubject.for_uid(session.uid())

	var player_id := bridge.player_for_peer(peer_id) if bridge != null else 0
	return DotPunishmentSubject.for_uid("local:%d" % player_id) if player_id != 0 else ""


func _build_chat() -> DotResult:
	chat = DotChatRouter.new()
	chat.name = "Chat"
	chat.rules = chat_rules()
	chat.rules_file = ""
	chat.install_default_channels = false
	chat.handle_me_command = true
	chat.register_as = _scoped(DotChatRouter.SERVICE)
	chat.mute_service = DotModerationManager.MUTE_SERVICE

	chat.send_fn = _send_chat
	chat.peers_fn = _chat_peers
	chat.name_fn = _name_of
	chat.key_fn = _key_of
	chat.position_fn = _position_of
	chat.is_admin_fn = _is_admin

	add_child(chat)

	var started := chat.start()

	if not started.ok:
		return started.wrap("The chat router could not start")

	for channel in chat_channels():
		var added := chat.add_channel(channel)

		if not added.ok:
			return added.wrap("A chat channel was refused")

	chat.command_entered.connect(func(
		peer: int, command: String, args: PackedStringArray, _raw: String
	) -> void:
		command_entered.emit(peer, command, args)
	)

	return DotResult.success(null)


static func chat_channels() -> Array[DotChatChannel]:
	var out: Array[DotChatChannel] = []

	var everyone := DotChatChannel.make(CHANNEL_ALL, "All", DotChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# A sandbox is a place people arrive at mid-conversation more than any other kind of
	# server, because there is no round to wait for.
	everyone.backlog = 20
	everyone.history_limit = 300
	out.append(everyone)

	var near := DotChatChannel.make(CHANNEL_NEAR, "Near", DotChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.68, 0.83, 0.62)
	near.radius = NEAR_RANGE
	# [b]No backlog on a proximity channel.[/b] A backlog is handed to whoever joins, and
	# a line somebody said quietly beside their build is exactly the line that must not be
	# replayed to a stranger who was not standing there.
	near.backlog = 0
	near.history_limit = 150
	out.append(near)

	var admin := DotChatChannel.make(CHANNEL_ADMIN, "Admin", DotChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# A gag is about a player's speech; an admin who has been gagged has a bigger problem
	# than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := DotChatChannel.make(
		CHANNEL_WHISPER, "Whisper", DotChatChannel.Scope.DIRECT
	)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## What a line may be.
##
## Longer and chattier than a shooter's, because a sandbox is a place people talk in while
## they build — and `!` and `/` are both command prefixes, because this game's console
## surface is the largest in the family and half of it is meant to be reachable from chat.
static func chat_rules() -> DotChatRules:
	var rules := DotChatRules.new()
	rules.max_length = 200
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 30
	rules.burst = 5.0
	rules.flood_penalty_sec = 10.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	# An unclaimed `!command` is not broadcast: a player typing `!ban` at a server with no
	# such command would otherwise say "!ban" to the whole server, which is worse than
	# nothing happening.
	rules.broadcast_unknown_commands = false
	rules.history_limit = 400
	return rules


func _send_chat(wire: Dictionary, recipients: PackedInt32Array) -> void:
	if bridge == null:
		return

	# The session id, lifted into the one meta field this wire carries, so a client can
	# colour a line by whose it is. The key IS the session id — see [method _key_of].
	var addressed := wire.duplicate()
	var key := str(wire.get("s", ""))

	if key.is_valid_int() and key.to_int() > 0:
		addressed["x"] = {"p": key.to_int()}

	for peer_id in recipients:
		bridge.send_chat(int(peer_id), addressed)



# --- The website relay -----------------------------------------------------

## Joins this server's chat to its room on the website.
##
## [b]Every seam points at something that already existed.[/b] The backbone client is
## dot-auth's. The permission answer is dot-server's admin manager, through
## `uid_has_permission` — the method written for exactly this, deciding what somebody may
## do when they are not connected. The command runner is `DotServer.run_command_as_uid`,
## which builds a context with that uid's OWN flags rather than RCON's root.
##
## Nothing here is a new policy. A relayed command is checked against the same file, by
## the same flags, as the same person typing it in game.
func _build_relay() -> DotResult:
	if relay_config == null:
		relay_config = DotChatRelayConfig.new()

		# LAYERED, and it was not. A `DotConfig` is exported defaults, then a JSON file,
		# then the environment, then the command line -- and a config that is merely `new()`d
		# has only the first of those, so `DOT_CHAT_RELAY_ENABLED=1` and
		# `--chat-relay-enabled` both did nothing. The relay could be turned on only by a
		# host that assigned a config object, and no host in this family assigns one: the
		# whole addon was unreachable from every documented route, in all five games, with
		# nothing erroring, because a disabled relay is a legitimate configuration.
		#
		# Only on the config this builds. A config the host handed over is the host's, and
		# re-layering it here would overwrite a deliberate choice with an environment
		# variable somebody set for a different server.
		var layered := relay_config.load_layered(RELAY_CONFIG_PATH)
		if not layered.ok:
			DotLog.warn(CHANNEL, "the chat relay configuration is not usable", {
				"why": str(layered.error),
			})
			return DotResult.success(null)

	if not relay_config.enabled:
		return DotResult.success(null)

	if backbone == null:
		# **Found, not handed over.** A backbone client is built by whatever owns the
		# server's credential — dot-server-deploy's `TmcReport`, or this game's own
		# identity layer — and a relay built during module load exists before any host
		# could assign one. `DotBackboneClient` publishes itself under this name for
		# exactly that reason; the ordering trap is the one that left dot-server's audit
		# log unopened in every default configuration.
		backbone = DotRegistry.get_service(&"dot_backbone_client")

	if backbone == null:
		# Info and success, not a failure, and the difference matters now that the relay
		# can be turned on by an environment variable. A deployment that exports
		# `DOT_CHAT_RELAY_ENABLED=1` for a whole fleet and holds a credential for only some
		# of them is the ordinary case -- and a red line on every boot of the others is this
		# family's own "a warning that reads like a setting nobody filled in", which is how
		# a real one stops being read. The line names what to do, which is the only part an
		# operator can act on.
		DotLog.info(
			CHANNEL,
			"the chat relay is on but there is no backbone client, so it will not start",
			{"fix": "put a server-scoped integration token in the listing configuration"}
		)
		return DotResult.success(null)

	relay = DotChatRelay.new()
	relay.name = "ChatRelay"
	relay.router = chat
	relay.config = relay_config
	relay.client = backbone
	relay.permission_fn = _uid_has_permission
	relay.command_fn = _run_relayed_command
	relay.commands_fn = _relay_command_document

	add_child(relay)

	var started := relay.start()

	if not started.ok:
		remove_child(relay)
		relay.queue_free()
		relay = null
		return started

	relay.site_command.connect(_on_site_command)

	# [b]Tell the clients.[/b] A player whose lines already reach a page they are looking
	# at does not need a chat box in front of the game, and a player whose lines reach
	# nothing but this server needs one badly. Only the server knows which.
	if server != null and server.chat != null:
		server.chat.watch_relay(relay)

	return DotResult.success(relay)


func _uid_has_permission(uid: String, flag: String) -> bool:
	if server == null or server.admins == null:
		return false
	return server.admins.uid_has_permission(uid, flag)


func _run_relayed_command(
	uid: String, command: String, args: PackedStringArray, source: int
) -> void:
	if server == null:
		return

	for reply in server.run_command_as_uid(uid, command, args, source):
		DotLog.info(CHANNEL, "relayed command reply", {"uid": uid, "line": reply})


func _on_site_command(uid: String, command: String, allowed: bool) -> void:
	# Audited either way. A refusal is the half worth having a record of: it is somebody
	# trying to drive the server from a web page without the rights to.
	if server != null and server.audit != null:
		server.audit.record(
			"relay_command", "web:%s" % uid, command, {"allowed": allowed}
		)


# --- Voice -----------------------------------------------------------------

func _build_voice() -> DotResult:
	var config := voice_config()
	var problem := config.validate()

	if not problem.ok:
		return problem.wrap("The voice configuration is not usable")

	voice = DotVoiceRouter.new()
	voice.name = "Voice"
	voice.config = config
	# [b]Everybody, and the near channel is text's.[/b] Text you can read two of at once
	# and choose; voice you cannot, and a sandbox where you walk out of earshot of the
	# person helping you build is a sandbox where nobody uses voice. The proximity
	# machinery is wired and reachable — `position_fn` is set below — so a deployment that
	# wants it changes one line.
	voice.default_channel = DotVoiceRouter.Channel.ALL
	voice.proximity_range = config.proximity_range
	voice.max_bytes_per_second = config.max_bytes_per_second
	voice.send_fn = _send_voice
	voice.position_fn = _position_of

	add_child(voice)

	return DotResult.success(null)


## The voice format, which both ends must agree on exactly.
##
## Static, and read by the client too: [method DotVoiceConfig.format_fingerprint] exists
## because a sample rate or a frame length that differs between two peers is a stream of
## packets the router refuses for being the wrong length, counted and said to nobody.
static func voice_config() -> DotVoiceConfig:
	var config := DotVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = NEAR_RANGE
	config.max_bytes_per_second = 6144
	return config


func _send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if bridge != null and bridge.link != null:
		bridge.link.send_voice(peer_id, payload)


# --- Peers -----------------------------------------------------------------

func add_peer(peer_id: int) -> void:
	if voice != null:
		voice.add_peer(peer_id)


func remove_peer(peer_id: int) -> void:
	if voice != null:
		voice.remove_peer(peer_id)

	if chat != null:
		# The rate limiter's and the repeat detector's memory of this peer. Without it a
		# reconnecting player inherits whatever the last holder of that peer id had been
		# saying, and is told they are repeating themselves on their first line.
		chat.forget(peer_id)


func _chat_peers() -> PackedInt32Array:
	return bridge.ready_peers() if bridge != null else PackedInt32Array()


func _session_for(peer_id: int) -> DotClientSession:
	return server.session_of(peer_id) if server != null else null


func _name_of(peer_id: int) -> String:
	var session := _session_for(peer_id)
	return session.display_name if session != null else "player %d" % peer_id


## The key a chat line is attributed to: the speaker's session id, as a string.
##
## [b]Not the account uid.[/b] "Who said this" is a question about this server right now,
## and a client resolving it has a roster and nothing else. Two guests behind one device id
## share a uid, so keying by that puts the second person's words under the first person's
## name — game-simple-lobby found that with two clients in one process, and every count
## matched throughout.
func _key_of(peer_id: int) -> String:
	var session_id := bridge.player_for_peer(peer_id) if bridge != null else 0
	return str(session_id) if session_id != 0 else ""


## Where somebody is standing, as dot-chat and dot-voice both ask for it.
##
## [b]The controller's state, not the node.[/b] A player riding a vehicle is reparented
## into the seat, and the node's global position is then the seat's — which is right for a
## camera and wrong for everything that asks where the *person* is.
## [method Playground._carry_riders] copies the position back onto the state for exactly
## this class of reader, and the state is what everything else in this game uses.
func _position_of(peer_id: int) -> Vector3:
	if bridge == null or game == null:
		return Vector3.ZERO

	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0:
		return Vector3.ZERO

	var found: Variant = game.players.get(StringName(str(session_id)))
	var player := found as PlaygroundPlayer

	if player == null or player.controller == null or player.controller.state == null:
		return Vector3.ZERO

	return player.controller.state.position


func _is_admin(peer_id: int) -> bool:
	var session := _session_for(peer_id)
	return session != null and session.is_admin()


func _scoped(base: StringName) -> StringName:
	return base if service_scope == &"" else StringName("%s:%s" % [base, service_scope])


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if chat != null:
		out.append_array(chat.describe_lines())

	if voice != null:
		out.append_array(voice.describe_lines())

	if moderation != null:
		out.append_array(moderation.describe_lines())
		out.append("punishments  %s" % (
			"loaded" if punishments_loaded else "STILL LOADING — nothing is enforced"
		))

	return out


## What this server accepts, for the site's `/` menu.
##
## Built at the relay's OWN source rather than at "chat", because the two answer different
## questions: a relay configured as RCON reaches everything RCON reaches, and a menu built
## from `chat_allowed` alone would hide an operator's whole toolbox from a deployment that
## deliberately made their site admins remote administrators -- or, the other way round,
## offer a records server's map change to somebody whose every attempt is refused.
##
## A method rather than a lambda because the relay re-reads it on every publish: the table
## changes when a module loads, and a callable that closed over a list would publish the
## table as it was at boot, for ever.
func _relay_command_document() -> Array[Dictionary]:
	if server == null or server.console == null:
		return []
	return server.console.command_document(relay_config.command_source as DotCmdContext.Source)
