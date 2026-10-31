extends Node
## AudioManager.gd
## Autoload-Singleton für Sound-Effekte (begrenzter Pool) und Musik
## (zwei Kanäle mit sanftem Überblenden / Crossfade).
##
## Registrierung: Project Settings -> Autoload -> Pfad zu diesem Skript,
## Name z.B. "AudioManager".
##
## Erwartet zwei Audio-Busse in der Audio Bus Layout: "SFX" und "Music"
## (Namen unten über sound_bus / musik_bus anpassbar).


# ==================================================================
# SIGNALE
# ==================================================================

## Ein einzelner Sound-Effekt wurde vollständig (natürlich) zu Ende gespielt.
signal sound_beendet(stream: AudioStream)

## Die aktive Musik wurde gestoppt (nach abgeschlossenem Ausklingen).
signal musik_beendet(stream: AudioStream)

## Ein Musik-Crossfade wurde erfolgreich abgeschlossen.
signal musik_gewechselt(alter_stream: AudioStream, neuer_stream: AudioStream)


# ==================================================================
# KONFIGURATION
# ==================================================================

@export var max_gleichzeitige_sounds: int = 8
@export var sound_bus: String = "SFX"
@export var musik_bus: String = "Music"
@export var ueberblenddauer: float = 1.5   ## Standard-Dauer für crossfade_music()
@export var ausklingdauer: float = 1.0     ## Standard-Dauer für stop_music()

@export var min_sound_db:float = -30.0

# ==================================================================
# SOUND-EFFEKTE (Pool mit fixer Größe)
# ==================================================================

var _sound_spieler: Array[AudioStreamPlayer] = []
var _aktive_sounds: Array[AudioStreamPlayer] = []   # älteste zuerst -> für erzwungenes Stoppen


# ==================================================================
# MUSIK (zwei Kanäle für sanftes Umschalten)
# ==================================================================

var _musik_spieler: Array[AudioStreamPlayer] = []
var _aktiver_musik_kanal: int = 0
var _naechste_musik: AudioStream = null
var _musik_soll_loopen: Array[bool] = [true, true]
var _musik_tween: Tween = null
var _ausklingen_tween: Tween = null


func _ready() -> void:
	_sound_pool_aufbauen()
	_musik_kanaele_aufbauen()


# ==================================================================
# SETUP
# ==================================================================

func _sound_pool_aufbauen() -> void:
	for i in range(max_gleichzeitige_sounds):
		var spieler := AudioStreamPlayer.new()
		spieler.name = "SoundSlot_%d" % i
		spieler.bus = sound_bus
		add_child(spieler)
		spieler.finished.connect(_on_sound_finished.bind(spieler))
		_sound_spieler.append(spieler)


func _musik_kanaele_aufbauen() -> void:
	for i in range(2):
		var spieler := AudioStreamPlayer.new()
		spieler.name = "MusikKanal_%d" % i
		spieler.bus = musik_bus
		add_child(spieler)
		spieler.finished.connect(_on_music_player_finished.bind(i))
		_musik_spieler.append(spieler)


# ==================================================================
# SOUND-EFFEKTE — API
# ==================================================================

## Spielt einen Sound ab, falls ein freier Slot verfügbar ist.
## Gibt den benutzten AudioStreamPlayer zurück, oder null falls der Pool voll ist.
func play_sound(stream: AudioStream, volume_db: float = 0.0, pitch_scale: float = 1.0) -> AudioStreamPlayer:
	var spieler := _freien_sound_slot_finden()
	if spieler == null:
		return null
	_sound_starten(spieler, stream, volume_db, pitch_scale)
	return spieler


## Spielt einen Sound garantiert ab. Ist der Pool voll, wird der älteste
## aktive Sound sofort gestoppt und dessen Slot wiederverwendet.
func force_play_sound(stream: AudioStream, volume_db: float = 0.0, pitch_scale: float = 1.0) -> AudioStreamPlayer:
	var spieler := _freien_sound_slot_finden()
	if spieler == null:
		spieler = _aeltesten_sound_stoppen()
	_sound_starten(spieler, stream, volume_db, pitch_scale)
	return spieler


## Stoppt sofort alle aktuell aktiven Sound-Effekte (Musik bleibt unberührt).
func stop_all_sounds() -> void:
	for spieler in _sound_spieler:
		if spieler.playing:
			spieler.stop()
	_aktive_sounds.clear()


func has_free_sound_slot() -> bool:
	return _freien_sound_slot_finden() != null


func _freien_sound_slot_finden() -> AudioStreamPlayer:
	for spieler in _sound_spieler:
		if not spieler.playing:
			return spieler
	return null


