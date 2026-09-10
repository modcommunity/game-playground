class_name PlaygroundVoice
extends Node

## The client half of voice: a microphone, a codec, a jitter buffer per speaker, and a key.
##
## [b]dot-voice does the work; this decides three things[/b] — where a captured frame goes,
## where an arriving one comes from, and what opens the gate. Everything else (resampling,
## encoding, sequencing, concealment, one buffer per speaker) is [DotVoiceManager]'s.
##
## [b]Push to talk, and the microphone closes when a screen takes the keyboard.[/b] A
## key-up delivered into a chat box or a spawn menu is a gate that never closes, and the
## resulting bug is reported as "everyone could hear me" rather than as a bug.
##
## [b]It degrades to nothing rather than to an error.[/b] A headless run, a browser that
## refused microphone permission and a machine with no sound card all end here with
## [member available] false and playback still working — which matters, because
## `AudioServer` reports a 44100 Hz mix rate and a "Default" input device in a headless run
## and only `get_driver_name()` says `"Dummy"`. A capability check built on any of the
## others passes on a machine with no audio at all, and the symptom is a capture returning
## silence for ever with nothing reporting a problem.

const CHANNEL := "playground.voice"

## Held to talk. `V` because it is not a movement key and not one this game already uses:
## `1` and `2` are the tools, `Q` is the menu, `E` spawns, `F` gets into a vehicle.
const KEY_TALK := KEY_V


signal talking_changed(talking: bool)
signal speaker_changed(speaker: int, speaking: bool)


var available: bool = false
var unavailable_reason: String = ""
var manager: DotVoiceManager = null
var send_fn: Callable = Callable()

## Whether playback goes into a buffer instead of an audio device.
##
## [b]What makes the receiving half checkable at all.[/b] `DotVoiceSinkPlayer` needs an
## `AudioStreamPlayer` and a mixer, neither of which exists in a headless run — so without
## a buffer sink the receiving half is the one part of this game nothing can ever run, and
## a wire that decoded to nothing would look exactly like one that worked. dot-voice put
## [DotVoiceSource] and [DotVoiceSink] behind an interface for precisely this.
var buffered_playback: bool = false

var _talking: bool = false
var _buffers: Dictionary = {}


func setup(enable_capture: bool = true) -> DotResult:
	manager = DotVoiceManager.new()
	manager.name = "Voice"
	# [b]The config comes from the same file the server's does.[/b] A sample rate or a
	# frame length that differs between two peers is a stream of packets the router
	# refuses for being the wrong length — counted, and said to nobody.
	manager.config = PlaygroundServices.voice_config()
	manager.config_file = ""
	manager.register_service = false
	manager.positional_playback = false
	manager.send_fn = _send
	add_child(manager)

	manager.speaker_changed.connect(_on_speaker_changed)

	buffered_playback = not enable_capture

	if buffered_playback:
		manager.sink_factory = _make_buffer_sink

	var supported := DotVoiceSourceMicrophone.is_supported()
	available = supported.ok

	if not available:
		unavailable_reason = supported.error.message
		DotLog.info(CHANNEL, "no microphone; listening only", {
			"why": unavailable_reason,
		})
		return DotResult.success(false)

	if not enable_capture:
		return DotResult.success(false)

	var opened := manager.start_capture()

	if not opened.ok:
		available = false
		unavailable_reason = opened.error.message
		return DotResult.success(false)

	return DotResult.success(true)


## The talk key. Edge triggered on both edges, and the release is the one that matters.
func handle_event(event: InputEvent) -> bool:
	if not (event is InputEventKey) or event.is_echo():
		return false

	var key := event as InputEventKey

	if key.keycode != KEY_TALK:
		return false

	set_talking(key.pressed)
	return true


func set_talking(pressed: bool) -> void:
	if manager == null or not available or _talking == pressed:
		return

	_talking = pressed
	manager.set_talking(pressed)
	talking_changed.emit(pressed)


## Everything goes quiet: a screen took the keyboard, the window lost focus, the client
## disconnected. Called from every one of those, because the key-up will not arrive.
func release() -> void:
	set_talking(false)


func is_talking() -> bool:
	return _talking


func receive(payload: PackedByteArray) -> void:
	if manager != null:
		manager.receive(payload)


func active_speakers() -> PackedInt64Array:
	return manager.active_speakers() if manager != null else PackedInt64Array()


## Stops hearing somebody, on this machine only.
##
## [b]A local mute, deliberately not a request to the server.[/b] "I do not want to hear
## this person" is a client's business; "this person may not speak" is a moderator's and is
## dot-moderation's — a client asking a server to stop sending somebody's voice to
## everybody is not muting anybody.
func set_local_mute(speaker: int, muted: bool) -> void:
	if manager != null:
		manager.set_local_mute(speaker, muted)


func _make_buffer_sink(speaker: int) -> DotVoiceSink:
	var sink := DotVoiceSinkBuffer.new()
	_buffers[speaker] = sink
	return sink


## How loud a speaker has been, when playback is buffered. Zero otherwise.
##
## An amplitude rather than a frame count: a count says the packets arrived, this says they
## decoded to something, and the difference is "the wire works" against "you can hear them".
func heard_rms(speaker: int) -> float:
	var sink: Variant = _buffers.get(speaker)
	return (sink as DotVoiceSinkBuffer).rms() if sink is DotVoiceSinkBuffer else 0.0


func _send(bytes: PackedByteArray) -> void:
	if send_fn.is_valid():
		send_fn.call(bytes)


func _on_speaker_changed(speaker: int, speaking: bool) -> void:
	speaker_changed.emit(speaker, speaking)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("voice        %s" % (
		"talking" if _talking else ("ready" if available else "no microphone")
	))

	if manager != null:
		out.append_array(manager.describe_lines())

	return out
