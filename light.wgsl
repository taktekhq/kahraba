// Lights the street. The script hands over two pictures of the same frame:
// albedo (what things are made of; where it is transparent, that is sky) and
// emission (what glows). Here they meet the city's glow,
// moonlight, the spill from lit windows, your phone torch, fog and grain.

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

struct U {
    res: vec2<f32>,
    torch: vec2<f32>,
    time: f32,
    dark: f32,     // 0 lit street .. 1 power cut
    torchOn: f32,  // 0..1
    reach: f32,    // torch radius in pixels
    lights: f32,   // window light level
    fog: f32,      // fog density
    shock: f32,    // a jinn was caught / the battery died
    battery: f32,  // 0..1
    scale: f32,    // design units to pixels
    dead: f32,     // the battery is dead
    rumble: f32,   // the moteur is running
    horizon: f32,  // horizon line, pixels from the top
    moon: vec2<f32>,
    pad0: f32,
    pad1: f32,
};

@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var albedoTex: texture_2d<f32>;
@group(0) @binding(2) var emitTex: texture_2d<f32>;
@group(0) @binding(3) var glowTex: texture_2d<f32>;
@group(0) @binding(4) var samp: sampler;

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    var pos = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    let p = pos[idx];
    var out: VertexOutput;
    out.position = vec4<f32>(p, 0.0, 1.0);
    out.uv = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

