extends Node
## Durchsucht rekursiv einen Ordner nach .wav-Dateien und sortiert sie
## anhand von Dateiname/Ordnerpfad in Music (%Music) und Sounds (%Sounds).
##
## Music = Dateiname ODER Ordnerpfad enthält "ambient" oder "loop" (Groß-/
## Kleinschreibung wird ignoriert).
## Alle übrigen .wav-Dateien landen bei Sounds.

## Startordner der Suche (res:// oder user://, je nach Bedarf anpassen)
@export var search_path: String = "res://res/"

@onready var music_button: OptionButton = %Music
@onready var sounds_button: OptionButton = %Sounds


func _ready() -> void:
	#music_button.item_selected.connect(_on_music_selected)
	#sounds_button.item_selected.connect(_on_sounds_selected)
	_populate_lists()


func _populate_lists() -> void:
	music_button.clear()
	sounds_button.clear()
	_scan_directory(search_path)


func _scan_directory(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		push_error("Konnte Ordner nicht öffnen: %s (Fehler: %s)" % [path, DirAccess.get_open_error()])
		return

	dir.list_dir_begin()
	var entry_name := dir.get_next()

	while entry_name != "":
		var full_path := path.path_join(entry_name)

		if dir.current_is_dir():
			_scan_directory(full_path)  # rekursiv in jeden Unterordner
		elif entry_name.get_extension().to_lower() == "wav":
			_add_wav_entry(full_path, entry_name)

		entry_name = dir.get_next()

	dir.list_dir_end()


func _add_wav_entry(full_path: String, file_name: String) -> void:
	var target_button := music_button if _is_music(full_path) else sounds_button

	var idx := target_button.item_count
	target_button.add_item(file_name)
	# Vollständigen Pfad als Metadaten am Eintrag hinterlegen,
	# damit er beim Auswählen sofort geladen werden kann.
	target_button.set_item_metadata(idx, full_path)


func _is_music(full_path: String) -> bool:
	var lower_path := full_path.to_lower()
	return lower_path.contains("ambient") or lower_path.contains("loop")

# nope
func _on_music_selected(index: int) -> void:
	var path: String = music_button.get_item_metadata(index)
	AudioManager.set_next_music(load(path))

# nope
func _on_sounds_selected(index: int) -> void:
	var path: String = sounds_button.get_item_metadata(index)
	# Beispiel — an die tatsächliche Sound-API von AudioManager anpassen:
	AudioManager.play_sound(load(path))
