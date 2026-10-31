@tool
extends Node3D
## Fledermausflügel: IK-Controller + dynamische Haut.
##
## Dieses Skript gehört an den Knoten "WING". Es erwartet die Knotennamen aus
## wing_test.tscn (werden per Namen gesucht, die Hierarchie darf sich ändern).
##
## Steuerung (alles Node3D unter "Controller"):
##   WING_TARGET          Ziel für die Spitze des Leitfingers (Zeigefinger).
##   WING_DIRECTION_UP    Pol-/Up-Punkt: Die Flügelebene geht durch Schulter,
##                        Ziel und diesen Punkt. Das richtet den ganzen Flügel aus.
##   WING_CURVE_Z         Kurve 1 (skin_base_point -> END_POINT_MF): Mittelpunkt.
##                        Zählt: Position entlang der Linie + Höhe in Z (vorne).
##   WING_CURVE_TANGENT   Kind von WING_CURVE_Z: Offset = Tangente der Kurve.
##   FLESH_CURVES         Kurve 2: Ruhe-Marker (Einzug der Haut zwischen den Fingern).
##                        Werden einmalig in einen Parameter (Tiefe) umgerechnet.
##
## Annahme: Der Flügel liegt in der Ruhepose in der XY-Ebene des Knotens WING,
## die Flügelnormale ("vorne") ist +Z.

const FINGER_NAMES := ["IF", "MF", "RF", "PF"]
const PANELS := 4          # IF-MF, MF-RF, RF-PF, PF-Körper
const U_SEGS := 14         # Gitterauflösung je Hautfeld (Handgelenk -> Spitze)
const V_SEGS := 8          # Gitterauflösung je Hautfeld (Finger -> Finger)
const SPINE_SAMPLES := 9
const REST_NORMAL := Vector3.BACK


class Finger:
	var f3: Node3D      # ROTATION_POINT_xx_3 (Handgelenk)
	var f4: Node3D      # ROTATION_POINT_xx_4 (Knöchel)
	var fe: Node3D      # END_POINT_xx
	var psi1 := 0.0     # Ruhe: Richtung Segment 1 (XY-Ebene)
	var psi2 := 0.0     # Ruhe: Richtung Segment 2
	var l1 := 0.0
	var l2 := 0.0
	var c3 := 0.0       # Offset Knotenachse <-> Segmentrichtung (Gelenk 3)
	var c4 := 0.0       # dito (Gelenk 4)
	var delta := 0.0    # Ruhe: Fächerwinkel relativ zum Leitfinger
	var beta := 0.0     # Ruhe: Knick zwischen Segment 1 und 2


@export var enabled := true:
	set(value):
		enabled = value
		_refresh_active()
## Im Editor live berechnen (praktisch beim Animieren). Beim Speichern der Szene
## wird die Ruhepose automatisch wiederhergestellt.
@export var run_in_editor := true:
	set(value):
		run_in_editor = value
		_refresh_active()

@export_group("IK")
## Welcher Finger zielt auf WING_TARGET (Kette Schulter - Ellbogen - Handgelenk - Finger).
@export_enum("IF", "MF", "RF", "PF") var lead_finger := 0:
	set(value):
		lead_finger = value
		if _ready_done and _valid:
			_restore_rest()
			_capture_rest()
## Gelenkknicke (Grad) bei voller Faltung: Ellbogen, Handgelenk, Fingerknöchel.
## Abwechselnde Vorzeichen = Zickzack-Faltung (Knochen kreuzen sich nicht).
@export var fold_bends_deg := Vector3(140.0, -150.0, 120.0)
## Zusätzlicher Knick im 2. Fingerglied bei voller Faltung (Grad).
@export var finger_fold_bend_deg := 140.0
## Fächerung der Finger bei voller Faltung (1 = wie Ruhepose, 0 = alle parallel).
@export_range(0.0, 1.0, 0.01) var folded_fan_ratio := 0.12
## -1 = automatisch aus der Zielentfernung. 0..1 = Faltung fest vorgeben.
@export_range(-1.0, 1.0, 0.01) var fold_override := -1.0
## -1 = automatisch. 0..1 = Fingerspreizung fest vorgeben (animierbar).
@export_range(-1.0, 1.0, 0.01) var spread_override := -1.0
## Versatz der Finger entlang der Flügelnormale beim Falten (gegen Clipping).
@export var layer_spacing := 0.02
## Nicht-Leitfinger vom Skript steuern lassen (aus = Finger per Animation steuern).
@export var auto_fingers := true
## Daumen behält seinen Winkel relativ zum Leitfinger.
@export var thumb_follows_lead := true