func _aeltesten_sound_stoppen() -> AudioStreamPlayer:
	var spieler: AudioStreamPlayer = _aktive_sounds.pop_front()
	spieler.stop()
	return spieler


func _sound_starten(spieler: AudioStreamPlayer, stream: AudioStream, volume_db: float, pitch_scale: float) -> void:
	_aktive_sounds.erase(spieler)
	spieler.stream = stream
	spieler.volume_db = volume_db
	spieler.pitch_scale = pitch_scale
	spieler.play()
	_aktive_sounds.append(spieler)


func _on_sound_finished(spieler: AudioStreamPlayer) -> void:
	_aktive_sounds.erase(spieler)
	sound_beendet.emit(spieler.stream)


# ==================================================================
# MUSIK — API
# ==================================================================

## Legt fest, welcher Stream beim nächsten crossfade_music()-Aufruf
## eingeblendet wird. Spielt selbst noch nichts ab.
func set_next_music(stream: AudioStream) -> void:
	_naechste_musik = stream


## Blendet sanft von der aktuellen Musik auf die zuvor per set_next_music()
## gesetzte Musik über (läuft auf dem jeweils anderen Kanal, damit sich
## beide Stücke kurz überlagern). fade_time < 0 verwendet ueberblenddauer.
func crossfade_music(fade_time: float = -1.0) -> void:
	if _naechste_musik == null:
		push_warning("AudioManager: crossfade_music() ohne vorheriges set_next_music() aufgerufen.")
		return

	var dauer := fade_time if fade_time >= 0.0 else ueberblenddauer

	if _musik_tween and _musik_tween.is_valid():
		_musik_tween.kill()
	if _ausklingen_tween and _ausklingen_tween.is_valid():
		_ausklingen_tween.kill()

	var alter_kanal := _aktiver_musik_kanal
	var alter_spieler := _musik_spieler[alter_kanal]
	var alter_stream := alter_spieler.stream
	var alter_lief := alter_spieler.playing

	var neuer_kanal := 1 - alter_kanal
	var neuer_spieler := _musik_spieler[neuer_kanal]
	var neuer_stream := _naechste_musik

	_musik_soll_loopen[alter_kanal] = false
	_musik_soll_loopen[neuer_kanal] = true

	neuer_spieler.stream = neuer_stream
	neuer_spieler.volume_db = min_sound_db
	neuer_spieler.play()
	#neuer_spieler.finished.connect(_in_debug)

	_musik_tween = create_tween()
	_musik_tween.set_parallel(true)
	_musik_tween.tween_property(neuer_spieler, "volume_db", 0.0, dauer)
	if alter_lief:
		_musik_tween.tween_property(alter_spieler, "volume_db", min_sound_db, dauer)
	_musik_tween.set_parallel(false)
	_musik_tween.tween_callback(_on_crossfade_fertig.bind(alter_spieler, alter_stream, neuer_stream))

	_naechste_musik = null
	_aktiver_musik_kanal = neuer_kanal

func _in_debug():
	print("AAAAAAAAAAAAAAAA")




func _on_crossfade_fertig(alter_spieler: AudioStreamPlayer, alter_stream: AudioStream, neuer_stream: AudioStream) -> void:
	if alter_spieler.playing:
		alter_spieler.stop()
	alter_spieler.volume_db = 0.0
	musik_gewechselt.emit(alter_stream, neuer_stream)


## Blendet die aktuell laufende Musik aus und stoppt sie danach.
## fade_time < 0 verwendet ausklingdauer.
func stop_music(fade_time: float = -1.0) -> void:
	if _musik_tween and _musik_tween.is_valid():
		_musik_tween.kill()
		_musik_tween = null
	if _ausklingen_tween and _ausklingen_tween.is_valid():
		_ausklingen_tween.kill()

	var spieler := _musik_spieler[_aktiver_musik_kanal]
	if not spieler.playing:
		return

	var stream := spieler.stream
	var dauer := fade_time if fade_time >= 0.0 else ausklingdauer
	_musik_soll_loopen[_aktiver_musik_kanal] = false

	_ausklingen_tween = create_tween()
	_ausklingen_tween.tween_property(spieler, "volume_db", min_sound_db, dauer)
	_ausklingen_tween.tween_callback(func():
		spieler.stop()
		spieler.volume_db = 0.0
		musik_beendet.emit(stream)
	)


func get_active_music_stream() -> AudioStream:
	return _musik_spieler[_aktiver_musik_kanal].stream


func _on_music_player_finished(kanal_index: int) -> void:
	# Wird nur bei Streams ohne eigenes Loop-Flag im Import ausgelöst.
	# Läuft der Stream intern bereits geloopt, feuert "finished" gar nicht erst.
	if _musik_soll_loopen[kanal_index]:
		_musik_spieler[kanal_index].play()
