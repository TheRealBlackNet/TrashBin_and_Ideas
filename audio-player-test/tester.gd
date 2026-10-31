extends Control

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	AudioManager.sound_beendet.connect(_on_event_sound_beendet)
	AudioManager.musik_beendet.connect(_on_event_musik_beendet)
	AudioManager.musik_gewechselt.connect(_on_event_musik_gewechselt)
	pass

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	pass

func _on_event_sound_beendet(_stream: AudioStream):
	print("sound_ended")
	
func _on_event_musik_beendet(_stream: AudioStream):
	print("music_ended")
	
func _on_event_musik_gewechselt(_alter_stream: AudioStream, _neuer_stream: AudioStream):
	print("music_crossed")



func _on_play_sound_button_up() -> void:
	var index: int = %Sounds.selected
	if index >= 0:
		var path: String = %Sounds.get_item_metadata(index)
		AudioManager.play_sound(load(path))


func _on_force_sound_button_up() -> void:
	var index: int = %Sounds.selected
	if index >= 0:
		var path: String = %Sounds.get_item_metadata(index)
		AudioManager.force_play_sound(load(path))


func _on_stop_sound_button_up() -> void:
	AudioManager.stop_all_sounds()



func _on_set_music_button_up() -> void:
	var index: int = %Music.selected
	if index >= 0:
		var path: String = %Music.get_item_metadata(index)
		AudioManager.set_next_music(load(path))


func _on_fade_music_button_up() -> void:
	AudioManager.crossfade_music(%HSlider.value)


func _on_stop_music_button_up() -> void:
	AudioManager.stop_music(%HSlider.value)