@export_group("Haut")
@export var skin_enabled := true
@export var skin_shader: Shader
@export var skin_color := Color(0.16, 0.09, 0.11)
@export var skin_texture: Texture2D
## Kurve 2 aus den Markern unter FLESH_CURVES ableiten (sonst scallop_depths nehmen).
@export var use_flesh_markers := true
## Einzugstiefe der Hautkante als Anteil der Sehnenlänge.
## Reihenfolge: IF-MF, MF-RF, RF-PF, PF-skin_base.
@export var scallop_depths := PackedFloat32Array([0.13, 0.2, 0.195, 0.18])
@export_range(0.5, 4.0, 0.1) var scallop_power := 1.5
## Stärke der Aufwölbung überschüssiger Haut beim Falten.
@export_range(0.0, 2.0, 0.01) var billow := 0.8
## Stärke der Kurve 1 (WING_CURVE_Z / WING_CURVE_TANGENT).
@export_range(0.0, 3.0, 0.01) var curve_strength := 1.0

## Aktueller Faltungsgrad 0 (Ruhe/gestreckt) .. 1 (voll gefaltet), nur lesen.
var fold_amount := 0.0

var _ready_done := false
var _valid := false
var _active_prev := false

var _n_r1: Node3D
var _n_r2: Node3D
var _skin_base: Node3D
var _target: Node3D
var _up: Node3D
var _curve_z: Node3D
var _curve_tan: Node3D
var _flesh_root: Node3D
var _tf3: Node3D
var _tf4: Node3D
var _fingers: Array[Finger] = []

var _inv := Transform3D.IDENTITY
var _rest_local := {}      # Node3D -> Transform3D (lokal)
var _rest_world := {}      # Node3D -> Transform3D (im WING-Raum)
var _cur_basis := {}       # Node3D -> Basis (WING-Raum, aktueller Frame)

var _chain_len := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _chain_psi := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _chain_c := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _bends_rest := Vector3.ZERO
var _tf_delta := 0.0
var _tf_c3 := 0.0

var _last_e1 := Vector3.RIGHT
var _last_e2 := Vector3.UP

var _skin_mi: MeshInstance3D
var _mat: ShaderMaterial
var _pts := PackedVector3Array()
var _brk := PackedVector2Array()
var _sag := PackedVector3Array()
var _spine := PackedFloat32Array()
var _baked_depths := PackedFloat32Array()
var _rest_chord_a := Vector3.ZERO
var _rest_chord_b := Vector3.ZERO


# ---------------------------------------------------------------------------
# Lebenszyklus
# ---------------------------------------------------------------------------

func _ready() -> void:
	if not Engine.is_editor_hint():
		process_priority = 100   # nach AnimationPlayer & Co.
	_ready_done = true
	_pts.resize(40)
	_brk.resize(5)
	_sag.resize(PANELS)
	_spine.resize(SPINE_SAMPLES)
	_valid = _lookup_nodes()
	if not _valid:
		push_warning("BatWing: Pflicht-Knoten fehlen, Controller ist inaktiv.")
		return
	_capture_rest()
	_build_skin()
	_active_prev = _is_active()
	if _skin_mi != null:
		_skin_mi.visible = _active_prev and skin_enabled


func _process(_delta: float) -> void:
	if not _valid:
		return
	_refresh_active()
	if not _active_prev:
		return
	_solve_ik()


func _notification(what: int) -> void:
	# Im Editor soll die Szene nie mit der IK-Pose gespeichert werden.
	if what == NOTIFICATION_EDITOR_PRE_SAVE and _valid:
		_restore_rest()


