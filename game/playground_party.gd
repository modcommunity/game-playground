class_name PlaygroundParty
extends Node

## A sandbox for friends, and the one place a host migration would be a catastrophe.
##
## [b]This game's answer to dot-peer-to-peer turns on one fact nobody else's does: the
## world IS the host's physics state.[/b] Every prop somebody spawned, every contraption
## they froze in place, the whole evening's building, lives in one process's rigid bodies —
## so electing a new host hands everybody a world with nothing in it. Not a stutter, not a
## re-sync: an empty room, silently, with every count still correct.
##
## So `migrate_host` is **off**, and the log says why when a session opens. Five games in
## this family take this addon and between them give five reasons for two answers:
##
## | | migrates | why |
## | --- | --- | --- |
## | game-simple-lobby | yes | nothing is built, and a host leaving is somebody's evening |
## | game-hungario | yes | a continuous arena with no round to be in the middle of |
## | game-arena | no | the host holds the match clock, the score and every hitbox |
## | game-g2gfast | no | a time made of two machines' clocks is worse than no time |
## | **this one** | **no** | **the world is the host's physics state and does not move** |
##
## The trust model is `HOST_AUTHORITATIVE` rather than sandboxed, which is the other
## disagreement: a sandbox is a place where a friend hosting *should* be able to give
## everybody money and spawn a hundred crates, because that is the game. What must not
## leave is anything persistent — [method reporting_allowed] is the one place that is
## asked, and it answers no while a session is live.

const CHANNEL := "playground.party"

signal open(code: String)
signal closed(res: DotResult)

var session: DotP2PSession = null

@export var signalling_url: String = ""

var _http: DotHttp = null


func setup() -> DotResult:
	session = DotP2PSession.new()
	session.name = "P2P"
	session.config = _config()
	add_child(session)

	var res := session.setup()
	if not res.ok:
		return res.wrap("the playground's party session")

	session.signaller = _make_signaller()
	session.ended.connect(func(r: DotResult) -> void: closed.emit(r))
	return DotResult.success(null)


func _config() -> DotP2PConfig:
	var c := DotP2PConfig.new()
	# Six. A sandbox's cost is the props rather than the players, and a domestic uplink
	# carrying six people's worth of rigid-body transforms is already working hard.
	c.max_peers = 6
	# The host decides, which in a sandbox is what a friend hosting SHOULD be able to do.
	c.trust = DotP2PConfig.Trust.HOST_AUTHORITATIVE
	# Off. See the class notes: the world is the host's physics state.
	c.migrate_host = false
	c.signalling_url = signalling_url
	return c


func _make_signaller() -> DotP2PSignaller:
	if signalling_url.is_empty():
		return DotP2PSignallerLoopback.new(session.local_id)
	_http = DotHttp.new()
	_http.name = "PartyHttp"
	add_child(_http)
	return DotP2PSignallerHttp.new(signalling_url, session.local_id, _http)


func host(display_name: String) -> DotResult:
	if not DotP2PSession.available():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"this build cannot host a sandbox",
			DotP2PSession.unavailable_reason()
		)
	var res := session.host(display_name)
	if res.ok:
		open.emit(str(res.value))
		# Both halves said once, at the point somebody could still choose otherwise.
		DotLog.info(
			CHANNEL,
			"a sandbox is open. Nothing is filed anywhere, and if the host leaves the "
			+ "world goes with them.",
			{"code": str(res.value)}
		)
	return res


func join(code: String, display_name: String) -> DotResult:
	return session.join(code, display_name)


func leave() -> void:
	session.leave()


func active() -> bool:
	return session != null and session.state() != &"idle"


## Whether records, statistics and achievements may leave this session.
##
## [b]Asked in one place.[/b] The alternative is four reporters each checking a flag, which
## is four places to forget -- and the one that is forgotten is the one that files a
## peer-to-peer host's time to a real board.
func reporting_allowed() -> bool:
	return not active()


func describe_lines() -> PackedStringArray:
	if session == null:
		return PackedStringArray(["no party"])
	var out := session.describe_lines()
	out.append("  reporting %s" % ("allowed" if reporting_allowed() else "refused"))
	out.append("  the world does not survive the host leaving, which is why it does not migrate")
	return out
