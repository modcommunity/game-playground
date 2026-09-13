extends Node

## The identity half, in one node: who somebody is, what they are called, what they wear.
##
## dot-auth says who a connection belongs to, dot-user turns that into a profile that
## follows them between servers, dot-user-avatar says what they may wear, and
## [DotPlatformHub] joins the three into one admission. This builds all of them with this
## sandbox's settings and then gets out of the way: the admission itself is
## [DotPlatformModule]'s, which the dedicated example loads beside [PlaygroundModule].
##
## [b]It is optional and the sandbox must work without it.[/b] A LAN server somebody runs
## for an evening has no accounts, and that is the most common deployment there is — so
## [PlaygroundModule] duck-types against the platform module rather than naming it.
##
## [b]The reason it is here at all is dot-stats.[/b] A statistic has to be filed under a
## key, and dot-stats refuses an account id as one before it leaves the server: the scoped
## pseudonymous id dot-user derives is what a board and an achievement are keyed by, and
## without dot-platform there is nowhere to get one. A sandbox with no identity stack files
## everything under the session id, which lasts exactly as long as the session — honest,
## and the reason this exists.

const CHANNEL := "playground.platform"

const DEFAULT_DIR := "user://playground_identity"

var users: DotUserManager = null
var avatars: DotAvatarManager = null
var hub: DotPlatformHub = null

var directory: String = DEFAULT_DIR

## The pseudonym scope.
##
## [b]The field that decides whether operators can correlate their players.[/b] dot-user
## derives a per-scope id from the account and this string, so two servers with different
## scopes see two unrelated ids for one person. Per-server deliberately: a community that
## wants one identity across its servers sets them all the same, and that is a decision
## rather than a default.
var scope: String = "server:playground"

var service_scope: StringName = &""


## Builds profiles, avatars and the hub, in that order.
##
## [b]Awaited, and it has to be.[/b] A store may be a directory that does not exist yet.
## Called from an application's own setup rather than from a module's `_module_load`,
## because dot-server's module host does not await that and a module whose load suspends
## returns null to it.
func setup() -> DotResult:
	var profiled: DotResult = await _build_users()

	if not profiled.ok:
		return profiled

	var dressed: DotResult = await _build_avatars()

	if not dressed.ok:
		return dressed

	return await _build_hub()


func _build_users() -> DotResult:
	users = DotUserManager.new()
	users.name = "Users"
	users.register_service = true
	users.service_scope = service_scope
	users.load_layered_config = false
	users.config_file = ""
	users.server_id = scope

	var config := DotUserConfig.new()
	config.backend = "local"
	config.directory = "%s/profiles" % directory
	config.scope = scope
	config.scope_key_file = "%s/scope.key" % directory
	# A sandbox you can walk into. A profile that required an account would make the name
	# box on the launcher a lie.
	config.allow_guest_profiles = true
	config.create_missing = true
	config.save_on_leave = true
	# [b]Off, unlike the lobby's.[/b] A sandbox has a leaderboard on it: a name that can
	# change is a record whose owner cannot be recognised, and the whole point of a board
	# is that somebody can be told they beat somebody.
	config.allow_name_changes = false
	config.refuse_duplicate_names = true
	users.config = config

	add_child(users)

	return await users.setup()


func _build_avatars() -> DotResult:
	avatars = DotAvatarManager.new()
	avatars.name = "Avatars"
	avatars.register_service = true
	avatars.service_scope = service_scope
	avatars.load_layered_config = false
	avatars.config_file = ""
	# [b]The server holds the schema and no art at all.[/b] That is dot-user-avatar's one
	# idea: whether an avatar is legal is a question about a document and an entitlement
	# set, and a dedicated server answers it without ever loading a mesh.
	avatars.schema = avatar_schema()

	var config := DotAvatarConfig.new()
	config.backend = "local"
	config.directory = "%s/avatars" % directory
	avatars.config = config

	add_child(avatars)

	return await avatars.setup()