func _is_active() -> bool:
	return enabled and (run_in_editor or not Engine.is_editor_hint())


func _refresh_active() -> void:
	if not _ready_done or not _valid:
		return
	var a := _is_active()
	if a != _active_prev:
		_active_prev = a
		if a:
			_capture_rest()
		else:
			_restore_rest()
	if _skin_mi != null:
		_skin_mi.visible = _active_prev and skin_enabled


# ---------------------------------------------------------------------------
# Knoten suchen & Ruhepose erfassen
# ---------------------------------------------------------------------------

func _find(nm: String, required := true) -> Node3D:
	var n := find_child(nm, true, false) as Node3D
	if n == null and required:
		push_warning("BatWing: Knoten '%s' nicht gefunden." % nm)
	return n


func _lookup_nodes() -> bool:
	_n_r1 = _find("ROTATION_POINT_1")
	_n_r2 = _find("ROTATION_POINT_2")
	_skin_base = _find("skin_base_point")
	_target = _find("WING_TARGET")
	_up = _find("WING_DIRECTION_UP")
	_curve_z = _find("WING_CURVE_Z", false)
	_curve_tan = _find("WING_CURVE_TANGENT", false)
	_flesh_root = _find("FLESH_CURVES", false)
	_tf3 = _find("ROTATION_POINT_TF_3", false)
	_tf4 = _find("ROTATION_POINT_TF_4", false)
	var ok := _n_r1 != null and _n_r2 != null and _skin_base != null and _target != null and _up != null
	_fingers.clear()
	for nm in FINGER_NAMES:
		var f := Finger.new()
		f.f3 = _find("ROTATION_POINT_%s_3" % nm)
		f.f4 = _find("ROTATION_POINT_%s_4" % nm)
		f.fe = _find("END_POINT_%s" % nm)
		ok = ok and f.f3 != null and f.f4 != null and f.fe != null
		_fingers.append(f)
	return ok


func _wp(n: Node3D) -> Vector3:
	return _inv * n.global_position


func _rw(n: Node3D) -> Transform3D:
	return _rest_world[n]


func _ang(v: Vector3) -> float:
	return atan2(v.y, v.x)


func _wrap(a: float) -> float:
	return wrapf(a, -PI, PI)


func _theta(n: Node3D) -> float:
	var b: Basis = _rw(n).basis
	return atan2(b.x.y, b.x.x)


## Muss mit allen Knoten in Ruhepose aufgerufen werden (beim Start / nach Reaktivieren).
func _capture_rest() -> void:
	_inv = global_transform.affine_inverse()
	_rest_local.clear()
	_rest_world.clear()

	var joints: Array[Node3D] = [_n_r1, _n_r2]
	for f in _fingers:
		joints.append(f.f3)
		joints.append(f.f4)
	if _tf3 != null:
		joints.append(_tf3)
	for n in joints:
		_rest_local[n] = n.transform
		_rest_world[n] = _inv * n.global_transform
	var extras: Array[Node3D] = [_skin_base]
	for f in _fingers:
		extras.append(f.fe)
	if _tf4 != null:
		extras.append(_tf4)
	for n in extras:
		_rest_world[n] = _inv * n.global_transform

	# Finger
	for f in _fingers:
		var p3 := _rw(f.f3).origin
		var p4 := _rw(f.f4).origin
		var pe := _rw(f.fe).origin
		f.psi1 = _ang(p4 - p3)
		f.psi2 = _ang(pe - p4)
		f.l1 = (p4 - p3).length()
		f.l2 = (pe - p4).length()
		f.c3 = _wrap(_theta(f.f3) - f.psi1)
		f.c4 = _wrap(_theta(f.f4) - f.psi2)
	var lead: Finger = _fingers[lead_finger]
	for f in _fingers:
		f.delta = _wrap(f.psi1 - lead.psi1)
		f.beta = _wrap(f.psi2 - f.psi1)

	# Führungskette: Schulter -> Ellbogen -> Handgelenk -> Knöchel -> Spitze
	var cn: Array[Node3D] = [_n_r1, _n_r2, lead.f3, lead.f4]
	var cp: Array[Vector3] = [
		_rw(_n_r1).origin, _rw(_n_r2).origin, _rw(lead.f3).origin,
		_rw(lead.f4).origin, _rw(lead.fe).origin,
	]
	for i in 4:
		var d := cp[i + 1] - cp[i]
		_chain_len[i] = d.length()
		_chain_psi[i] = _ang(d)
		_chain_c[i] = _wrap(_theta(cn[i]) - _chain_psi[i])
	_bends_rest = Vector3(
		_wrap(_chain_psi[1] - _chain_psi[0]),
		_wrap(_chain_psi[2] - _chain_psi[1]),
		_wrap(_chain_psi[3] - _chain_psi[2]))

	# Daumen
	if _tf3 != null and _tf4 != null:
		var psi_t := _ang(_rw(_tf4).origin - _rw(_tf3).origin)
		_tf_delta = _wrap(psi_t - lead.psi1)
		_tf_c3 = _wrap(_theta(_tf3) - psi_t)

	# Haut-Ruhedaten
	_fill_pts(0)
	_compute_brk()
	_rest_chord_a = _tip(0, 4)
	_rest_chord_b = _tip(0, 1)
	_bake_depths()
	if _mat != null:
		_mat.set_shader_parameter("brk", _brk)


