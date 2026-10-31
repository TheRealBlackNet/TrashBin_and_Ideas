shader_type spatial;
render_mode cull_disabled;

// ---------------------------------------------------------------------------
// Fledermausflügel-Haut: Das Mesh wird EINMAL gebaut (Gitter je Hautfeld) und
// verändert sich danach nie. Jede Frame schiebt bat_wing.gd nur ein paar
// Kontrollpunkte als Uniforms herein; die Verformung passiert hier im
// Vertex-Shader.
//
// Mesh-Attribute:
//   UV  = (u, v)     u: vom Handgelenk zur Spitze, v: von Finger a zu Finger b
//   UV2 = (panel, 0) Hautfeld 0..3 (IF-MF, MF-RF, RF-PF, PF-Körper)
//   VERTEX = Ruhepose (wird nur für die Texturkoordinaten benutzt)
// ---------------------------------------------------------------------------

// 5 Pfade à 4 Punkte: IF, MF, RF, PF, KÖRPER (Handgelenk -> Ellbogen -> Schulter -> skin_base)
// [0..19] = Ruhepose, [20..39] = aktuelle Pose
uniform vec3 pts[40];
// Knickpunkte (Bogenlängenanteil) je Pfad
uniform vec2 brk[5];
// Einzug der Hautkante zwischen den Fingerspitzen (Vektor Sehnenmitte -> tiefster Punkt)
uniform vec3 sag[4];
// Aufwölbung bei Faltung: Richtung je Hautfeld (+1 vorne / -1 hinten)
uniform float billow_sign[4];
// Flügelnormale ("nach vorne")
uniform vec3 plane_n;
// Kurve 1 (skin_base -> END_POINT_MF): Sehne + Höhenprofil entlang der Normalen
uniform vec3 chord_a;
uniform vec3 chord_ab;
uniform float spine_h[9];

uniform float billow = 0.8;
uniform float scallop_pow = 1.5;

uniform vec4 albedo : source_color = vec4(0.16, 0.09, 0.11, 1.0);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float uv_scale = 0.25;
uniform float vein_strength = 0.35;

varying vec2 vuv;

vec3 path_pos(int base, int k, float u) {
	int i = base + k * 4;
	vec3 a = pts[i];
	vec3 b = pts[i + 1];
	vec3 c = pts[i + 2];
	vec3 d = pts[i + 3];
	float u1 = brk[k].x;
	float u2 = brk[k].y;
	if (u <= u1) {
		return mix(a, b, u / max(u1, 1e-5));
	} else if (u <= u2) {
		return mix(b, c, (u - u1) / max(u2 - u1, 1e-5));
	}
	return mix(c, d, clamp((u - u2) / max(1.0 - u2, 1e-5), 0.0, 1.0));
}

vec3 skin(int panel, float u, float v) {
	vec3 a = path_pos(20, panel, u);
	vec3 b = path_pos(20, panel + 1, u);
	vec3 p = mix(a, b, v);
	float bub = 4.0 * v * (1.0 - v); // 0 an den Knochen, 1 in der Feldmitte

	// Kurve 2: Haut zieht sich zwischen den Fingerspitzen ein
	p += sag[panel] * bub * pow(max(u, 1e-4), scallop_pow);

	// Faltung: Überschüssige Haut wölbt sich aus der Ebene, statt zu clippen
	vec3 a0 = path_pos(0, panel, u);
	vec3 b0 = path_pos(0, panel + 1, u);
	float w0 = distance(a0, b0);
	float w1 = distance(a, b);
	float slack = max(w0 * w0 - w1 * w1, 0.0);
	p += plane_n * billow_sign[panel] * billow * 0.5 * sqrt(slack) * bub;

	// Kurve 1: Höhenprofil entlang der Linie skin_base -> END_POINT_MF
	float t = clamp(dot(p - chord_a, chord_ab) / max(dot(chord_ab, chord_ab), 1e-6), 0.0, 1.0);
	float f = t * 8.0;
	int i0 = int(floor(f));
	int i1 = min(i0 + 1, 8);
	float h = mix(spine_h[i0], spine_h[i1], f - float(i0));
	p += plane_n * h * bub * smoothstep(0.0, 0.4, u);

	return p;
}

void vertex() {
	int panel = int(UV2.x + 0.5);
	float u = UV.x;
	float v = UV.y;
	vuv = vec2(u, v);

	// Textur klebt an der Ruhepose: Dehnung/Stauchung beim Falten wird sichtbar
	UV = VERTEX.xy * uv_scale + vec2(0.5);

	float e = 0.04;
	vec3 p = skin(panel, u, v);
	vec3 du = skin(panel, min(u + e, 1.0), v) - skin(panel, max(u - e, 0.0), v);
	vec3 dv = skin(panel, u, min(v + e, 1.0)) - skin(panel, u, max(v - e, 0.0));
	vec3 n = cross(dv, du);
	float nl = length(n);

	VERTEX = p;
	NORMAL = nl > 1e-9 ? n / nl : plane_n;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	float edge = min(vuv.y, 1.0 - vuv.y);
	float vein = 1.0 - vein_strength * (1.0 - smoothstep(0.0, 0.12, edge));
	ALBEDO = albedo.rgb * tex.rgb * vein;
	ROUGHNESS = 0.75;
	BACKLIGHT = albedo.rgb * 0.5;
}
