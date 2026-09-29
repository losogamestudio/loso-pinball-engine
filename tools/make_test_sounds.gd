extends SceneTree
## Writes the small synthesized test sounds that ship in git (we made them, so
## they're free to share). Real game media is NOT in git; see assets/README.md.
##
##     godot --headless --path . -s res://tools/make_test_sounds.gd
##
## Safe to run again: it just rewrites the same files.

const RATE := 22050


func _init() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sfx/test")
	DirAccess.make_dir_recursive_absolute("res://assets/music/test")
	_save("res://assets/sfx/test/test_beep.wav", _tone([880.0], 0.12, 0.5))
	_save("res://assets/sfx/test/test_chime.wav", _tone([660.0, 990.0, 1320.0], 0.6, 0.35))
	_save("res://assets/sfx/test/test_buzz.wav", _tone([110.0, 116.0], 0.5, 0.4, true))
	# Two loops for hearing the music crossfade: a low and a high arpeggio.
	_save("res://assets/music/test/test_loop_a.wav", _arpeggio([220.0, 277.2, 329.6, 277.2], 4.0), true)
	_save("res://assets/music/test/test_loop_b.wav", _arpeggio([440.0, 523.3, 659.3, 783.99], 4.0), true)
	print("test sounds written")
	quit()


## Several sine (or square) tones mixed, with a quick fade out.
func _tone(freqs: Array, seconds: float, level: float, square := false) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for f: float in freqs:
			var s := sin(TAU * f * t)
			v += (signf(s) * 0.5 if square else s)
		var envelope := minf(1.0, i / (RATE * 0.005)) * (1.0 - float(i) / n)   # 5 ms attack, linear release
		out[i] = v / freqs.size() * level * envelope
	return out


## Notes of equal length, each with its own short fade, filling [param seconds].
func _arpeggio(notes: Array, seconds: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var steps := 16
	var note_len := seconds / steps
	for step in steps:
		out.append_array(_tone([notes[step % notes.size()]], note_len, 0.25))
	return out


func _save(path: String, samples: PackedFloat32Array, loop := false) -> void:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, clampi(int(samples[i] * 32767.0), -32768, 32767))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = samples.size()
	wav.save_to_wav(ProjectSettings.globalize_path(path))
