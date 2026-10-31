extends Control

const DEFAULT_FILE_NAME := "text.txt"

@onready var text_edit: TextEdit = $MarginContainer/VBoxContainer/TextEdit

@onready var load_btn: Button = %loadBtn
@onready var save_btn: Button = %saveBtn
@onready var save_file_dialog: FileDialog = %SAVE_FileDialog
@onready var load_file_dialog: FileDialog = %LOAD_FileDialog

var _is_web: bool = false

# Die Referenz muss gehalten werden, sonst wird der JS-Callback freigegeben.
var _web_load_callback: JavaScriptObject


func _ready() -> void:
	_is_web = OS.has_feature("web")

	if _is_web:
		# Im Browser werden die FileDialogs nicht benutzt, stattdessen
		# kommen der Datei-Dialog bzw. der Download des Browsers zum Einsatz.
		_web_load_callback = JavaScriptBridge.create_callback(_on_web_file_loaded)
		var window := JavaScriptBridge.get_interface("window")
		window.godotLoadCallback = _web_load_callback
	else:
		# Desktop: native Dialoge (unter Windows die Explorer-Dialoge).
		# Native Dialoge funktionieren nur mit Zugriff auf das Dateisystem.
		for dialog: FileDialog in [save_file_dialog, load_file_dialog]:
			dialog.access = FileDialog.ACCESS_FILESYSTEM
			dialog.use_native_dialog = true
		save_file_dialog.current_file = DEFAULT_FILE_NAME
		save_file_dialog.file_selected.connect(_on_save_file_selected)
		load_file_dialog.file_selected.connect(_on_load_file_selected)


# --------------------------------------------------------------------------
# Button-Handler (in der Szene bereits verbunden)
# --------------------------------------------------------------------------

func _on_load_btn_pressed() -> void:
	if _is_web:
		_web_open_file_dialog()
	else:
		load_file_dialog.popup_centered_ratio(0.6)


func _on_save_btn_pressed() -> void:
	if _is_web:
		_web_download_text()
	else:
		save_file_dialog.popup_centered_ratio(0.6)


# --------------------------------------------------------------------------
# Desktop
# --------------------------------------------------------------------------

func _on_save_file_selected(path: String) -> void:
	if path.get_extension().is_empty():
		path += ".txt"

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Speichern fehlgeschlagen (%s): %s" % [path, error_string(FileAccess.get_open_error())])
		return

	file.store_string(text_edit.text)
	file.close()


func _on_load_file_selected(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_error("Datei nicht gefunden: %s" % path)
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Laden fehlgeschlagen (%s): %s" % [path, error_string(FileAccess.get_open_error())])
		return

	text_edit.text = file.get_as_text()
	file.close()


# --------------------------------------------------------------------------
# Web (z.B. itch.io)
# --------------------------------------------------------------------------

# Speichern: löst einen Download im Browser aus.
func _web_download_text() -> void:
	JavaScriptBridge.download_buffer(
		text_edit.text.to_utf8_buffer(),
		DEFAULT_FILE_NAME,
		"text/plain"
	)


# Laden: öffnet den Datei-Auswahldialog des Browsers.
# Muss direkt aus dem Button-Klick heraus aufgerufen werden
# (Browser erlauben das nur nach einer Nutzeraktion).
func _web_open_file_dialog() -> void:
	JavaScriptBridge.eval("""
		(function() {
			var input = document.createElement('input');
			input.type = 'file';
			input.accept = '.txt,text/plain';
			input.style.display = 'none';
			input.addEventListener('change', function() {
				var file = input.files[0];
				if (file) {
					var reader = new FileReader();
					reader.onload = function() {
						window.godotLoadCallback(reader.result);
					};
					reader.readAsText(file);
				}
				input.remove();
			});
			document.body.appendChild(input);
			input.click();
		})();
	""", true)


# Wird vom JavaScript aufgerufen, sobald die Datei gelesen wurde.
func _on_web_file_loaded(args: Array) -> void:
	if args.size() > 0:
		text_edit.text = str(args[0])
