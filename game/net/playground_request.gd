class_name PlaygroundRequest
extends DotNetMessage

## Anything a client asks the authority for. Reliable, rare, to the server only.
##
## Small on purpose: every one of these costs the server work — a spawn is a rigid body
## and a budget check — and the manager rate-limits them per peer. A client sending
## thousands is broken or hostile, and in a sandbox the difference does not matter.

const NAME := &"pg.request"
const KIND_BITS := 4
const MAX_BODY := 2048

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


static func of(p_kind: int, p_body: PackedByteArray) -> PlaygroundRequest:
	var ask := PlaygroundRequest.new()
	ask.kind = p_kind
	ask.body = p_body
	return ask


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= PlaygroundEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)
	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "PlaygroundRequest(%s, %d bytes)" % [PlaygroundEvents.ask_name(kind), body.size()]
