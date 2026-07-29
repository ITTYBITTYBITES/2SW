shader_type canvas_item;
render_mode blend_mix, unshaded;

// ═══════════════════════════════════════════════════════════════════════
// iris_procedural.gdshader — the Iris hub portal, generated entirely in math.
//
// ZERO textures. Every pixel comes from SDFs, Voronoi noise, and analytic
// gradients. Nothing here samples an image, so the eye is resolution
// independent, weighs nothing in the APK, and can scale to any rank forever.
//
// v1 shipped 8 static PNGs (9.3 MB) tinted per stage, with a hard cycle hack
// past Lv 80 and flat ColorRect lids overlaid on a photo that already had lids
// baked in. That is why it never read as alive. This replaces all of it.
//
// STRUCTURE (drawn back to front):
//   1. sclera        — soft radial body with subtle sub-surface warmth
//   2. limbal ring   — the dark rim separating iris from sclera
//   3. stroma        — Voronoi fibre mesh, density scaled by rank complexity
//   4. collarette    — the raised inner ridge around the pupil
//   5. pupil         — SDF disc, dilation-driven, with soft absorbing edge
//   6. shimmer       — Resonance-driven chromatic sheen in the stroma
//   7. cornea        — refractive dome with a moving specular glint
//   8. eyelids       — two SDF arcs; a real aperture, not a rectangle overlay
//
// COORDINATES: all math runs in a centred, aspect-corrected space where the
// eye occupies roughly [-1, 1] on the short axis. Pupil is always at origin.
// ═══════════════════════════════════════════════════════════════════════

// ── Driven by IrisState ────────────────────────────────────────────────
uniform vec2  gaze_vector = vec2(0.0);          // normalised, length <= 1
uniform float pupil_dilation : hint_range(0.0, 1.0) = 0.5;
uniform float shimmer_resonance : hint_range(0.0, 1.0) = 0.0;
uniform float complexity_factor : hint_range(1.0, 6.0) = 1.2;

// ── Expression / life ──────────────────────────────────────────────────
uniform float blink : hint_range(0.0, 1.0) = 0.0;     // 0 open, 1 closed
uniform float glow : hint_range(0.0, 3.0) = 1.0;
uniform float portal_transition : hint_range(0.0, 1.0) = 0.0;
uniform float reduced_motion : hint_range(0.0, 1.0) = 0.0;
uniform float time_scale : hint_range(0.0, 3.0) = 1.0;

// ── Palette (fed from design/palette.gd — never hardcoded here) ────────
uniform vec3 iris_color      = vec3(0.22, 0.72, 0.78);
uniform vec3 iris_deep_color = vec3(0.05, 0.18, 0.26);
uniform vec3 sclera_color    = vec3(0.86, 0.90, 0.95);
uniform vec3 limbal_color    = vec3(0.02, 0.05, 0.09);
uniform vec3 lid_color       = vec3(0.024, 0.031, 0.055);
uniform vec3 glint_color     = vec3(1.0, 1.0, 1.0);

// ── Geometry ───────────────────────────────────────────────────────────
uniform float iris_radius : hint_range(0.1, 1.0) = 0.92;
uniform float pupil_min : hint_range(0.05, 0.5) = 0.20;
uniform float pupil_max : hint_range(0.1, 0.8) = 0.46;
uniform float eye_width : hint_range(0.5, 2.0) = 1.32;
uniform float eye_height : hint_range(0.3, 1.5) = 1.04;