fn hash2(p: vec2<f32>) -> f32 {
    let h = dot(p, vec2<f32>(127.1, 311.7));
    return fract(sin(h) * 43758.5453);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let a = hash2(i);
    let b = hash2(i + vec2<f32>(1.0, 0.0));
    let c = hash2(i + vec2<f32>(0.0, 1.0));
    let d = hash2(i + vec2<f32>(1.0, 1.0));
    let w = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

fn fbm(p0: vec2<f32>) -> f32 {
    var p = p0;
    var v = 0.0;
    var a = 0.5;
    for (var i = 0; i < 5; i = i + 1) {
        v = v + a * noise(p);
        p = p * 2.03 + vec2<f32>(17.0, 9.0);
        a = a * 0.5;
    }
    return v;
}

// Soft glow: the feathered quarter-size emission, widened over a ring of taps.
fn glow(uv: vec2<f32>, radius: f32) -> vec3<f32> {
    var acc = textureSample(glowTex, samp, uv).rgb * 2.0;
    let px = radius / u.res;
    for (var i = 0; i < 8; i = i + 1) {
        let a = f32(i) * 0.7854 + 0.3;
        let o = vec2<f32>(cos(a), sin(a));
        acc = acc + textureSample(glowTex, samp, uv + o * px).rgb;
        acc = acc + textureSample(glowTex, samp, uv + vec2<f32>(-o.y, o.x) * px * 0.5).rgb;
    }
    return acc / 18.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let t = u.time;
    var uv = in.uv;
    let s = u.scale;

    // a caught jinn shakes the picture; the moteur hums through it
    let sh = u.shock * u.shock;
    uv = uv + vec2<f32>(sin(t * 83.0), cos(t * 71.0)) * 0.004 * sh;
    uv.x = uv.x + sin(uv.y * 40.0 + t * 30.0) * 0.003 * sh;
    uv.y = uv.y + sin(t * 157.0) * 0.0006 * u.rumble;

    let px = uv * u.res;

    // chromatic split grows with the shock
    let ca = (0.0008 + 0.006 * sh) * (uv - vec2<f32>(0.5));
    let albR = textureSample(albedoTex, samp, uv + ca).r;
    let albC = textureSample(albedoTex, samp, uv);
    let albG = albC.g;
    let albB = textureSample(albedoTex, samp, uv - ca).b;
    let alb = vec3<f32>(albR, albG, albB);
    let em = textureSample(emitTex, samp, uv).rgb;
    let sky = 1.0 - albC.a; // premultiplied: whatever is drawn covers the sky

    let city = 1.0 - u.dark; // how much of Beirut has power

    // --- the sky: deep blue overhead, sodium glow on the horizon while the
    // city has power, clouds lit from below by it
    let hz = clamp((px.y) / max(u.horizon, 1.0), 0.0, 1.2);
    var skyCol = mix(vec3<f32>(0.015, 0.02, 0.06), vec3<f32>(0.05, 0.07, 0.17), smoothstep(0.0, 0.8, hz));
    let sodium = vec3<f32>(0.46, 0.25, 0.13);
    skyCol = mix(skyCol, sodium, smoothstep(0.35, 1.05, hz) * (0.25 + 0.75 * city) * 0.85);
    let cp = vec2<f32>(px.x / (520.0 * s) + t * 0.010, px.y / (170.0 * s));
    let cn = fbm(cp + vec2<f32>(fbm(cp * 0.6 - t * 0.004), 0.0) * 0.8);
    let cloud = smoothstep(0.42, 0.78, cn) * (1.0 - smoothstep(0.85, 1.1, hz) * 0.5);
    let md = length(px - u.moon) / (260.0 * s);
    let moonLit = exp(-md * md) * 0.5;
    let cloudCol = mix(vec3<f32>(0.08, 0.09, 0.16), vec3<f32>(0.36, 0.24, 0.18), smoothstep(0.2, 1.0, hz) * city)
        + vec3<f32>(0.55, 0.58, 0.7) * moonLit;
    skyCol = mix(skyCol, cloudCol, cloud * 0.75);
    // a halo round the moon
    skyCol = skyCol + vec3<f32>(0.12, 0.13, 0.2) * exp(-md * 3.0);

    // --- what lights the street
    // while the city has power: warm sodium street light from below and the
    // windows; in the cut: blue moonlight and nothing else
    let cityLit = vec3<f32>(0.70, 0.62, 0.56);
    let moonDark = vec3<f32>(0.10, 0.12, 0.22);
    var ambient = mix(cityLit, moonDark, u.dark);
    ambient = ambient * (1.0 - 0.6 * u.dead);
    // the facade is a touch brighter near the ground, where the shops and the
    // street lamp are
    ambient = ambient * (0.88 + 0.22 * smoothstep(0.2, 1.0, uv.y) * city);

    // spill from lit windows onto the stone around them
    let near = glow(uv, 22.0 * s);
    let far = glow(uv, 64.0 * s);
    let spill = near * (0.28 + 0.2 * u.dark) + far * (0.18 + 0.5 * u.dark);

    // the phone torch: a hot centre, a soft ring and a little fog scatter
    let d = length(px - u.torch);
    let r = max(u.reach, 1.0);
    let core = smoothstep(r, r * 0.15, d);
    let ring = smoothstep(r * 1.05, r * 0.9, d) * smoothstep(r * 0.7, r * 0.92, d) * 0.25;
    let torch = (core * core * 0.85 + core * 0.4 + ring) * u.torchOn;
    let torchCol = vec3<f32>(1.0, 0.93, 0.80); // a phone LED, a little warm

    var col = alb * (ambient + spill + torch * torchCol);
    col = col + skyCol * sky;
    col = col + em * (0.9 + 0.1 * u.lights);
    // bloom: restrained while the street is lit, generous in the dark
    col = col + far * (0.07 + 0.22 * u.dark) + near * (0.04 + 0.14 * u.dark);

    // fog rolling down the street in the cut, lit by whatever is lit
    let fp = vec2<f32>(px.x / (260.0 * s) + t * 0.05, px.y / (180.0 * s) - t * 0.02);
    let fogN = fbm(fp + vec2<f32>(fbm(fp * 0.7 + t * 0.03) * 1.6, 0.0));
    let ground = smoothstep(0.35, 1.0, uv.y);
    let fogA = clamp((fogN - 0.3) * 1.6 * u.fog * (0.15 + 0.85 * ground), 0.0, 0.7);
    let fogLight = vec3<f32>(0.08, 0.10, 0.18) + torchCol * torch * 0.35 + far * 0.4;
    col = mix(col, fogLight, fogA * 0.4);

    // vignette, deeper in the dark
    let v = length((uv - vec2<f32>(0.5)) * vec2<f32>(1.0, 0.8));
    col = col * mix(1.0, smoothstep(0.95, 0.25, v), 0.18 + 0.5 * u.dark);

    // shock flash
    col = col + vec3<f32>(0.25, 0.05, 0.08) * sh * 0.3;

    // phone-camera grain, only really there in the dark
    let g = hash2(floor(px) + vec2<f32>(fract(t * 13.0) * 100.0, fract(t * 7.0) * 100.0)) - 0.5;
    col = col + g * (0.012 + 0.04 * u.dark);

    // gentle filmic shoulder
    col = col / (col + vec3<f32>(0.9)) * 1.75;
    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