func _restore_rest() -> void:
	for n in _rest_local:
		if is_instance_valid(n):
			n.transform = _rest_local[n]


# ---------------------------------------------------------------------------
# IK
# ---------------------------------------------------------------------------

func _bends(lam: float) -> Vector3:
	if lam >= 0.0:
		var fold := Vector3(
			deg_to_rad(fold_bends_deg.x),
			deg_to_rad(fold_bends_deg.y),
			deg_to_rad(fold_bends_deg.z))
		return _bends_rest.lerp(fold, lam)
	return _bends_rest * (1.0 + lam)


func _chain_angles(b: Vector3, phi: float) -> PackedFloat32Array:
	return PackedFloat32Array([phi, phi + b.x, phi + b.x + b.y, phi + b.x + b.y + b.z])


func _chain_points(angles: PackedFloat32Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var p := Vector2.ZERO
	pts.append(p)
	for i in 4:
		p += Vector2.from_angle(angles[i]) * _chain_len[i]
		pts.append(p)
	return pts


func _chain_dist(lam: float) -> float:
	var pts := _chain_points(_chain_angles(_bends(lam), 0.0))
	return pts[4].length()


func _any_perp(e1: Vector3) -> Vector3:
	var r := e1.cross(Vector3.UP)
	if r.length_squared() < 1e-6:
		r = e1.cross(Vector3.RIGHT)
	return r.normalized()


func _parent_basis(n: Node3D) -> Basis:
	var p := n.get_parent() as Node3D
	if p == null or p == self:
		return Basis.IDENTITY
	if _cur_basis.has(p):
		return _cur_basis[p]
	var t: Transform3D = _inv * p.global_transform
	return t.basis.orthonormalized()


## Setzt die Basis eines Gelenks (im WING-Raum) über seine lokale Transformation.
func _set_wing_basis(n: Node3D, b: Basis, offset := Vector3.ZERO) -> void:
	var pb := _parent_basis(n)
	var rest: Transform3D = _rest_local[n]
	var t := rest
	t.basis = pb.inverse() * b
	t.origin = rest.origin + pb.inverse() * offset
	n.transform = t
	_cur_basis[n] = b


func _solve_ik() -> void:
	_inv = global_transform.affine_inverse()
	_cur_basis.clear()

	var s_pos := _wp(_n_r1)
	var to_t := _wp(_target) - s_pos
	var dist := to_t.length()

	# Ebene: Schulter, Ziel, Pol
	var e1 := _last_e1
	if dist > 1e-5:
		e1 = to_t / dist
	var up_vec := _wp(_up) - s_pos
	up_vec -= e1 * up_vec.dot(e1)
	var e2 := _last_e2 - e1 * _last_e2.dot(e1)
	if up_vec.length_squared() > 1e-10:
		e2 = up_vec
	if e2.length_squared() < 1e-10:
		e2 = _any_perp(e1)
	e2 = e2.normalized()
	var e3 := e1.cross(e2)
	_last_e1 = e1
	_last_e2 = e2
	var frame := Basis(e1, e2, e3)

	# Faltungsparameter lambda: -1 gestreckt, 0 Ruhe, +1 voll gefaltet
	var lam := 0.0
	if fold_override >= 0.0:
		lam = clampf(fold_override, 0.0, 1.0)
	else:
		if dist >= _chain_dist(-1.0):
			lam = -1.0
		elif dist <= _chain_dist(1.0):
			lam = 1.0
		else:
			var lo := -1.0
			var hi := 1.0
			for _i in 32:
				var mid := 0.5 * (lo + hi)
				if _chain_dist(mid) > dist:
					lo = mid
				else:
					hi = mid
			lam = 0.5 * (lo + hi)
	fold_amount = clampf(lam, 0.0, 1.0)

	# Kette in der Ebene lösen und Spitze auf die Zielachse (e1) drehen
	var bends := _bends(lam)
	var tip := _chain_points(_chain_angles(bends, 0.0))[4]
	var phi := -tip.angle()
	var angles := _chain_angles(bends, phi)

	var lead: Finger = _fingers[lead_finger]
	var cn: Array[Node3D] = [_n_r1, _n_r2, lead.f3, lead.f4]
	for i in 4:
		_set_wing_basis(cn[i], frame * Basis(REST_NORMAL, angles[i] + _chain_c[i]))

	# Fingerspreizung
	var s := 1.0 - smoothstep(0.0, 1.0, clampf(lam, 0.0, 1.0))
	if spread_override >= 0.0:
		s = clampf(spread_override, 0.0, 1.0)
	var lead_psi1 := angles[2]

	if auto_fingers:
		var fan_k := folded_fan_ratio + (1.0 - folded_fan_ratio) * s
		var ff := deg_to_rad(finger_fold_bend_deg)
		for i in _fingers.size():
			if i == lead_finger:
				continue
			var f: Finger = _fingers[i]
			var a1 := lead_psi1 + f.delta * fan_k
			var a2 := a1 + lerpf(f.beta + ff, f.beta, s)
			var off := -e3 * (layer_spacing * float(absi(i - lead_finger)) * (1.0 - s))
			_set_wing_basis(f.f3, frame * Basis(REST_NORMAL, a1 + f.c3), off)
			_set_wing_basis(f.f4, frame * Basis(REST_NORMAL, a2 + f.c4))

	if _tf3 != null and _tf4 != null:
		if thumb_follows_lead:
			_set_wing_basis(_tf3, frame * Basis(REST_NORMAL, lead_psi1 + _tf_delta + _tf_c3))
		else:
			_tf3.transform = _rest_local[_tf3]

	if _skin_mi != null and skin_enabled:
		_update_skin(e3)


# ---------------------------------------------------------------------------
# Haut
# ---------------------------------------------------------------------------

func _tip(base: int, k: int) -> Vector3:
	if k < 4:
		return _pts[base + k * 4 + 2]
	return _pts[base + 16 + 3]


func _fill_pts(base: int) -> void:
	for i in 4:
		var f: Finger = _fingers[i]
		var a := _wp(f.f3)
		var b := _wp(f.f4)
		var c := _wp(f.fe)
		var o := base + i * 4
		_pts[o] = a
		_pts[o + 1] = b
		_pts[o + 2] = c
		_pts[o + 3] = c
	var ob := base + 16
	_pts[ob] = _wp((_fingers[3] as Finger).f3)
	_pts[ob + 1] = _wp(_n_r2)
	_pts[ob + 2] = _wp(_n_r1)
	_pts[ob + 3] = _wp(_skin_base)


func _compute_brk() -> void:
	for k in 5:
		var o := k * 4
		var l1 := (_pts[o + 1] - _pts[o]).length()
		var l2 := (_pts[o + 2] - _pts[o + 1]).length()
		if k < 4:
			_brk[k] = Vector2(l1 / maxf(l1 + l2, 1e-6), 1.0)
		else:
			var l3 := (_pts[o + 3] - _pts[o + 2]).length()
			var tot := maxf(l1 + l2 + l3, 1e-6)
			_brk[k] = Vector2(l1 / tot, (l1 + l2) / tot)


## Gegenstück zu path_pos() im Shader (nur für die Ruhe-Vertices).
func _path_pos(base: int, k: int, u: float) -> Vector3:
	var i := base + k * 4
	var u1 := _brk[k].x
	var u2 := _brk[k].y
	if u <= u1:
		return _pts[i].lerp(_pts[i + 1], u / maxf(u1, 1e-5))
	elif u <= u2:
		return _pts[i + 1].lerp(_pts[i + 2], (u - u1) / maxf(u2 - u1, 1e-5))
	return _pts[i + 2].lerp(_pts[i + 3], clampf((u - u2) / maxf(1.0 - u2, 1e-5), 0.0, 1.0))


func _rest_surface(panel: int, u: float, v: float) -> Vector3:
	return _path_pos(0, panel, u).lerp(_path_pos(0, panel + 1, u), v)


## Kurve 2: Marker unter FLESH_CURVES (Reihenfolge Körper -> Spitze) in Tiefen umrechnen.
func _bake_depths() -> void:
	_baked_depths = PackedFloat32Array()
	if _flesh_root == null:
		return
	var markers: Array[Node3D] = []
	for node in _flesh_root.get_children():
		if node is Node3D:
			markers.append(node as Node3D)
	if markers.size() < PANELS:
		return
	var wrist := _pts[0]
	for p in PANELS:
		var a := _tip(0, p)
		var b := _tip(0, p + 1)
		var ch := b - a
		var chord_len := ch.length()
		if chord_len < 1e-5:
			_baked_depths = PackedFloat32Array()
			return
		var c := ch / chord_len
		var inward := wrist - (a + b) * 0.5
		inward -= c * inward.dot(c)
		if inward.length_squared() < 1e-10:
			_baked_depths = PackedFloat32Array()
			return
		inward = inward.normalized()
		var q := _wp(markers[PANELS - 1 - p])
		_baked_depths.append((q - (a + b) * 0.5).dot(inward) / chord_len)


func _get_depth(p: int) -> float:
	if use_flesh_markers and _baked_depths.size() == PANELS:
		return _baked_depths[p]
	if p < scallop_depths.size():
		return scallop_depths[p]
	return 0.18


func _bez(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)


## Kurve 1: Höhenprofil (Z = vorne) entlang skin_base -> END_POINT_MF.
## Koordinaten sind auf die Ruhe-Sehnenlänge normiert, damit die Kurve mit dem
## Flügel mitskaliert.
func _compute_spine(cur_len: float) -> void:
	for k in SPINE_SAMPLES:
		_spine[k] = 0.0
	if _curve_z == null:
		return
	var ab := _rest_chord_b - _rest_chord_a
	var l_r := ab.length()
	if l_r < 1e-5:
		return
	var c_r := ab / l_r
	var zc := _wp(_curve_z)
	var rel := zc - _rest_chord_a
	var a := clampf(rel.dot(c_r) / l_r, 0.05, 0.95)
	var h := rel.dot(REST_NORMAL) / l_r
	var tx := 0.0
	var tz := 0.0
	if _curve_tan != null:
		var tau := _wp(_curve_tan) - zc
		tx = tau.dot(c_r) / l_r
		tz = tau.dot(REST_NORMAL) / l_r
	if Vector2(tx, tz).length() < 1e-4:
		tx = minf(a, 1.0 - a) * 0.66   # automatische, waagerechte Tangente
		tz = 0.0

	var m := Vector2(a, h)
	var tau2 := Vector2(tx, tz)
	var p0 := Vector2.ZERO
	var p3 := Vector2(1.0, 0.0)
	var xs := PackedFloat32Array()
	var zs := PackedFloat32Array()
	for seg in 2:
		for j in 9:
			if seg == 1 and j == 0:
				continue
			var t := float(j) / 8.0
			var q: Vector2
			if seg == 0:
				q = _bez(p0, p0 + (m - p0) / 3.0, m - tau2, m, t)
			else:
				q = _bez(m, m + tau2, p3 + (m - p3) / 3.0, p3, t)
			xs.append(q.x)
			zs.append(q.y)
	for k in SPINE_SAMPLES:
		var x := float(k) / float(SPINE_SAMPLES - 1)
		var hv := 0.0
		for j in xs.size() - 1:
			if xs[j + 1] > xs[j] and x >= xs[j] and x <= xs[j + 1]:
				hv = lerpf(zs[j], zs[j + 1], inverse_lerp(xs[j], xs[j + 1], x))
				break
		_spine[k] = hv * curve_strength * cur_len


func _update_skin(e3: Vector3) -> void:
	_fill_pts(20)

	# Kurve 2: Einzug je Hautfeld
	var wrist := _pts[20]
	for p in PANELS:
		var a := _tip(20, p)
		var b := _tip(20, p + 1)
		var ch := b - a
		var chord_len := ch.length()
		var sag := Vector3.ZERO
		if chord_len > 1e-5:
			var c := ch / chord_len
			var inward := wrist - (a + b) * 0.5
			inward -= c * inward.dot(c)
			if inward.length_squared() > 1e-10:
				sag = inward.normalized() * (_get_depth(p) * chord_len)
		_sag[p] = sag

	# Kurve 1
	var chord_a := _tip(20, 4)
	var chord_ab := _tip(20, 1) - chord_a
	_compute_spine(chord_ab.length())

	_mat.set_shader_parameter("pts", _pts)
	_mat.set_shader_parameter("sag", _sag)
	_mat.set_shader_parameter("plane_n", e3)
	_mat.set_shader_parameter("chord_a", chord_a)
	_mat.set_shader_parameter("chord_ab", chord_ab)
	_mat.set_shader_parameter("spine_h", _spine)
	_mat.set_shader_parameter("billow", billow)
	_mat.set_shader_parameter("scallop_pow", scallop_power)
	_mat.set_shader_parameter("albedo", skin_color)
	if skin_texture != null:
		_mat.set_shader_parameter("albedo_tex", skin_texture)


## Baut das Mesh genau einmal. Danach ändert sich nur noch die Shader-Parametrierung.
func _build_skin() -> void:
	for c in get_children(true):
		if c.name == &"_WingSkin":
			remove_child(c)
			c.free()

	var sh := skin_shader
	if sh == null:
		var path := (get_script() as Script).resource_path.get_base_dir().path_join("bat_wing_skin.gdshader")
		sh = load(path) as Shader
	if sh == null:
		push_error("BatWing: bat_wing_skin.gdshader nicht gefunden (Export 'skin_shader' setzen).")
		return
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("pts", _pts)
	_mat.set_shader_parameter("brk", _brk)
	_mat.set_shader_parameter("billow_sign", PackedFloat32Array([1.0, -1.0, 1.0, -1.0]))

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	for panel in PANELS:
		var base := verts.size()
		for i in range(U_SEGS + 1):
			for j in range(V_SEGS + 1):
				var u := float(i) / float(U_SEGS)
				var v := float(j) / float(V_SEGS)
				verts.append(_rest_surface(panel, u, v))
				norms.append(REST_NORMAL)
				uv.append(Vector2(u, v))
				uv2.append(Vector2(float(panel), 0.0))
		for i in range(U_SEGS):
			for j in range(V_SEGS):
				var a := base + i * (V_SEGS + 1) + j
				var b := base + (i + 1) * (V_SEGS + 1) + j
				var c := a + 1
				var d := b + 1
				idx.append_array(PackedInt32Array([a, b, c, b, d, c]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_skin_mi = MeshInstance3D.new()
	_skin_mi.name = &"_WingSkin"
	_skin_mi.mesh = mesh
	_skin_mi.material_override = _mat
	# Die Form wird im Shader verformt -> Culling-Box großzügig setzen.
	_skin_mi.custom_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	_skin_mi.extra_cull_margin = 4.0
	add_child(_skin_mi, false, Node.INTERNAL_MODE_FRONT)