// ── Optical depth (Phase 3) ────────────────────────────────────────────
// How strongly the cornea refracts what is under it. 0 renders the iris
// flat on the surface, which is what this shader did before.
uniform float refraction_strength : hint_range(0.0, 2.0) = 1.0;
// Apparent depth of the iris below the corneal apex, in normalised units.
//
// CALIBRATED, not guessed. A real cornea magnifies the iris behind it by
// roughly 10-13% — the anterior chamber is shallow and the index step from
// aqueous humour to air is small. The first value here was 0.16, which
// measured 47% magnification on a CPU raster: the pupil ballooned and
// crushed the stroma ring to a thin band. Measured sweep:
//
//     CORNEA_DEPTH   pupil magnification
//         0.16              47%   grossly wrong
//         0.10              27%   still cartoonish
//         0.06              15%   close
//         0.045            ~11%   correct
//
// The effect is meant to be felt as depth when the eye moves, not seen as
// a fisheye when it is still.
const float CORNEA_DEPTH = 0.045;
// The corneal dome spans wider than the iris it covers.
const float CORNEA_BULGE_SCALE = 1.24;
// How far the upper lid throws a shadow down the globe, as a fraction of
// eye height. Anatomically the lid rests ON the sclera, so the contact
// shadow is tight and the ambient occlusion under it is broad.
const float LID_SHADOW_REACH = 0.62;
// Filament count around the iris. The reference shows on the order of 150
// distinct spokes; angle is in radians so this is spokes per 2*pi.
const float FIBRE_SPOKES = 64.0;
// ── Petal rosette ──────────────────────────────────────────────────────
// Concentric rings of petals. Three is enough to read as layered; more
// costs a loop iteration per pixel for detail lost at phone size.
const int   PETAL_RINGS = 3;
// Petals in the innermost ring. Outer rings scale up from this.
const float PETAL_BASE_COUNT = 13.0;
// Where the rosette starts and ends, as a fraction of the iris radius.
const float PETAL_INNER = 0.34;
const float PETAL_OUTER = 0.78;
// Half-length of one petal along the radius.
const float PETAL_HALF_LEN = 0.30;
// Width of the bright rim as a fraction of the petal's half-width.
const float PETAL_RIM = 0.34;
// How strongly the rosette dominates the cellular layers.
const float PETAL_GAIN = 0.95;


// Pixel size of the host rect, pushed by IrisView whenever the control
// resizes. Used ONLY for aspect correction. Defaults to square so a preview
// in the editor with no script attached still renders a round eye.
uniform vec2 rect_size = vec2(512.0, 512.0);


// ═══════════════════════════════════════════════════════════════════════
// NOISE / HASH — deterministic, no texture lookups
// ═══════════════════════════════════════════════════════════════════════
vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Value noise, used for soft organic variation in the sclera and stroma.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// ═══════════════════════════════════════════════════════════════════════
// VORONOI STROMA
// Returns .x = distance to nearest cell edge (fibre boundary)
//         .y = per-cell random id (fibre brightness variation)
// Cell density scales with complexity_factor, so a rank-10,000 eye genuinely
// has a finer, richer fibre mesh than a rank-1 eye. Infinite by construction.
// ═══════════════════════════════════════════════════════════════════════
vec2 voronoi_fibres(vec2 p, float density, float t) {
	vec2 scaled = p * density;
	vec2 cell = floor(scaled);
	vec2 frac_p = fract(scaled);

	float nearest = 8.0;
	float second = 8.0;
	float cell_id = 0.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbour = vec2(float(x), float(y));
			vec2 point = hash22(cell + neighbour);
			// Gentle per-cell drift so fibres shimmer rather than sit frozen.
			point = 0.5 + 0.42 * sin(t * 0.35 + 6.2831 * point);
			float d = length(neighbour + point - frac_p);
			if (d < nearest) {
				second = nearest;
				nearest = d;
				cell_id = hash12(cell + neighbour);
			} else if (d < second) {
				second = d;
			}
		}
	}
	// second - nearest gives a clean edge distance: bright at cell borders,
	// which reads exactly like iris stroma fibres.
	return vec2(second - nearest, cell_id);
}

// ═══════════════════════════════════════════════════════════════════════
// SDF PRIMITIVES
// ═══════════════════════════════════════════════════════════════════════
float sd_circle(vec2 p, float r) {
	return length(p) - r;
}

