extends DotNetInput

const PlaygroundNetCommand := preload("playground_net_command.gd")

## One tick of a player's intent, on the wire: a [DotFpsCommand] and nothing else.
##
## [b]The only thing a client may send about itself.[/b] Clients send inputs, never
## state — a client that could send a position could send any position, and dot-net's
## whole security model rests on the distinction. Which prop to spawn, which tool to
## hold and which map to vote for are requests rather than inputs: they change what the
## simulation IS rather than what it does this tick, so they go reliably and rarely
## through [PlaygroundRequest].
##
## The tool triggers ride in [member DotFpsCommand.buttons], because they are per-tick
## and predicted like a jump: holding the physics gun's trigger is a held button, not an
## event, and sending it as a request would put a grab a round trip behind the mouse.

var move: DotFpsCommand = DotFpsCommand.new()


func _write(writer: DotNetWriter) -> void:
	move.write(writer)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)


## Not optional. Quantisation bounds each field; it cannot bound the relationship
## between them, and a move vector of (1, 1) is 41% more speed than anybody else.
func _sanitise() -> void:
	move.sanitise()


func _equals(other: DotNetInput) -> bool:
	var them := other as PlaygroundNetCommand
	return them != null and move.equals(them.move)