func _build_hub() -> DotResult:
	hub = DotPlatformHub.new()
	hub.name = "Platform"
	hub.register_service = true
	hub.service_scope = service_scope
	hub.load_layered_config = false
	hub.config_file = ""

	var config := DotPlatformConfig.new()
	# [b]Neither is required.[/b] dot-platform's own module documents that admission
	# completes shortly *after* dot-server has already admitted the player, because there
	# is no cancellable stage between authentication and content — so `require_profile` is
	# a promise it cannot keep yet. A sandbox is also the last place to hold somebody at
	# the door.
	config.require_profile = false
	config.require_avatar = false
	config.apply_profile_name = true
	config.broadcast_avatar_changes = true
	config.onboarded_needs_avatar = false
	hub.config = config

	add_child(hub)

	return await hub.setup()


## What somebody may wear, as a document with no art in it.
##
## Three slots and eight parts, small on purpose: what matters is that the *choosing* works
## end to end — the server refusing something you have not unlocked, the choice surviving a
## reconnect, and everybody else seeing it. A hundred hats would prove nothing more.
##
## **One part is not free.** `hat_hard` requires an entitlement, because entitlements
## default to nothing and a server that granted everything would work perfectly in every
## test, ship, and quietly be a game where every unlock is free.
static func avatar_schema() -> DotAvatarSchema:
	var schema := DotAvatarSchema.new()
	schema.id = &"pg_builder"
	schema.version = 1

	var body := DotAvatarSlot.make(&"body", true, &"body_plain")
	body.display_name = "Body"
	body.layer = 20

	var hat := DotAvatarSlot.make(&"hat")
	hat.display_name = "Hat"
	hat.layer = 60

	var badge := DotAvatarSlot.make(&"badge")
	badge.display_name = "Badge"
	badge.layer = 40

	schema.slots = [body, badge, hat]

	var parts: Array[DotAvatarPart] = []

	for entry in [
		[&"body_plain", &"body", true, 2],
		[&"body_overalls", &"body", true, 2],
		[&"body_suit", &"body", true, 2],
		[&"hat_cap", &"hat", true, 1],
		[&"hat_beret", &"hat", true, 1],
		[&"hat_hard", &"hat", false, 1],
		[&"badge_dot", &"badge", true, 1],
		[&"badge_star", &"badge", true, 1],
	]:
		var row: Array = entry
		var part := DotAvatarPart.make(row[0], row[1], bool(row[2]))
		part.colour_channels = int(row[3])
		# Everything in the body slot falls back to the plain one, so somebody wearing a
		# part this build has never heard of is drawn as a person rather than as nothing.
		# The plain body has no fallback: a part that fell back to itself is a resolution
		# loop that cannot terminate, which the schema refuses — and which game-hungario's
		# suite missed for a while because it never validated a schema.
		part.fallback_id = (
			&"body_plain" if row[1] == &"body" and row[0] != &"body_plain" else &""
		)
		parts.append(part)

	schema.parts = parts
	schema.invalidate()
	return schema


## The auth server a sandbox runs when there is no backbone.
##
## Guests, explicitly: `ANONYMOUS` with `allow_guests` is what makes a server somebody can
## walk into, and it is what every deployment of this game runs today. A real backbone means
## a device-code grant and a person clicking Approve in a browser, which nothing in this
## family has ever done against a live site.
static func guest_auth_config() -> DotAuthConfig:
	var config := DotAuthConfig.new()
	config.strategy = DotAuthConfig.Strategy.ANONYMOUS
	config.allow_guests = true
	return config


## The scoped pseudonymous key a session is filed under, or the session id.
##
## [b]The one function everything that files a number should go through.[/b] dot-stats
## refuses an account id as a player key before it leaves the server, and this is where a
## deployment with dot-platform gets the right one — and where a deployment without it gets
## an honest fallback rather than an account id by accident.
static func key_for_session(server: DotServer, session: DotClientSession) -> String:
	if server == null or session == null:
		return ""

	var platform: Object = server.modules.get_module("platform")

	if platform != null and platform.has_method("key_for_userid"):
		var key: Variant = platform.call("key_for_userid", session.userid)

		if key != null and str(key) != "":
			return str(key)

	# No identity stack. The session id lasts exactly as long as the session, which is the
	# honest answer — and it is prefixed so it can never be mistaken for a scoped id in a
	# stored record.
	return "local:%d" % session.userid


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("identity     scope %s" % scope)

	if hub != null:
		out.append_array(hub.describe_lines())

	return out