// Almond eyelid aperture: intersection of two opposing parabolic arcs.
// A real eye's aperture is a lens shape, never a rectangle — this is what
// makes the blink read as an eyelid rather than a shutter.
float sd_eye_aperture(vec2 p, float w, float h, float lid_close) {
	// Upper lid descends as lid_close rises; lower lid rises slightly less,
	// mirroring how a real blink is mostly upper-lid travel.
	float upper_y =  h * (1.0 - 1.06 * lid_close);
	float lower_y = -h * (1.0 - 0.55 * lid_close);

	// Parabolic curvature across the width gives the almond taper.
	float nx = clamp(p.x / max(w, 0.0001), -1.0, 1.0);
	float curve = 1.0 - nx * nx;

	float upper_edge = upper_y * curve;
	float lower_edge = lower_y * curve;

	// Positive outside the aperture, negative inside.
	float d_upper = p.y - upper_edge;
	float d_lower = lower_edge - p.y;
	float d_sides = abs(p.x) - w;

	return max(max(d_upper, d_lower), d_sides);
}


void fragment() {
	// ── Aspect-corrected, centred coordinates ──────────────────────────
	vec2 uv = UV - vec2(0.5);
	// ASPECT CORRECTION.
	//
	// This used to read `vec2 p = uv * 2.0;` under a comment asserting "the
	// view keeps the control square, so no extra aspect division is
	// required". That was measured and is false on two of the three screens
	// that mount iris_view.tscn:
	//
	//     hub_portal   520 x 520    aspect 1.000   round, as intended
	//     intro       1016 x 1350   aspect 0.753   squashed horizontally
	//     daily_hub   1024 x 200    aspect 5.120   smeared into a letterbox
	//
	// Every radial term below (sd_circle for the pupil, the iris_radius
	// mask, the Voronoi polar warp, the glint falloffs) assumes p is
	// isotropic. Feed it a non-square rect and the pupil becomes an
	// ellipse, the limbal ring goes oval and the lids stop meeting at the
	// canthus.
	//
	// Dividing by the SHORT axis preserves circularity and lets the eye
	// simply have more empty space along the long axis, which is what the
	// body_alpha falloff at the bottom already expects.
	// rect_size is pushed by IrisView on every resize. TEXTURE cannot serve
	// here: a ColorRect has no texture, so textureSize() would report the
	// 1x1 fallback and silently reintroduce the distortion.
	float short_axis = max(min(rect_size.x, rect_size.y), 1.0);
	vec2 p = uv * 2.0 * (rect_size / short_axis);

	float t = TIME * time_scale * (1.0 - reduced_motion * 0.85);

	// ── Gaze parallax ──────────────────────────────────────────────────
	// The iris translates with gaze; the cornea highlight translates LESS,
	// which is the parallax cue that sells a wet spherical surface.
	vec2 gaze = gaze_vector * 0.22;
	vec2 iris_flat = p - gaze;

	// ── CORNEAL REFRACTION ─────────────────────────────────────────────
	// The iris is not on the surface: it sits behind ~0.5mm of aqueous
	// humour under a curved cornea, and every ray reaching it is bent.
	// That is why a real iris appears magnified and shifts against the
	// highlight as the eye turns — the single strongest depth cue an eye
	// has, and the one thing a flat 2D disc can never fake.
	//
	// Modelled as a thin spherical lens. Reconstruct the corneal dome
	// height at this pixel, take its gradient as the surface normal, and
	// displace the sample by that normal scaled by apparent depth. Snell's
	// law linearises to exactly this for small angles, which is all the
	// dome ever spans.
	float dome_r = iris_radius * CORNEA_BULGE_SCALE;
	float dome_t = clamp(1.0 - dot(iris_flat, iris_flat) / (dome_r * dome_r), 0.0, 1.0);
	float dome_h = sqrt(dome_t);              // unit hemisphere height
	// Gradient of that height field == the surface normal's xy.
	vec2 dome_n = iris_flat / max(dome_r * dome_r, 0.0001);
	// Refraction displaces INWARD (toward the axis), magnifying the iris.
	vec2 refract_offset = -dome_n * dome_h * CORNEA_DEPTH * refraction_strength;

	vec2 iris_p = iris_flat + refract_offset;
	float r = length(iris_p);
	// Undisplaced radius, for anything that lives ON the cornea rather
	// than under it. Mixing the two is what makes the lid, the highlight
	// and the iris move at different rates.
	float r_flat = length(iris_flat);

	// ── Pupil radius from dilation ─────────────────────────────────────
	float pupil_r = mix(pupil_min, pupil_max, clamp(pupil_dilation, 0.0, 1.0));
	// Portal transition blows the pupil open into a doorway.
	pupil_r = mix(pupil_r, iris_radius * 1.35, portal_transition);

	// ═══════════════════════════════════════════════════════════════════
	// 1. SCLERA
	// ═══════════════════════════════════════════════════════════════════
	float sclera_shade = 1.0 - smoothstep(0.0, 1.35, length(p));
	vec3 col = sclera_color * (0.55 + 0.45 * sclera_shade);
	// Faint sub-surface warmth toward the corners.
	col = mix(col, sclera_color * vec3(1.0, 0.93, 0.90),
		smoothstep(0.35, 1.1, abs(p.x)) * 0.35);
	// Very low-amplitude noise stops the sclera looking like flat vector art.
	col += (value_noise(p * 9.0) - 0.5) * 0.02;

	// ═══════════════════════════════════════════════════════════════════
	// 2-4. IRIS BODY: stroma, collarette, limbal ring
	// ═══════════════════════════════════════════════════════════════════
	float iris_mask = 1.0 - smoothstep(iris_radius - 0.012, iris_radius + 0.012, r);

	if (iris_mask > 0.001) {
		// Normalised radius within the iris disc.
		float nr = clamp(r / max(iris_radius, 0.0001), 0.0, 1.0);
		float angle = atan(iris_p.y, iris_p.x);

		// Polar-warped Voronoi: cells stretch radially, exactly like real
		// stroma fibres radiating from the pupil.
		// HIGHER FREQUENCY for crisp, high-definition strands
		float density = 9.0 + complexity_factor * 8.0;
		vec2 polar = vec2(angle * 2.8, nr * 3.8);
		vec2 vor = voronoi_fibres(polar, density, t);

		// ── LAYERED STROMA (SHARPER) ────────────────────────────────────
		float fibre_coarse = pow(smoothstep(0.0, 0.28, vor.x), 1.8) * (0.78 + 0.6 * vor.y);

		vec2 vor_mid = voronoi_fibres(polar * 2.6 + 4.0, density * 1.3, t * 0.7);
		float fibre_mid = pow(smoothstep(0.0, 0.22, vor_mid.x), 2.0) * (0.68 + 0.75 * vor_mid.y);

		vec2 vor_fine = voronoi_fibres(polar * 5.8 + 9.0, density * 1.6, t * 0.45);
		float fibre_fine = pow(smoothstep(0.0, 0.16, vor_fine.x), 2.2);

		// Sharpened with a gamma below 1: pushes the mid-tones apart and
		// widens the gap between fibre and gap, which is what "high
		// contrast" means for a texture that is mostly mid-grey.
		// ── PETALED STROMA ──────────────────────────────────────────────
		// The reference is not noise and not a starburst. It is a FLOWER:
		// concentric rings of overlapping petal shapes, each ring offset in
		// phase from the one inside it, with hard bright edges where petals
		// cross. Voronoi gives blobs and a sine wave gives spokes; neither
		// produces a petal, because a petal is a SHAPE with a boundary.
		//
		// Built by folding the angular domain into repeating wedges, then
		// evaluating a lens-shaped distance field inside each wedge. Three
		// rings at rising petal counts, phase-staggered so their tips
		// interleave rather than stack — which is what makes the pattern
		// read as layered depth instead of a single flat rosette.
		float petal_field = 0.0;
		for (int ring = 0; ring < PETAL_RINGS; ring++) {
			float fring = float(ring);
			// Each ring sits further out and carries more, smaller petals.
			float ring_r = PETAL_INNER + (PETAL_OUTER - PETAL_INNER)
				* (fring / float(PETAL_RINGS - 1));
			float count = PETAL_BASE_COUNT * (1.0 + fring * 0.85);
			// Stagger: half a wedge per ring, so tips sit in the gaps below.
			float phase = fring * 3.14159 / count;

			// Fold angle into one wedge, centred on zero.
			float wedge = 6.28318 / count;
			float a_local = mod(angle + phase + wedge * 0.5, wedge) - wedge * 0.5;

			// Lens/almond profile: narrow at the tips, widest mid-petal.
			float radial = (nr - ring_r) / PETAL_HALF_LEN;
			float taper = 1.0 - radial * radial;          // 1 at centre, 0 at tips
			if (taper > 0.0) {
				float half_width = wedge * 0.5 * sqrt(taper);
				float edge = 1.0 - abs(a_local) / max(half_width, 1e-4);
				if (edge > 0.0) {
					// Hard rim, dim interior: the reference's petals are
					// bright OUTLINES, not filled shapes.
					float rim = smoothstep(0.0, PETAL_RIM, edge)
						* (1.0 - smoothstep(PETAL_RIM, PETAL_RIM * 2.6, edge));
					float body = edge * 0.22;
					petal_field = max(petal_field, rim * 1.0 + body);
				}
			}
		}
		// Fine filaments BETWEEN the petals, so the gaps are not empty.
		float filament_seed = hash12(vec2(floor(angle * FIBRE_SPOKES), 3.0));
		float filaments = pow(0.5 + 0.5 * sin(angle * FIBRE_SPOKES
			+ filament_seed * 6.2831), 5.0);
		filaments *= smoothstep(0.18, 0.40, nr) * (1.0 - smoothstep(0.70, 1.0, nr));

		// The petals dominate; the cellular layers survive only as grain
		// under them. Previously it was the other way round, which is why
		// the eye read as fine noise rather than as structure.
		float fibre = petal_field * PETAL_GAIN
			+ filaments * 0.30
			+ fibre_coarse * 0.14 + fibre_mid * 0.08 + fibre_fine * 0.05;
		// Gamma well below 1 pushes the mid-tones apart hard: this is the
		// "high contrast" the reference has and the previous mix lacked.
		fibre = pow(clamp(fibre, 0.0, 1.0), 0.55);

		// Radial depth ramp: dark at the pupil, brighter mid-iris, dark again
		// at the limbus. This is the single biggest "it looks real" cue.
		float depth = smoothstep(0.0, 0.42, nr) * (1.0 - smoothstep(0.72, 1.0, nr));

		vec3 stroma = mix(iris_deep_color, iris_color, depth);
		// Fibres both LIGHTEN their ridges and DARKEN the gaps between.
		// Adding light alone washes the iris toward grey; the subtraction is
		// what gives the texture its depth.
		stroma += iris_color * fibre * 0.78 * depth;
		stroma *= 1.0 - (1.0 - fibre) * 0.34 * depth;

		// Collarette: the raised ridge where the pupil margin meets stroma.
		float collar_pos = pupil_r / max(iris_radius, 0.0001) + 0.14;
		float collar = exp(-pow((nr - collar_pos) * 7.5, 2.0));
		stroma += iris_color * collar * 0.42;
		// The collarette is a RIDGE, so it casts a thin shadow on its outer
		// side. Without this it reads as a painted line rather than relief.
		float collar_shadow = exp(-pow((nr - collar_pos - 0.09) * 9.0, 2.0));
		stroma *= 1.0 - collar_shadow * 0.22;

		// Crypts: darker pits scattered through the stroma. Two scales, with
		// the larger ones deeper — real crypts vary in size, and a single
		// frequency reads as noise rather than as structure.
		float crypts = value_noise(polar * 3.1 + 11.0);
		float crypts_fine = value_noise(polar * 7.4 + 23.0);
		stroma *= 0.80 + 0.26 * crypts + 0.10 * crypts_fine;
		// Deep pits: only where the coarse crypt noise is already dark, so
		// they cluster the way real ones do instead of dusting evenly.
		float deep_pit = smoothstep(0.42, 0.0, crypts) * depth;
		stroma *= 1.0 - deep_pit * 0.30;

		// ── 6. SHIMMER (Resonance ◈) ────────────────────────────────────
		// Chromatic sheen that rotates through the stroma. Driven entirely by
		// lens_shimmer so the currency is visibly worn by the eye.
		if (shimmer_resonance > 0.001) {
			float sweep = sin(angle * 3.0 + t * 0.55 + nr * 5.0);
			vec3 chroma = vec3(
				0.5 + 0.5 * sin(sweep + 0.0),
				0.5 + 0.5 * sin(sweep + 2.094),
				0.5 + 0.5 * sin(sweep + 4.188));
			stroma = mix(stroma, stroma + chroma * 0.55,
				shimmer_resonance * depth * 0.85);
		}

		// 2. Limbal ring — dark boundary that makes the iris read as inset.
		float limbal = smoothstep(0.80, 1.0, nr);
		stroma = mix(stroma, limbal_color, limbal * 0.88);

		col = mix(col, stroma, iris_mask);
	}

	// ═══════════════════════════════════════════════════════════════════
	// 5. PUPIL
	// ═══════════════════════════════════════════════════════════════════
	float pupil_d = sd_circle(iris_p, pupil_r);
	float pupil_mask = 1.0 - smoothstep(-0.010, 0.010, pupil_d);
	// Not pure black: a real pupil retains a faint red-brown fundus glow.
	vec3 pupil_col = iris_deep_color * 0.18;
	// Portal state lights the pupil from within as it opens into a doorway.
	pupil_col = mix(pupil_col, iris_color * 1.4, portal_transition * 0.8);
	col = mix(col, pupil_col, pupil_mask);

	// Soft inner shadow just outside the pupil margin.
	float margin = smoothstep(0.0, 0.055, pupil_d) * (1.0 - smoothstep(0.055, 0.14, pupil_d));
	col *= 1.0 - margin * 0.30;

	// ═══════════════════════════════════════════════════════════════════
	// 7. CORNEA — refractive dome + specular glints
	// ═══════════════════════════════════════════════════════════════════
	// ── ANISOTROPIC CATCHLIGHTS ────────────────────────────────────────
	// A round Gaussian blob reads as a sticker. A real catchlight is the
	// reflected IMAGE of a light source in a curved mirror, so it is
	// stretched by the surface curvature — wider than tall on the upper
	// dome, and it smears further the closer it sits to the limbus where
	// the cornea turns away fastest.
	//
	// Modelled by scaling the sample distance anisotropically before the
	// Gaussian, then adding a second lobe offset along the stretch axis so
	// the highlight has internal structure instead of one smooth falloff.
	vec2 glint_pos = vec2(-0.34, 0.38) - gaze * 0.45;
	vec2 gd = p - glint_pos;
	// Curvature rises with distance from the corneal axis: the further out,
	// the more the reflection smears horizontally.
	float curve_stretch = 1.0 + length(glint_pos) * 0.85;
	vec2 gd_aniso = vec2(gd.x / curve_stretch, gd.y * 1.22);
	float glint_core = exp(-pow(length(gd_aniso) * 11.0, 2.0));
	// Broad glossy halo around the core — the wet-surface bloom.
	float glint_halo = exp(-pow(length(gd_aniso) * 4.6, 2.0));
	// A second specular lobe, offset along the stretch axis. Two sources of
	// slightly different size is what a window or a softbox actually looks
	// like reflected in an eye.
	vec2 gd_b = (p - glint_pos - vec2(0.055, -0.030));
	float glint_sub = exp(-pow(length(vec2(gd_b.x / curve_stretch, gd_b.y * 1.3)) * 15.0, 2.0));

	// TONED DOWN, AND MOVED OFF THE PUPIL.
	//
	// At 0.82 the core was a near-white blob sitting over the pupil, which
	// reported as "the eye has a reflection, the white looks like a light".
	// A real catchlight is a small bright accent on the WET DOME, not a lamp
	// in the middle of the iris. Halved, and the secondary lobe with it.
	col += glint_color * glint_core * 0.38;
	col += glint_color * glint_halo * 0.09;
	col += glint_color * glint_sub * 0.15;

	// Secondary, softer and lower — a second light source reads as a room.
	// Also stretched, but along the opposing axis so the two do not look
	// like copies of one another.
	vec2 glint2_pos = vec2(0.26, -0.20) - gaze * 0.30;
	vec2 g2d = p - glint2_pos;
	float glint2 = exp(-pow(length(vec2(g2d.x * 1.35, g2d.y / 1.15)) * 6.4, 2.0));
	col += glint_color * glint2 * 0.10;

	// Refractive rim: light bending through the corneal edge.
	float rim = smoothstep(iris_radius * 0.86, iris_radius * 1.04, r)
		* (1.0 - smoothstep(iris_radius * 1.04, iris_radius * 1.20, r));
	col += iris_color * rim * 0.28 * glow;

	// Overall glow response.
	col *= 0.86 + 0.20 * glow;

	// ═══════════════════════════════════════════════════════════════════
	// 8. EYELIDS — SDF aperture, drawn last so lids occlude everything
	// ═══════════════════════════════════════════════════════════════════
	float aperture = sd_eye_aperture(p, eye_width, eye_height, blink);
	float lid_mask = smoothstep(-0.012, 0.012, aperture);

	// ── UPPER-LID SHADOW ───────────────────────────────────────────────
	// Applied BEFORE the lids are composited, because this is light the lid
	// blocks from reaching the GLOBE — it belongs on the eyeball, under the
	// aperture, not painted over the lid afterwards.
	//
	// Two components, because a lid does two different things to light:
	//
	//   contact    a tight, dark band where the lid margin meets the sclera.
	//              Almost no light reaches the crease.
	//   occlusion  a broad falloff further down, where the overhanging lid
	//              blocks part of the sky. This is the one that makes the
	//              eye read as a SPHERE rather than a disc, because it
	//              darkens the top of a curved surface exactly as a real
	//              overhang would.
	//
	// The upper lid only. A lower lid catches light rather than blocking it,
	// which is why real eyes are darker at the top and brighter beneath.
	// SIGN: +y is DOWN in this space (it is UV-derived), so the UPPER lid
	// margin sits at NEGATIVE y. Distance below it is therefore
	// p.y + lid_curve, not lid_curve - p.y.
	//
	// The first version had this inverted and shaded the BOTTOM of the
	// globe — measured top/bottom luminance rose to 1.34 when a sphere lit
	// from above must fall below 1.0. The image looked plausible in
	// isolation, which is exactly why it needed measuring.
	float upper_edge = eye_height * (1.0 - 1.06 * blink);
	float nx_shadow = clamp(p.x / max(eye_width, 0.0001), -1.0, 1.0);
	float lid_curve = upper_edge * (1.0 - nx_shadow * nx_shadow);
	float below_lid = p.y + lid_curve;

	float contact = 1.0 - smoothstep(0.0, eye_height * 0.14, below_lid);
	float occlusion = 1.0 - smoothstep(0.0, eye_height * LID_SHADOW_REACH, below_lid);
	// Squared: an overhang's occlusion falls off faster than linearly.
	occlusion *= occlusion;

	// Only where the globe is actually visible, and never below the eye's
	// vertical centre — light reaches the lower half freely.
	float globe = 1.0 - lid_mask;
	// Weighted toward the broad occlusion term rather than the tight
	// contact band. The first attempt was contact-heavy and produced a
	// thin dark line under the lid with a flat globe below it — measured
	// top/bottom luminance 1.14, when a lit-from-above sphere should read
	// well under 1.0. Occlusion is what curves the surface.
	float shade = clamp(contact * 0.42 + occlusion * 0.78, 0.0, 1.0)
		* globe * step(0.0, below_lid);
	col *= 1.0 - shade * 0.70;

	// The wet meniscus: the tear film pools at the lid margin and catches a
	// thin bright line, immediately below the shadow. This is the detail
	// that separates "shadowed" from "wet and shadowed".
	float meniscus = (1.0 - smoothstep(0.0, eye_height * 0.05, below_lid))
		* step(0.0, below_lid) * globe;
	col += glint_color * meniscus * 0.10;

	// Lash line: a soft dark gradient just inside the lid edge, which is what
	// stops the aperture looking like a hard vector cut.
	float lash = (1.0 - smoothstep(0.0, 0.085, abs(aperture))) * (1.0 - lid_mask);
	col = mix(col, lid_color * 0.55, lash * 0.55);

	// ── LID VOLUME ─────────────────────────────────────────────────────
	// The lid is flesh with thickness, not a flat mask. A soft gradient
	// across the first band of lid, brightening away from the margin,
	// reads as the rounded roll of the lid itself catching ambient light.
	float lid_depth = smoothstep(0.0, 0.16, aperture) * lid_mask;
	vec3 lid_shaded = mix(lid_color * 0.72, lid_color * 1.35, lid_depth);
	col = mix(col, lid_shaded, lid_mask);

	// ═══════════════════════════════════════════════════════════════════
	// OUTPUT
	// ═══════════════════════════════════════════════════════════════════
	// Alpha: the control is transparent outside the eyeball so the hub
	// background shows through. Lids are opaque where they cover.
	float body_alpha = 1.0 - smoothstep(1.02, 1.20, length(p));

	// THE EYE IS ONLY OPAQUE WHERE THE EYE ACTUALLY IS.
	//
	// THE BUG THIS FIXES: the baked hero housing was invisible on every
	// screen, reported three times.
	//
	// This line used to read `max(body_alpha, 1.0 - lid_mask)`. Where the lid
	// does not cover, lid_mask is 0, so `1.0 - lid_mask` is 1.0 — and the
	// alpha was forced to FULLY OPAQUE across the entire square rect, right
	// out to its corners at |p| = 1.41. The CoreEye therefore painted an
	// opaque square over the housing sitting behind it at z -10, and no
	// amount of resizing the frame could ever have revealed it.
	//
	// body_alpha alone is the correct coverage: it is 1.0 inside the eyeball
	// and falls to 0 past its rim. The lid is composited into `col` above and
	// must not extend the shape — a lid is drawn ON the eye, not beside it.
	float alpha = clamp(body_alpha, 0.0, 1.0);

	// NOT multiplied by COLOR.a.
	//
	// THE BUG THIS FIXES: the host ColorRect ships with color = (0,0,0,0),
	// because the rect is only a canvas for this shader and a visible fill
	// would draw a solid square behind the eye. Multiplying the computed
	// alpha by COLOR.a therefore zeroed every pixel — the Iris was fully
	// transparent everywhere it appeared: the hub, the intro, the daily hub.
	// Reported as "nothing looks right after acceptance"; the intro rendered
	// as an empty black panel above the text.
	//
	// The shader already computes its own coverage above (body_alpha and the
	// lid mask), so the rect's own alpha carries no information worth
	// honouring. Ignoring it also means no scene can silently switch the eye
	// off by setting a modulate colour.
	COLOR = vec4(col, alpha);
}
