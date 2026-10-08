-- Kahraba: a Beirut power-cut ghost story.
--
-- The street is drawn twice every frame: once as albedo (what things are made
-- of) and once as emission (what glows: windows, the moon, eyes, sparks). The
-- emission's alpha doubles as the sky mask. light.wgsl lights the albedo with
-- city glow, moonlight, window spill and your phone torch, paints the sky,
-- adds bloom, fog and grain, and the result is drawn back into the artboard.
--
-- The markup owns the words, the cards and the changeover switch; this script
-- owns the street and the story clock. They talk through the view model:
-- `power` comes in (0 cut, 1 state power, 2 the neighbourhood generator) and
-- goes out when the story flips it; battery, found, phase, captions, cards and
-- the street light level go out.

local W = 1280
local H = 800

-- The camera: the street is drawn a little smaller than the artboard so the
-- pavement clears the subtitles. design -> stage: x' = 640 + (x - 640) * ZOOM
local ZOOM = 0.88
local CAM_Y = 22

-- Story timing, in seconds. Tuned by eye against the captions.
local CUT_AFTER = 7.0 -- how long the state power lasts (it never lasts)
local WARN_AT = 5.6 -- the lights stutter before a cut
local DWELL = 0.9 -- how long the torch must rest on a jinn
local DRAIN = 1.5 -- battery percent per second while the torch is on
local CHARGE = 12 -- percent per second on 5 amps

type Shape = { path: Path, color: Color }

type Window = {
    x: number, y: number, w: number, h: number,
    arch: boolean,
    warm: Color,
    sub: boolean, -- pays the generator subscription
    tv: boolean,
    phase: number,
    curtain: Color,
    plant: boolean,
}

type Creature = {
    kind: string,
    x: number, y: number, r: number,
    found: boolean,
    dwell: number,
    gone: number, -- seconds since caught
    blink: number,
    eyes: Color,
    heat: number, -- how much torch is on it, eased
    -- pose this frame
    px: number, py: number, sc: number, alpha: number,
}

type Cable = { ax: number, ay: number, bx: number, by: number, sag: number, w: number, seed: number }

type Puff = { x: number, y: number, vx: number, vy: number, life: number, max: number, r: number }

type Spark = { x: number, y: number, vx: number, vy: number, life: number, max: number }

type Scene = {
    ctx: Context,
    size: Vector,
    pxScale: number,
    t: number,
    mouse: Vector, -- design units
    torch: Vector, -- smoothed
    albedo: Canvas?,
    emit: Canvas?,
    glow: Canvas?,
    gpu: GPUCanvas?,
    pipeline: GPUPipeline?,
    ubo: GPUBuffer?,
    bind: GPUBindGroup?,
    sampler: GPUSampler,
    data: buffer,
    paint: Paint,
    stroke: Paint,
    static: { Shape },
    generator: { Shape },
    windows: { Window },
    creatures: { Creature },
    cables: { Cable },
    puffs: { Puff },
    sparks: { Spark },
    -- story state
    power: number, -- what the switch says
    phase: number, -- 0 intro, 1 hunt, 2 rescued by the moteur, 3 ending
    cutT: number, -- seconds since the last switch
    endT: number, -- seconds since the sixth jinn
    dark: number, -- 0 lit .. 1 cut
    lights: number, -- window light multiplier
    rumble: number,
    battery: number,
    found: number,
    shock: number,
    dead: number, -- seconds since the battery died, -1 when alive
    sparkClock: number,
    caption: string,
    captionAr: string,
    vmPower: Property<number>?,
    vmBattery: Property<string>?,
    vmLevel: Property<number>?,
    vmFound: Property<string>?,
    vmFoundCount: Property<number>?,
    vmCaption: Property<string>?,
    vmCaptionAr: Property<string>?,
    vmCardAr: Property<string>?,
    vmCardEn: Property<string>?,
    vmPhase: Property<number>?,
    vmAuto: Property<number>?,
    vmLights: Property<number>?,
    vmQuality: Property<number>?,
    auto: boolean,
}

-- ---------------------------------------------------------------------------
-- small helpers

local function rgb(r: number, g: number, b: number): Color
    return Color.rgb(r, g, b)
end

local function rect(p: Path, x: number, y: number, w: number, h: number)
    p:moveTo(Vector.xy(x, y))
    p:lineTo(Vector.xy(x + w, y))
    p:lineTo(Vector.xy(x + w, y + h))
    p:lineTo(Vector.xy(x, y + h))
    p:close()
end

local K = 0.5523

local function ellipse(p: Path, cx: number, cy: number, rx: number, ry: number)
    p:moveTo(Vector.xy(cx + rx, cy))
    p:cubicTo(Vector.xy(cx + rx, cy + ry * K), Vector.xy(cx + rx * K, cy + ry), Vector.xy(cx, cy + ry))
    p:cubicTo(Vector.xy(cx - rx * K, cy + ry), Vector.xy(cx - rx, cy + ry * K), Vector.xy(cx - rx, cy))
    p:cubicTo(Vector.xy(cx - rx, cy - ry * K), Vector.xy(cx - rx * K, cy - ry), Vector.xy(cx, cy - ry))
    p:cubicTo(Vector.xy(cx + rx * K, cy - ry), Vector.xy(cx + rx, cy - ry * K), Vector.xy(cx + rx, cy))
    p:close()
end

-- A window with a round top: the Lebanese arch.
local function arch(p: Path, x: number, y: number, w: number, h: number)
    local r = w / 2
    p:moveTo(Vector.xy(x, y + h))
    p:lineTo(Vector.xy(x, y + r))
    p:cubicTo(Vector.xy(x, y + r - r * K), Vector.xy(x + r - r * K, y), Vector.xy(x + r, y))
    p:cubicTo(Vector.xy(x + r + r * K, y), Vector.xy(x + w, y + r - r * K), Vector.xy(x + w, y + r))
    p:lineTo(Vector.xy(x + w, y + h))
    p:close()
end

local function shape(list: { Shape }, color: Color): Path
    local p = Path.new()
    table.insert(list, { path = p, color = color })
    return p
end

local function hash(n: number): number
    local s = math.sin(n * 127.1 + 311.7) * 43758.5453
    return s - math.floor(s)
end

local function clamp01(v: number): number
    return math.max(0, math.min(1, v))
end

local function smooth(a: number, b: number, v: number): number
    local t = clamp01((v - a) / (b - a))
    return t * t * (3 - 2 * t)
end

local function mixc(a: Color, b: Color, t: number): Color
    return Color.lerp(a, b, clamp01(t))
end

local BLACK = rgb(0, 0, 0)

-- ---------------------------------------------------------------------------
-- the street, built once

local STONE = rgb(222, 203, 164) -- Lebanese sandstone
local STONE_DARK = rgb(176, 156, 122)
local STONE_EDGE = rgb(240, 228, 198)
local SHUTTER = rgb(58, 122, 100) -- the green abajour
local SHUTTER_DARK = rgb(36, 82, 68)
local GLASS = rgb(10, 12, 18)
local IRON = rgb(24, 24, 28)
local TANK = rgb(34, 34, 40)

local CURTAINS = { rgb(206, 112, 96), rgb(150, 162, 92), rgb(236, 214, 170), rgb(92, 150, 152), rgb(180, 120, 160) }

local function addWindow(self: Scene, x: number, y: number, w: number, h: number, isArch: boolean, sub: boolean, tv: boolean)
    local warmth = hash(x * 0.37 + y * 1.3)
    local warm = if warmth < 0.7 then rgb(255, 184, 104) else rgb(255, 214, 160)
    local ci = 1 + math.floor(hash(x * 1.7 + y) * #CURTAINS)
    table.insert(self.windows, {
        x = x, y = y, w = w, h = h, arch = isArch, warm = warm,
        sub = sub, tv = tv, phase = hash(x + y) * 10,
        curtain = CURTAINS[math.min(#CURTAINS, ci)],
        plant = hash(x * 3.3 + y * 0.7) > 0.62,
    })
end

local function buildNeighbours(self: Scene)
    local s = self.static
    -- far skyline
    local far = shape(s, rgb(46, 52, 70))
    local x = -160
    local i = 0
    while x < W + 160 do
        local bw = 60 + hash(i + 3) * 90
        local top = 300 + hash(i + 9) * 140
        rect(far, x, top, bw, 700)
        if hash(i + 21) > 0.6 then
            rect(far, x + bw * 0.4, top - 40, 6, 40) -- antenna
        end
        x += bw - 4
        i += 1
    end
    -- left neighbour
    rect(shape(s, rgb(184, 172, 150)), -130, 250, 410, 800)
    rect(shape(s, rgb(156, 146, 126)), -130, 238, 416, 14)
    -- right neighbour
    rect(shape(s, rgb(190, 176, 150)), 990, 210, 420, 800)
    rect(shape(s, rgb(162, 150, 126)), 984, 198, 430, 14)
    for row = 0, 3 do
        for col = -1, 2 do
            if row == 3 and col >= 0 then continue end -- behind the generator
            local wx = 18 + col * 88
            local wy = 290 + row * 112
            addWindow(self, wx, wy, 46, 66, false, hash(row * 7 + col) > 0.45, false)
        end
        for col = 0, 3 do
            local wx2 = 1020 + col * 92
            local wy2 = 250 + row * 118
            addWindow(self, wx2, wy2, 50, 70, false, hash(row * 5 + col + 40) > 0.4, row == 1 and col == 1)
        end
    end
    -- a flag on the left roof
    rect(shape(s, IRON), 58, 150, 3, 90)
end

local function buildBuilding(self: Scene)
    local s = self.static
    local L = 330
    local R = 950
    -- roof furniture behind the parapet
    local tanks = shape(s, TANK)
    for _, tx in { 392, 452, 868 } do
        rect(tanks, tx, 108, 46, 58)
        ellipse(tanks, tx + 23, 108, 23, 7)
    end
    local bands = shape(s, rgb(54, 54, 62))
    for _, tx in { 392, 452, 868 } do
        rect(bands, tx, 124, 46, 3)
        rect(bands, tx, 146, 46, 3)
    end
    local solar = shape(s, rgb(40, 52, 82))
    solar:moveTo(Vector.xy(690, 166))
    solar:lineTo(Vector.xy(712, 112))
    solar:lineTo(Vector.xy(812, 112))
    solar:lineTo(Vector.xy(790, 166))
    solar:close()
    local cells = shape(s, rgb(70, 88, 130))
    for k = 0, 3 do
        local yy = 118 + k * 12
        local inset = (yy - 112) / 54 * 22
        cells:moveTo(Vector.xy(712 - inset + 3, yy))
        cells:lineTo(Vector.xy(812 - inset - 3, yy))
        cells:lineTo(Vector.xy(812 - inset - 5, yy + 1.5))
        cells:lineTo(Vector.xy(712 - inset + 1, yy + 1.5))
        cells:close()
    end
    local frames = shape(s, rgb(150, 154, 160))
    rect(frames, 700, 140, 4, 26)
    rect(frames, 796, 140, 4, 26)
    local dish = shape(s, rgb(200, 202, 206))
    ellipse(dish, 600, 132, 20, 24)
    rect(shape(s, IRON), 598, 150, 4, 18)
    rect(shape(s, IRON), 540, 70, 3, 100) -- antenna mast
    local ant = shape(s, IRON)
    rect(ant, 520, 84, 44, 2)
    rect(ant, 526, 98, 32, 2)
    rect(ant, 530, 112, 24, 2)

    -- the facade
    rect(shape(s, STONE), L, 166, R - L, 900)
    rect(shape(s, STONE_EDGE), L - 8, 160, R - L + 16, 12) -- parapet cap
    -- stone courses, and the joints of the ashlar between them
    local courses = shape(s, STONE_DARK)
    for _, cy in { 298, 428, 586, 702 } do
        rect(courses, L - 6, cy, R - L + 12, 7)
    end
    local joints = shape(s, rgb(206, 186, 148))
    for row = 0, 15 do
        local yy = 186 + row * 34
        rect(joints, L + 10, yy, R - L - 20, 1.5)
        local off = if row % 2 == 0 then 0 else 38
        local xx = L + 10 + off
        while xx < R - 10 do
            rect(joints, xx, yy, 1.5, 34)
            xx += 76
        end
    end
    rect(shape(s, STONE_DARK), L, 166, 10, 900)
    rect(shape(s, STONE_DARK), R - 10, 166, 10, 900)

    -- fourth floor
    for _, wx in { 372, 482, 738, 848 } do
        addWindow(self, wx, 196, 60, 82, false, wx ~= 482, false)
    end
    -- third floor with the laundry balcony
    for _, wx in { 372, 482, 738, 848 } do
        addWindow(self, wx, 326, 60, 82, false, wx ~= 848, wx == 372)
    end
    addWindow(self, 590, 318, 100, 92, false, true, false)
    -- second floor: the triple arch, the heart of a Lebanese house
    for k = 0, 2 do
        addWindow(self, 572 + k * 48, 448, 40, 124, true, true, false)
    end
    addWindow(self, 396, 456, 58, 112, true, false, false)
    addWindow(self, 826, 456, 58, 112, true, true, false)
    -- first floor
    for _, wx in { 372, 482, 738, 848 } do
        addWindow(self, wx, 608, 60, 76, false, wx ~= 738, wx == 482)
    end

    -- ground floor: two shops and the entrance
    local shut = shape(s, rgb(124, 130, 138))
    rect(shut, 368, 722, 170, 84)
    rect(shut, 742, 722, 170, 84)
    local ribs = shape(s, rgb(94, 100, 108))
    for k = 0, 9 do
        rect(ribs, 368, 726 + k * 8, 170, 2)
        rect(ribs, 742, 726 + k * 8, 170, 2)
    end
    -- shop signs: the letters are neon in the markup, the boards are here
    rect(shape(s, rgb(150, 50, 40)), 362, 698, 182, 26) -- the bakery
    rect(shape(s, rgb(36, 84, 124)), 736, 698, 182, 26) -- the mini market
    local edge = shape(s, rgb(60, 30, 26))
    rect(edge, 362, 722, 182, 3)
    rect(edge, 736, 722, 182, 3)
    -- graffiti tags on the shutters, sprayed in two colours
    local tag = shape(s, rgb(196, 70, 60))
    for k = 0, 5 do
        local gx = 392 + k * 18
        tag:moveTo(Vector.xy(gx, 770 - hash(k) * 10))
        tag:lineTo(Vector.xy(gx + 12, 752 + hash(k + 3) * 8))
        tag:lineTo(Vector.xy(gx + 14, 754 + hash(k + 3) * 8))
        tag:lineTo(Vector.xy(gx + 2, 772 - hash(k) * 10))
        tag:close()
    end
    arch(shape(s, rgb(26, 22, 20)), 600, 716, 80, 92) -- entrance, dark
    rect(shape(s, STONE_EDGE), 594, 712, 92, 6)
end

local function buildFrames(self: Scene)
    -- frames and shutters drawn over the window glass
    local s = self.static
    local frame = shape(s, STONE_EDGE)
    local shutters = shape(s, SHUTTER)
    local slats = shape(s, SHUTTER_DARK)
    local sills = shape(s, STONE_DARK)
    for _, w in self.windows do
        if w.x > 300 and w.x < 960 then
            if w.arch then
                rect(frame, w.x - 4, w.y + w.h, w.w + 8, 6)
            else
                rect(frame, w.x - 5, w.y - 6, w.w + 10, 6)
                rect(frame, w.x - 6, w.y + w.h, w.w + 12, 7)
                rect(sills, w.x - 6, w.y + w.h + 7, w.w + 12, 2)
                if w.w < 80 then
                    -- one shutter leaf open on each side, louvered
                    local sw = w.w * 0.5
                    rect(shutters, w.x - sw - 4, w.y, sw, w.h)
                    rect(shutters, w.x + w.w + 4, w.y, sw, w.h)
                    for k = 0, math.floor(w.h / 7) - 1 do
                        rect(slats, w.x - sw - 2, w.y + 4 + k * 7, sw - 4, 2)
                        rect(slats, w.x + w.w + 6, w.y + 4 + k * 7, sw - 4, 2)
                    end
                end
            end
        else
            rect(frame, w.x - 3, w.y + w.h, w.w + 6, 5)
        end
    end
    -- pots on the sills: basil, geranium, a sad cactus
    local pots = shape(s, rgb(176, 92, 60))
    local leaves = shape(s, rgb(54, 104, 58))
    for _, w in self.windows do
        if w.plant and not w.arch then
            local px = w.x + w.w * 0.22
            rect(pots, px, w.y + w.h - 10, 12, 10)
            ellipse(leaves, px + 6, w.y + w.h - 15, 10, 7)
            ellipse(leaves, px + 12, w.y + w.h - 19, 6, 5)
        end
    end
    -- triple arch columns and the balcony under it
    local col = shape(s, STONE_EDGE)
    rect(col, 566, 448, 6, 128)
    rect(col, 612, 448, 8, 128)
    rect(col, 660, 448, 8, 128)
    rect(col, 708, 448, 6, 128)
    local slab = shape(s, STONE_DARK)
    rect(slab, 548, 578, 184, 8)
    rect(slab, 572, 412, 136, 8) -- third floor balcony slab
    local rail = shape(s, IRON)
    rect(rail, 552, 540, 176, 3)
    for k = 0, 22 do
        rect(rail, 554 + k * 7.8, 540, 2, 38)
    end
    rect(rail, 576, 376, 128, 3)
    for k = 0, 16 do
        rect(rail, 578 + k * 7.6, 376, 2, 36)
    end
    -- AC units, every one of them dripping on the pavement
    local ac = shape(s, rgb(226, 228, 230))
    rect(ac, 856, 412, 44, 28)
    rect(ac, 1112, 352, 44, 28)
    local grille = shape(s, rgb(150, 152, 156))
    ellipse(grille, 878, 426, 10, 10)
    ellipse(grille, 1134, 366, 10, 10)
end

local function buildStreet(self: Scene)
    local s = self.static
    rect(shape(s, rgb(58, 58, 64)), -200, 790, W + 400, 300) -- pavement
    rect(shape(s, rgb(84, 84, 90)), -200, 790, W + 400, 5) -- kerb
    -- the pole every cable comes from
    rect(shape(s, rgb(64, 60, 56)), 262, 300, 12, 500)
    rect(shape(s, rgb(64, 60, 56)), 238, 318, 60, 6)
    local box = shape(s, rgb(90, 90, 96)) -- the meter box with too many breakers
    rect(box, 252, 520, 32, 44)
    -- street lamp
    local lamp = shape(s, rgb(46, 48, 52))
    rect(lamp, 966, 430, 10, 380)
    rect(lamp, 912, 428, 64, 8)
    rect(lamp, 904, 426, 30, 12)
    -- low wall with the cat
    rect(shape(s, rgb(156, 146, 124)), 276, 770, 60, 30)

    -- the neighbourhood generator, a green box with a chimney, drawn on its own
    -- so it can shake
    local g = self.generator
    local boxp = shape(g, rgb(66, 104, 80))
    rect(boxp, 26, 618, 214, 176)
    local trim = shape(g, rgb(44, 72, 56))
    rect(trim, 26, 618, 214, 6)
    for k = 0, 6 do
        rect(trim, 48, 676 + k * 12, 90, 4)
    end
    rect(shape(g, rgb(236, 208, 100)), 38, 628, 158, 30) -- Abu Ali's name plate
    rect(shape(g, rgb(230, 190, 60)), 160, 676, 54, 34) -- warning plate
    rect(shape(g, rgb(30, 30, 30)), 172, 684, 30, 4)
    rect(shape(g, rgb(30, 30, 30)), 172, 694, 22, 4)
    local pipe = shape(g, rgb(40, 40, 44))
    rect(pipe, 196, 520, 14, 100)
    rect(pipe, 190, 512, 26, 12)
end

local function buildCables(self: Scene)
    local targets = {
        { 340, 214 }, { 340, 350 }, { 340, 470 }, { 344, 630 }, { 360, 700 },
        { 120, 290 }, { 60, 420 }, { 180, 520 }, { 990, 260 }, { 1000, 360 },
        { 940, 200 }, { 620, 166 }, { 920, 432 }, { 200, 612 }, { 30, 330 },
        { -60, 300 }, { 1060, 230 }, { 470, 300 },
    }
    for i, tg in targets do
        local ax = 268 + (hash(i) - 0.5) * 20
        local ay = 316 + hash(i + 50) * 10
        local dist = math.abs(tg[1] - ax) + math.abs(tg[2] - ay)
        table.insert(self.cables, {
            ax = ax, ay = ay, bx = tg[1], by = tg[2],
            sag = 20 + dist * 0.12 + hash(i + 9) * 30,
            w = 1.6 + hash(i + 77) * 1.6,
            seed = hash(i + 101) * 6.28,
        })
    end
end

local function addCreature(self: Scene, kind: string, x: number, y: number, r: number, eyes: Color)
    table.insert(self.creatures, {
        kind = kind, x = x, y = y, r = r, found = false, dwell = 0, gone = 0,
        blink = hash(x) * 4, eyes = eyes, heat = 0,
        px = x, py = y, sc = 1, alpha = 1,
    })
end

local function buildCreatures(self: Scene)
    addCreature(self, 'ghoul', 425, 122, 46, rgb(255, 70, 40))
    addCreature(self, 'silewa', 616, 356, 46, rgb(160, 255, 210))
    addCreature(self, 'qarina', 640, 500, 40, rgb(255, 255, 255))
    addCreature(self, 'ifrit', 204, 452, 50, rgb(255, 150, 30))
    addCreature(self, 'abukees', 640, 742, 44, rgb(255, 210, 60))
    addCreature(self, 'cat', 306, 760, 30, rgb(140, 255, 90))
end

-- ---------------------------------------------------------------------------
-- copy: the name card (Arabic, English) and the caption (English, Arabic)

local CARDS: { [string]: { string } } = {
    ghoul = { 'الغول', 'THE GHOUL', 'Eats travellers. Lives on the roof, between the water tanks.', 'بياكل المسافرين. ساكن عالسطح بين خزانات المي.' },
    silewa = { 'السعلوة', "THE SI'LEWA", "Combs her hair behind Umm Georges' laundry at midnight.", 'بتمشّط شعرها ورا غسيل أم جورج نص الليل.' },
    qarina = { 'القرينة', 'THE QARINA', 'Your shadow twin. She has a phone too. Hers is brighter.', 'توأمك من الضل. معها تلفون كمان. ضوّه أقوى من ضوّك.' },
    ifrit = { 'العفريت', 'THE IFRIT', 'Born in generator smoke. Runs on diesel. Back to the chimney.', 'خلق من دخان الموتور. بيمشي عالمازوت. رجع عالمدخنة.' },
    abukees = { 'أبو كيس', 'ABU KEES', 'Takes the kids who refuse to sleep. Brings his own sack.', 'بياخد الولاد يلّي ما بدهن يناموا. جايب كيسه معه.' },
    cat = { 'بسّة الجيران', "THE NEIGHBOURS' CAT", 'Just the neighbours\' cat. Probably.', 'بس بسّة الجيران. على الأغلب.' },
}

local function say(self: Scene, en: string, ar: string)
    self.caption = en
    self.captionAr = ar
    local c = self.vmCaption
    if c ~= nil then c.value = en end
    local a = self.vmCaptionAr
    if a ~= nil then a.value = ar end
end

local function setPhase(self: Scene, p: number)
    self.phase = p
    local ph = self.vmPhase
    if ph ~= nil and ph.value ~= p then ph.value = p end
end

local function sayPower(self: Scene)
    if self.phase == 3 then
        return
    end
    if self.power == 1 then
        say(self, 'Beirut, 8 PM. The state power is on. For now.', 'بيروت، الساعة ٨. كهربا الدولة جايي. هلّق.')
    elseif self.power == 0 then
        say(self, 'Cut. Six jinn live in this building. Hold your phone light on their eyes.', 'قطعت. في ستة جن بهالبناية. ثبّت ضو التلفون على عيونهن.')
    else
        say(self, "Moteur on, 5 amps. Flip back to the dark when you're charged.", 'اشتغل الموتور، ٥ أمبير. ارجع عالعتمة لمّا يشحن التلفون.')
    end
end

-- ---------------------------------------------------------------------------
-- lifecycle

local function bindVm(self: Scene, context: Context)
    local vm = context:viewModel()
    if vm == nil then
        return
    end
    self.vmPower = vm:getNumber('power')
    self.vmBattery = vm:getString('batteryText')
    self.vmLevel = vm:getNumber('batteryLevel')
    self.vmFound = vm:getString('foundText')
    self.vmFoundCount = vm:getNumber('found')
    self.vmCaption = vm:getString('caption')
    self.vmCaptionAr = vm:getString('captionAr')
    self.vmCardAr = vm:getString('cardAr')
    self.vmCardEn = vm:getString('cardEn')
    self.vmPhase = vm:getNumber('phase')
    self.vmAuto = vm:getNumber('autoplay')
    self.vmLights = vm:getNumber('lights')
    self.vmQuality = vm:getNumber('quality')
end

function init(self: Scene, context: Context): boolean
    self.ctx = context
    bindVm(self, context)
    if #self.static == 0 then
        buildNeighbours(self)
        buildBuilding(self)
        buildFrames(self)
        buildStreet(self)
        buildCables(self)
        buildCreatures(self)
    end
    sayPower(self)
    return true
end

local function quality(self: Scene): number
    local q = self.vmQuality
    if q ~= nil and q.value > 0 then
        return math.min(3, q.value)
    end
    return 1
end

local function rebuild(self: Scene)
    local q = self.pxScale * quality(self)
    local w = math.max(1, math.floor(self.size.x * q))
    local h = math.max(1, math.floor(self.size.y * q))
    local ctx = self.ctx
    local albedo = ctx:canvas({ width = w, height = h })
    local emit = ctx:canvas({ width = w, height = h })
    local glow = ctx:canvas({ width = math.max(1, math.floor(w / 4)), height = math.max(1, math.floor(h / 4)) })
    self.albedo = albedo
    self.emit = emit
    self.glow = glow
    local gpu = ctx:gpuCanvas({ width = w, height = h })
    self.gpu = gpu
    local shader = ctx:shader('light')
    if shader == nil then
        print('kahraba: light shader missing')
        return
    end
    local pipeline = GPUPipeline.new({
        vertex = shader,
        fragment = shader,
        vertexLayout = {},
        colorTargets = { { format = gpu.format } },
    })
    self.pipeline = pipeline
    local ubo = GPUBuffer.new({ size = 80, usage = 'uniform' })
    self.ubo = ubo
    self.bind = GPUBindGroup.new({
        layout = pipeline:getBindGroupLayout(0),
        ubos = { { slot = 0, buffer = ubo } },
        textures = {
            { slot = 1, view = albedo.image:view() },
            { slot = 2, view = emit.image:view() },
            { slot = 3, view = glow.image:view() },
        },
        samplers = { { slot = 4, sampler = self.sampler } },
    })
end

function resize(self: Scene, size: Vector, scale: number)
    self.size = size
    self.pxScale = if scale > 0 then scale else 1
    rebuild(self)
end

-- design units -> stage units: cover the stage, then the camera.
-- stage = A * design + (BX, BY)
local function cam(self: Scene): (number, number, number)
    local sx = self.size.x / W
    local sy = self.size.y / H
    local s = math.max(sx, sy)
    local ox = (self.size.x - W * s) / 2
    local oy = (self.size.y - H * s) / 2
    return s * ZOOM, ox + s * 640 * (1 - ZOOM), oy + s * CAM_Y
end

function pointerMove(self: Scene, event: PointerEvent)
    local a, bx, by = cam(self)
    self.mouse = Vector.xy((event.position.x - bx) / a, (event.position.y - by) / a)
    self.auto = false
end

function pointerDown(self: Scene, event: PointerEvent)
    pointerMove(self, event)
end

-- The torch's path when nobody is holding it, and in the film. Each stop is
-- (seconds, x, y); the light eases between stops and rests where two repeat.
-- Hand-placed: a wander, a miss, then each jinn in turn, the way a person
-- searches a building they know.
local FILM: { { number } } = {
    { 0, 640, 430 }, { 7.2, 640, 430 }, { 8.4, 560, 300 }, { 9.4, 520, 230 },
    { 10.4, 430, 140 }, { 12.0, 425, 126 },
    { 13.0, 540, 260 }, { 13.8, 610, 352 }, { 15.4, 616, 360 },
    { 16.4, 820, 470 }, { 17.4, 760, 520 }, { 18.2, 646, 500 }, { 19.8, 640, 504 },
    { 20.8, 440, 520 }, { 21.6, 220, 430 }, { 23.2, 204, 452 },
    { 24.2, 420, 640 }, { 25.0, 600, 740 }, { 25.4, 640, 752 }, { 27.0, 640, 752 },
    { 27.8, 470, 770 }, { 28.4, 330, 762 }, { 30.2, 306, 760 },
    { 31.4, 500, 420 }, { 60, 520, 400 },
}

local function autopilot(self: Scene): Vector
    local t = self.t
    local n = #FILM
    local a = FILM[1]
    local b = FILM[n]
    for i = 1, n - 1 do
        if t >= FILM[i][1] and t < FILM[i + 1][1] then
            a = FILM[i]
            b = FILM[i + 1]
            break
        end
    end
    if t >= FILM[n][1] then
        a = FILM[n]
        b = FILM[n]
    end
    local span = math.max(0.001, b[1] - a[1])
    local f = clamp01((t - a[1]) / span)
    f = f * f * (3 - 2 * f)
    -- a hand never holds a phone still
    local hx = math.sin(t * 2.3) * 4 + math.sin(t * 5.1) * 1.5
    local hy = math.cos(t * 1.7) * 3 + math.sin(t * 4.3) * 1.5
    return Vector.xy(a[2] + (b[2] - a[2]) * f + hx, a[3] + (b[3] - a[3]) * f + hy)
end

local function burst(self: Scene, x: number, y: number, n: number, seed: number)
    for k = 1, n do
        local a = -math.pi * (0.1 + 0.8 * hash(k * 1.3 + seed))
        local v = 80 + hash(k * 2.9 + seed) * 220
        table.insert(self.sparks, {
            x = x, y = y, vx = math.cos(a) * v, vy = math.sin(a) * v,
            life = 0, max = 0.35 + hash(k + seed) * 0.6,
        })
    end
end

local function pushPower(self: Scene, p: number)
    self.power = p
    self.cutT = 0
    local vp = self.vmPower
    if vp ~= nil and vp.value ~= p then
        vp.value = p
    end
end

local function setCard(self: Scene, c: Creature)
    local card = CARDS[c.kind]
    if card == nil then
        return
    end
    local ca = self.vmCardAr
    if ca ~= nil then ca.value = card[1] end
    local ce = self.vmCardEn
    if ce ~= nil then ce.value = card[2] .. '  ·  ' .. tostring(self.found) .. ' / 6' end
    say(self, card[3], card[4])
end

local function catch(self: Scene, c: Creature)
    c.found = true
    c.gone = 0
    self.found += 1
    self.shock = if c.kind == 'cat' then 0.45 else 1
    setCard(self, c)
    for k = 1, 18 do
        local a = hash(k + c.x) * 6.283
        local v = 30 + hash(k * 3 + c.y) * 90
        table.insert(self.puffs, {
            x = c.x, y = c.y, vx = math.cos(a) * v, vy = math.sin(a) * v - 30,
            life = 0, max = 0.8 + hash(k) * 0.8, r = 8 + hash(k + 5) * 14,
        })
    end
    local fv = self.vmFound
    if fv ~= nil then
        fv.value = tostring(self.found) .. ' / 6'
    end
    local fc = self.vmFoundCount
    if fc ~= nil then
        fc.value = self.found
    end
end

local function reset(self: Scene)
    for _, c in self.creatures do
        c.found = false
        c.dwell = 0
        c.gone = 0
        c.heat = 0
    end
    self.found = 0
    self.battery = 100
    self.endT = 0
    local fv = self.vmFound
    if fv ~= nil then fv.value = '0 / 6' end
    local fc = self.vmFoundCount
    if fc ~= nil then fc.value = 0 end
end

-- where each jinn is this frame: in hiding, fleeing once caught, or sitting on
-- the parapet at the end
local PARADE: { [string]: number } = { ghoul = 402, silewa = 494, qarina = 574, ifrit = 664, abukees = 756, cat = 842 }
local FEET: { [string]: number } = { ghoul = 38, silewa = 52, qarina = 66, ifrit = 56, abukees = 48, cat = 10 }

local function pose(self: Scene, c: Creature, idx: number)
    if self.phase == 3 then
        local enter = self.endT - 1.8 - idx * 0.28
        local px: number = PARADE[c.kind] or 640
        local sc = 1
        local feet: number = FEET[c.kind] or 40
        local drop = 1 - smooth(0, 0.45, enter)
        local bounce = math.abs(math.sin(clamp01(enter / 0.45) * math.pi)) * 6
        c.px = px + math.sin(self.t * 0.9 + idx) * 2
        c.py = 160 - feet * sc - drop * 60 - bounce
        c.sc = sc
        c.alpha = smooth(0, 0.2, enter)
        return
    end
    c.px = c.x
    c.py = c.y
    c.sc = 1
    c.alpha = 1
    if not c.found then
        return
    end
    local g = c.gone
    local e = smooth(0, 1, g / 1.1)
    if c.kind == 'ghoul' then
        -- leaps off the roof
        c.px = c.x + 90 * g
        c.py = c.y - 40 * g - 520 * g * g + 30 * math.sin(math.min(g, 0.25) * 12.6)
        c.alpha = 1 - smooth(0.7, 1.2, g)
    elseif c.kind == 'silewa' then
        -- rises through the laundry
        c.py = c.y - 110 * e
        c.alpha = 1 - smooth(0.2, 1.1, g)
    elseif c.kind == 'qarina' then
        -- sinks into the floor she came from
        c.py = c.y + 80 * e
        c.sc = 1 - 0.3 * e
        c.alpha = 1 - smooth(0.3, 1.0, g)
    elseif c.kind == 'ifrit' then
        -- sucked back down the generator chimney
        c.px = c.x + (203 - c.x) * e
        c.py = c.y + (505 - c.y) * e - math.sin(e * math.pi) * 40
        c.sc = 1 - 0.85 * e
        c.alpha = 1 - smooth(0.9, 1.25, g)
    elseif c.kind == 'abukees' then
        -- backs into the dark entrance
        c.sc = 1 - 0.45 * e
        c.py = c.y + 12 * e
        c.alpha = 1 - smooth(0.5, 1.2, g)
    else
        -- the cat bolts along the wall
        c.px = c.x - 380 * g * g - 120 * g
        c.py = c.y - math.abs(math.sin(g * 16)) * 7
        c.alpha = 1 - smooth(0.8, 1.2, g)
    end
end

function advance(self: Scene, seconds: number): boolean
    local dt = math.min(seconds, 1 / 20)
    self.t += dt
    self.cutT += dt

    local vauto = self.vmAuto
    if vauto ~= nil and vauto.value > 0 then
        self.auto = true
    end

    -- follow the switch in the markup
    local vp = self.vmPower
    if vp ~= nil and vp.value ~= self.power then
        self.power = vp.value
        self.cutT = 0
        if self.power == 0 then
            burst(self, 268, 318, 14, self.t)
            if self.phase == 3 or self.phase == 0 then
                if self.phase == 3 then reset(self) end
                setPhase(self, 1)
            elseif self.phase == 2 then
                setPhase(self, 1)
            end
        end
        sayPower(self)
    end

    -- the state power never lasts: it stutters, then goes
    if self.phase == 0 and self.power == 1 and self.cutT > CUT_AFTER then
        pushPower(self, 0)
        setPhase(self, 1)
        burst(self, 268, 318, 22, 1)
        burst(self, 940, 200, 10, 2)
        self.shock = 0.5
        say(self, 'And there it goes. Six jinn live in this building. Hold your phone light on their eyes.', 'وقطعت. في ستة جن بهالبناية. ثبّت ضو التلفون على عيونهن.')
    end

    -- the street lags the switch: a cut stutters, the generator coughs first
    local target = self.power
    local lightsTarget = 1
    local darkTarget = 0
    local rumbleTarget = 0
    if target == 1 and self.phase == 0 and self.cutT > WARN_AT then
        -- the warning flicker every Beiruti knows
        local f = hash(math.floor(self.cutT * 11))
        lightsTarget = if f > 0.45 then 1 else 0.35
    end
    if target == 0 then
        darkTarget = 1
        lightsTarget = 0
        if self.cutT < 0.5 then
            lightsTarget = if math.floor(self.cutT * 14) % 2 == 0 then 0.9 else 0
            darkTarget = 1 - lightsTarget
        end
    elseif target == 2 then
        darkTarget = 0.5
        lightsTarget = 0.82
        rumbleTarget = 0.3
        if self.cutT < 1.4 then
            local cough = math.sin(self.cutT * 31) * math.sin(self.cutT * 7.3)
            lightsTarget = if self.cutT < 0.6 then 0 else clamp01(0.4 + cough)
            darkTarget = 1 - lightsTarget * 0.5
            rumbleTarget = if self.cutT < 0.6 then 0.4 + 0.6 * math.abs(math.sin(self.cutT * 20)) else 1
        else
            lightsTarget = 0.8 + math.sin(self.t * 23) * 0.04 + math.sin(self.t * 3.1) * 0.03
        end
        if self.cutT - dt < 0.6 and self.cutT >= 0.6 then
            burst(self, 203, 512, 16, 3) -- the moteur catches
            burst(self, 268, 318, 8, 4)
        end
    end
    local k = 1 - math.exp(-dt * 18)
    self.dark += (darkTarget - self.dark) * k
    self.lights += (lightsTarget - self.lights) * (1 - math.exp(-dt * 30))
    self.rumble += (rumbleTarget - self.rumble) * (1 - math.exp(-dt * 8))
    local vl2 = self.vmLights
    if vl2 ~= nil then
        vl2.value = self.lights
    end

    -- the torch
    local goal = if self.auto then autopilot(self) else self.mouse
    local kt = 1 - math.exp(-dt * 12)
    self.torch = Vector.xy(self.torch.x + (goal.x - self.torch.x) * kt, self.torch.y + (goal.y - self.torch.y) * kt)

    local torchOn = self.power == 0 and self.dead < 0
    if torchOn and self.phase ~= 3 then
        self.battery = math.max(0, self.battery - dt * DRAIN)
        if self.battery <= 0 then
            self.dead = 0
            self.shock = 1.4
            say(self, 'Battery died. Everyone in the building is looking at you.', 'خلص الشحن. كل البناية عم تطلّع فيك.')
        end
    elseif self.power ~= 0 then
        self.battery = math.min(100, self.battery + dt * CHARGE)
    end
    if self.dead >= 0 then
        self.dead += dt
        if self.dead > 2.6 then
            self.dead = -1
            pushPower(self, 2)
            setPhase(self, 2)
            say(self, "Abu Ali's moteur, just in time. Flip back to the dark when you're charged.", 'موتير أبو علي، عالوقت. ارجع عالعتمة لمّا يشحن التلفون.')
        end
    end

    -- sparks: the cut, the moteur, and the odd crackle on the pole in the dark
    self.sparkClock -= dt
    if self.dark > 0.8 and self.sparkClock <= 0 then
        local pick = math.floor(hash(self.t * 3.7) * #self.cables) + 1
        local cb = self.cables[math.min(#self.cables, pick)]
        burst(self, cb.ax, cb.ay, 6 + math.floor(hash(self.t) * 6), self.t)
        self.sparkClock = 2.2 + hash(self.t * 1.3) * 3.5
    end
    for i = #self.sparks, 1, -1 do
        local sp = self.sparks[i]
        sp.life += dt
        sp.x += sp.vx * dt
        sp.y += sp.vy * dt
        sp.vy += 700 * dt
        sp.vx *= 0.985
        if sp.life > sp.max then
            table.remove(self.sparks, i)
        end
    end

    -- jinn: the torch has to rest on one to see it properly
    local reach = 70 * (0.55 + 0.45 * self.battery / 100)
    for idx, c in self.creatures do
        c.blink += dt
        local near = 0
        if c.found then
            c.gone += dt
        elseif torchOn and self.phase == 1 then
            local dx = self.torch.x - c.x
            local dy = self.torch.y - c.y
            local d = math.sqrt(dx * dx + dy * dy)
            near = smooth(c.r + reach * 1.6, c.r * 0.6, d)
            if d < c.r + reach * 0.35 then
                c.dwell += dt
                if c.dwell > DWELL then
                    catch(self, c)
                end
            else
                c.dwell = math.max(0, c.dwell - dt * 0.8)
            end
        else
            c.dwell = 0
        end
        c.heat += (near - c.heat) * (1 - math.exp(-dt * 6))
        pose(self, c, idx - 1)
    end
    if self.found >= 6 and self.phase ~= 3 then
        setPhase(self, 3)
        self.endT = 0
        pushPower(self, 2)
        say(self, "Six jinn, one moteur. Even the jinn pay Abu Ali's subscription.", 'ستة جن وموتير واحد. حتى الجن دافعين اشتراك أبو علي.')
    end
    if self.phase == 3 then
        self.endT += dt
    end

    for i = #self.puffs, 1, -1 do
        local p = self.puffs[i]
        p.life += dt
        p.x += p.vx * dt
        p.y += p.vy * dt
        p.vx *= 0.96
        p.vy = p.vy * 0.96 - 8 * dt
        if p.life > p.max then
            table.remove(self.puffs, i)
        end
    end
    -- generator smoke, thicker while it is catching
    local smokeRate = if self.cutT < 2 then 0.25 else 0.55
    if self.power == 2 and self.cutT > 0.3 and hash(self.t * 13.7) > smokeRate then
        table.insert(self.puffs, {
            x = 203, y = 510, vx = 10 + (hash(self.t) - 0.5) * 20, vy = -50 - hash(self.t + 1) * 30,
            life = 0, max = 1.6 + hash(self.t + 2), r = 6 + hash(self.t + 3) * 6,
        })
    end

    self.shock = math.max(0, self.shock - dt * 1.6)

    local vb = self.vmBattery
    if vb ~= nil then
        vb.value = tostring(math.floor(self.battery + 0.5)) .. '%'
    end
    local vl = self.vmLevel
    if vl ~= nil then
        vl.value = self.battery
    end
    return true
end

-- ---------------------------------------------------------------------------
-- drawing

local function fill(self: Scene, r: Renderer, p: Path, c: Color)
    self.paint.color = c
    r:drawPath(p, self.paint)
end

local function drawCables(self: Scene, r: Renderer)
    local writhe = self.dark * (1 - self.lights)
    self.stroke.color = rgb(14, 14, 16)
    for _, cb in self.cables do
        local p = Path.new()
        local n = 22
        for i = 0, n do
            local u = i / n
            local x = cb.ax + (cb.bx - cb.ax) * u
            local y = cb.ay + (cb.by - cb.ay) * u + math.sin(u * math.pi) * cb.sag
            local wob = math.sin(u * math.pi) * writhe
            x += math.sin(self.t * 2.1 + u * 9 + cb.seed) * 7 * wob
            y += math.sin(self.t * 1.7 + u * 7 + cb.seed * 2) * 11 * wob
            -- the moteur shakes the lines a little
            y += math.sin(u * math.pi) * math.sin(self.t * 47 + cb.seed) * 1.2 * self.rumble
            if i == 0 then p:moveTo(Vector.xy(x, y)) else p:lineTo(Vector.xy(x, y)) end
        end
        self.stroke.thickness = cb.w
        r:drawPath(p, self.stroke)
    end
end

-- The six jinn. Each is a handful of parts (fills and limb strokes) built at
-- its pose every frame. `h` is how much torch is on it (0..1), and each one
-- answers the light in its own way. Drawn dark in the albedo, so only the
-- torch shows them; the eyes and the odd glowing detail go in the emission.

type Part = { path: Path, tone: { number }?, width: number }

-- each jinn has its own matter, hand-picked to stay dark until the torch
-- finds it and then read as a different creature: ash, bone, shadow, ember,
-- sackcloth, cat
local TONE: { [string]: { number } } = {
    ghoul = { 62, 78, 56 }, silewa = { 132, 120, 112 }, qarina = { 44, 48, 64 },
    ifrit = { 104, 46, 34 }, abukees = { 70, 56, 44 }, cat = { 30, 28, 34 },
}
local HAIR = { 18, 16, 22 }

local function bodyParts(self: Scene, c: Creature): { Part }
    local base = TONE[c.kind]
    local t = self.t
    local h = c.heat
    local sc = c.sc
    local trem = c.dwell * 2.5
    local x = c.px + math.sin(t * 60) * trem
    local y = c.py
    local parts: { Part } = {}
    local function V(dx: number, dy: number): Vector
        return Vector.xy(x + dx * sc, y + dy * sc)
    end
    local function part(tone: { number }?, width: number): Path
        local p = Path.new()
        table.insert(parts, { path = p, tone = tone or base, width = width * sc })
        return p
    end
    local function ell(p: Path, dx: number, dy: number, rx: number, ry: number)
        ellipse(p, x + dx * sc, y + dy * sc, rx * sc, ry * sc)
    end
    local function poly(p: Path, pts: { number })
        p:moveTo(V(pts[1], pts[2]))
        for i = 3, #pts - 1, 2 do
            p:lineTo(V(pts[i], pts[i + 1]))
        end
        p:close()
    end
    local function limb(p: Path, ax: number, ay: number, bx: number, by: number, cx: number, cy: number)
        -- a quadratic bend, written as the equivalent cubic
        p:moveTo(V(ax, ay))
        p:cubicTo(V(ax + (bx - ax) * 2 / 3, ay + (by - ay) * 2 / 3), V(cx + (bx - cx) * 2 / 3, cy + (by - cy) * 2 / 3), V(cx, cy))
    end
    local function lerp(a: number, b: number, k: number): number
        return a + (b - a) * k
    end

    if c.kind == 'ghoul' then
        -- crouched on the parapet, ears like a donkey's; lit, it rears up and
        -- throws its claws over its head
        local rise = -10 * h
        local body = part(nil, 0)
        poly(body, { -9, 16, -14, 0 + rise, -16, -10 + rise, -6, -17 + rise, 6, -17 + rise, 16, -10 + rise, 14, 0 + rise, 9, 16 })
        ell(body, 0, -28 + rise, 11, 13)
        local ear = 4 * h
        poly(body, { -7, -36 + rise, -21 - ear, -52 + rise + ear, -2, -39 + rise })
        poly(body, { 7, -36 + rise, 21 + ear, -52 + rise + ear, 2, -39 + rise })
        local legs = part(nil, 5)
        limb(legs, -7, 14, -20, 22, -14, 38)
        limb(legs, 7, 14, 20, 22, 14, 38)
        local arms = part(nil, 4.5)
        local sw = math.sin(t * 1.8) * 2
        local lex, ley = lerp(-27, -32, h), lerp(6, -22, h) + rise
        local lhx, lhy = lerp(-23, -42, h) + sw, lerp(31, -50, h) + rise
        limb(arms, -15, -8 + rise, lex, ley, lhx, lhy)
        limb(arms, 15, -8 + rise, -lex, ley, -lhx + sw * 0.5, lhy)
        local claws = part(nil, 2)
        for side = -1, 1, 2 do
            local hx = if side < 0 then lhx else -lhx + sw * 0.5
            for k = -1, 1 do
                local a = (if h > 0.5 then -math.pi / 2 else math.pi / 2) + k * 0.45 + side * 0.25
                claws:moveTo(V(hx, lhy))
                claws:lineTo(V(hx + math.cos(a) * 7, lhy + math.sin(a) * 7))
            end
        end
    elseif c.kind == 'silewa' then
        -- behind Umm Georges' laundry, all hair; lit, the hair whips and she
        -- ducks behind the sheets
        local duck = 9 * h
        local hx = -6 * h
        local body = part(nil, 0)
        poly(body, { -12, 2 + duck, 12, 2 + duck, 20, 52, -20, 52 })
        ell(body, hx, -14 + duck, 11, 13)
        local hair = part(HAIR, 2.6)
        local amp = 3 + 12 * h
        local spd = 1.2 + 6 * h
        for i = 0, 10 do
            local u = i / 10
            local sx = hx - 12 + u * 24
            local len = 54 + math.sin(i * 2.3) * 8
            local wv = math.sin(t * spd + i * 0.7) * amp
            limb(hair, sx, -24 + duck + math.abs(u - 0.5) * 8, sx + (u - 0.5) * 18 + wv * 0.4, 10 + duck, sx + (u - 0.5) * 26 + wv, -20 + len)
        end
    elseif c.kind == 'qarina' then
        -- your twin in the arch; she steps the other way, and lit, she lifts
        -- her own phone at you
        local ox = math.max(-12, math.min(12, (640 - self.torch.x) * 0.03))
        local tall = 1 + 0.18 * h
        local body = part(nil, 0)
        ell(body, ox, -22 * tall, 8.5, 10.5)
        poly(body, { ox - 4, -12 * tall, ox + 4, -12 * tall, ox + 14, -4 * tall, ox + 16, 20, ox + 21, 66, ox - 21, 66, ox - 16, 20, ox - 14, -4 * tall })
        local arms = part(nil, 4)
        limb(arms, ox - 12, -2 * tall, ox - 18, 18, ox - 15, 36)
        local hx, hy = ox + lerp(17, 15, h), lerp(34, -40, h)
        limb(arms, ox + 12, -2 * tall, ox + lerp(20, 26, h), lerp(16, -10, h), hx, hy)
        local phone = part({ 30, 30, 36 }, 0)
        poly(phone, { hx - 3, hy - 9, hx + 3, hy - 9, hx + 3, hy + 1, hx - 3, hy + 1 })
    elseif c.kind == 'ifrit' then
        -- a column of generator smoke with horns; lit, it swells and burns
        local body = part(nil, 0)
        local grow = 1 + 0.25 * h
        for i = 0, 6 do
            local u = i / 6
            local sx = math.sin(t * (2 + 4 * h) + i * 1.1) * (3 + 5 * h) * (1 - u * 0.5)
            ell(body, sx, 50 - u * 52 * grow, (5 + u * 11) * (1 + 0.15 * math.sin(t * 5 + i)), 7 + u * 4)
        end
        ell(body, 0, -12 * grow, 15 + 3 * h, 13 + 2 * h)
        local horns = part(nil, 4)
        local hl = 1 + 0.5 * h
        limb(horns, -9, -20 * grow, -24 * hl, -26 * grow, -17 * hl, -44 * hl * grow)
        limb(horns, 9, -20 * grow, 24 * hl, -26 * grow, 17 * hl, -44 * hl * grow)
        local arms = part(nil, 4)
        limb(arms, -12, 2, -30, 8 - 10 * h, -32 - 6 * h, -10 - 16 * h)
        limb(arms, 12, 2, 30, 8 - 10 * h, 32 + 6 * h, -10 - 16 * h)
    elseif c.kind == 'abukees' then
        -- an old man in a tarboush with a sack on his back; lit, whatever is
        -- in the sack starts kicking
        local kick = math.sin(t * 15) * 3 * h + math.sin(t * 1.8) * 1.2
        local sack = part({ 70, 56, 40 }, 0)
        ell(sack, 21 + kick * 0.4, -12, 17 + math.abs(kick) * 0.5, 20 + kick)
        poly(sack, { 14, -32, 22, -38, 26, -30 })
        local body = part(nil, 0)
        poly(body, { -14, -17, -4, -19, 12, -16, 17, 8, 15, 48, -19, 48, -16, 8 })
        ell(body, -10, -27, 9, 10)
        poly(body, { -17, -29, -27, -21, -16, -21 }) -- the nose
        local fez = part({ 112, 24, 26 }, 0)
        poly(fez, { -18, -33, -3, -33, -6, -45, -15, -45 })
        local tassel = part(nil, 1.5)
        limb(tassel, -10, -45, -4, -44, -2 + math.sin(t * 3) * 2, -34)
        local arm = part(nil, 4)
        limb(arm, -8, -12, -14, 2, -21, 8)
        local cane = part({ 60, 44, 30 }, 3)
        limb(cane, -21, 4, -24, 26, -28, 48)
        local rope = part({ 90, 74, 52 }, 2)
        limb(rope, -6, -16, 6, -26, 20, -32)
    else
        -- the neighbours' cat on the wall; lit, it stands, arches and puffs
        local body = part(nil, 0)
        local up = h
        ell(body, 3, lerp(-6, -16, up), lerp(12, 15, up), lerp(13, 9, up))
        ell(body, -6, lerp(-10, -16, up), 8, 9)
        local hy = lerp(-22, -20, up)
        ell(body, -13, hy, 7, 6.5)
        local flat = 4 * up
        poly(body, { -18, hy - 4, -18 + flat * 0.5, hy - 13 + flat, -13, hy - 6 })
        poly(body, { -11, hy - 6, -7 - flat * 0.5, hy - 13 + flat, -7, hy - 3 })
        if up > 0.05 then
            local legs = part(nil, 3.5)
            limb(legs, -8, -10, -9, 0, -10, 10)
            limb(legs, -2, -10, -2, 0, -3, 10)
            limb(legs, 8, -10, 9, 0, 10, 10)
            limb(legs, 13, -10, 15, 0, 15, 10)
        end
        local tail = part(nil, 3 + 5 * up)
        local wag = math.sin(t * (1.5 + 5 * up)) * (4 + 2 * up)
        limb(tail, 13, lerp(4, -12, up), lerp(30, 24, up), lerp(8, -18, up) + wag * 0.3, lerp(26, 22, up) + wag, lerp(-10, -40, up))
    end
    return parts
end

-- eyes: centre (relative), half gap, radii, one or two, pupil
type Eyes = { dx: number, dy: number, gap: number, rx: number, ry: number, one: boolean, pupil: string }

local function eyesOf(self: Scene, c: Creature): Eyes
    local h = c.heat
    if c.kind == 'ghoul' then
        return { dx = 0, dy = -29 - 10 * h, gap = 5, rx = 3.2, ry = 3.2, one = false, pupil = 'dot' }
    elseif c.kind == 'silewa' then
        return { dx = -6 * h + 4, dy = -14 + 9 * h, gap = 0, rx = 2.6, ry = 2.6, one = true, pupil = 'dot' }
    elseif c.kind == 'qarina' then
        local ox = math.max(-12, math.min(12, (640 - self.torch.x) * 0.03))
        return { dx = ox, dy = -22 * (1 + 0.18 * h), gap = 3.6, rx = 2, ry = 2, one = false, pupil = 'none' }
    elseif c.kind == 'ifrit' then
        return { dx = 0, dy = -12 * (1 + 0.25 * h), gap = 6, rx = 4.2, ry = 1.8 + 1.2 * h, one = false, pupil = 'slit' }
    elseif c.kind == 'abukees' then
        return { dx = -13, dy = -28, gap = 0, rx = 2, ry = 2, one = true, pupil = 'dot' }
    end
    return { dx = -13, dy = -22 + 2 * h, gap = 3.2, rx = 2.2 + 0.8 * h, ry = 2.2 + 0.8 * h, one = false, pupil = 'slit' }
end

local function drawEyes(self: Scene, r: Renderer, c: Creature, open: number, full: boolean)
    if open <= 0.02 then
        return
    end
    local e = eyesOf(self, c)
    local sc = c.sc
    local stare = 1 + c.dwell * 0.5
    local x = c.px + math.sin(self.t * 60) * c.dwell * 2.5 + e.dx * sc
    local y = c.py + e.dy * sc
    local rx = e.rx * sc * stare
    local ry = e.ry * sc * stare * open
    local p = Path.new()
    if e.one then
        ellipse(p, x, y, rx, ry)
    else
        ellipse(p, x - e.gap * sc, y, rx, ry)
        ellipse(p, x + e.gap * sc, y, rx, ry)
    end
    fill(self, r, p, mixc(c.eyes, rgb(255, 255, 255), c.heat * 0.2))
    if full and e.pupil ~= 'none' and open > 0.4 then
        -- pupils follow the torch
        local dx = clamp01((self.torch.x - c.px) / 300 + 0.5) * 2 - 1
        local dy = clamp01((self.torch.y - c.py) / 300 + 0.5) * 2 - 1
        local pp = Path.new()
        local prx = if e.pupil == 'slit' then rx * 0.28 else rx * 0.45
        local pry = if e.pupil == 'slit' then ry * 0.9 else ry * 0.45
        local ox = dx * rx * 0.35
        local oy = dy * ry * 0.3
        if e.one then
            ellipse(pp, x + ox, y + oy, prx, pry)
        else
            ellipse(pp, x - e.gap * sc + ox, y + oy, prx, pry)
            ellipse(pp, x + e.gap * sc + ox, y + oy, prx, pry)
        end
        fill(self, r, pp, BLACK)
    end
end

-- what glows on a jinn besides its eyes, in the emission
local function drawJinnLights(self: Scene, r: Renderer, c: Creature, a: number)
    local h = c.heat
    local sc = c.sc
    local t = self.t
    local x = c.px
    local y = c.py
    if c.kind == 'ghoul' and h > 0.1 then
        -- the mouth opens, and it has too many teeth
        local rise = -10 * h
        local m = Path.new()
        ellipse(m, x, y + (-20 + rise) * sc, 6.5 * sc, (1 + 4.5 * h) * sc)
        fill(self, r, m, mixc(BLACK, rgb(210, 36, 24), h * a))
        local teeth = Path.new()
        for k = -2, 2 do
            local tx = x + k * 2.6 * sc
            local ty = y + (-20 + rise - 4.5 * h) * sc
            teeth:moveTo(Vector.xy(tx - 1.1 * sc, ty))
            teeth:lineTo(Vector.xy(tx + 1.1 * sc, ty))
            teeth:lineTo(Vector.xy(tx, ty + 2.6 * h * sc))
            teeth:close()
        end
        fill(self, r, teeth, mixc(BLACK, rgb(240, 230, 210), h * a))
    elseif c.kind == 'ifrit' then
        -- an ember in its chest, always smouldering, roaring when lit
        local fl = 0.85 + 0.15 * math.sin(t * 23) * math.sin(t * 7)
        local f = Path.new()
        ellipse(f, x, y + 8 * sc, (4 + 4 * h) * fl * sc, (6 + 9 * h) * fl * sc)
        fill(self, r, f, mixc(BLACK, rgb(255, 110, 24), (0.25 + 0.6 * h) * a))
        local core = Path.new()
        ellipse(core, x, y + 9 * sc, (1.5 + 2 * h) * sc, (3 + 4 * h) * sc)
        fill(self, r, core, mixc(BLACK, rgb(255, 220, 140), (0.3 + 0.7 * h) * a))
    elseif c.kind == 'qarina' and h > 0.15 then
        -- her phone light, pointed back at you
        local ox = math.max(-12, math.min(12, (640 - self.torch.x) * 0.03))
        local hx = x + (ox + 15 + 0 * h) * sc
        local hy = y + (34 + (-40 - 34) * h) * sc
        local k = smooth(0.15, 0.7, h) * a
        local sp = Path.new()
        ellipse(sp, hx, hy - 6 * sc, 3.2 * sc, 3.2 * sc)
        fill(self, r, sp, mixc(BLACK, rgb(255, 255, 255), k))
        local flare = Path.new()
        rect(flare, hx - 16 * sc, hy - 6.5 * sc, 32 * sc, 1 * sc)
        rect(flare, hx - 0.5 * sc, hy - 18 * sc, 1 * sc, 24 * sc)
        fill(self, r, flare, mixc(BLACK, rgb(220, 230, 255), k * 0.7))
    elseif c.kind == 'abukees' and h > 0.25 then
        -- he grins
        local g = Path.new()
        g:moveTo(Vector.xy(x - 18 * sc, y - 21 * sc))
        g:cubicTo(Vector.xy(x - 16 * sc, y - 18 * sc), Vector.xy(x - 10 * sc, y - 18 * sc), Vector.xy(x - 8 * sc, y - 21 * sc))
        self.stroke.color = mixc(BLACK, rgb(255, 230, 160), smooth(0.25, 0.8, h) * a)
        self.stroke.thickness = 1.4 * sc
        r:drawPath(g, self.stroke)
    end
end

-- the body in the albedo (its own tones at alpha `a`), or every part in one
-- colour (`over`) for the glow of a fleeing jinn
local BODY = { 54, 45, 62 }
local function drawParts(self: Scene, r: Renderer, parts: { Part }, a: number, over: Color?, rim: number?)
    for _, pt in parts do
        if rim ~= nil then
            -- a spectral rim: the fills' outlines only
            if pt.width == 0 and over ~= nil then
                self.stroke.color = over
                self.stroke.thickness = rim
                r:drawPath(pt.path, self.stroke)
            end
            continue
        end
        local col: Color
        if over ~= nil then
            col = over
        else
            local tn = pt.tone or BODY
            col = Color.rgba(tn[1], tn[2], tn[3], math.floor(255 * a))
        end
        if pt.width > 0 then
            self.stroke.color = col
            self.stroke.thickness = pt.width
            r:drawPath(pt.path, self.stroke)
        else
            fill(self, r, pt.path, col)
        end
    end
end

local function eyePair(self: Scene, r: Renderer, x: number, y: number, gap: number, size: number, c: Color, open: number)
    if open <= 0.02 then
        return
    end
    local p = Path.new()
    ellipse(p, x - gap, y, size, size * open)
    ellipse(p, x + gap, y, size, size * open)
    fill(self, r, p, c)
end

local function present(self: Scene): number
    if self.phase == 3 then
        return 1
    end
    return smooth(0.5, 0.95, self.dark) * (1 - self.lights)
end

local function drawFlag(self: Scene, r: Renderer)
    -- the cedar flag on the neighbour's roof, never taken down
    local t = self.t
    local x0 = 61
    local y0 = 152
    local fw = 52
    local fh = 34
    local function wave(u: number, v: number): Vector
        local dy = math.sin(t * 3.2 - u * 5) * 3 * u
        return Vector.xy(x0 + u * fw, y0 + v * fh + dy)
    end
    local function band(v0: number, v1: number, col: Color)
        local p = Path.new()
        p:moveTo(wave(0, v0))
        for k = 1, 8 do p:lineTo(wave(k / 8, v0)) end
        for k = 8, 0, -1 do p:lineTo(wave(k / 8, v1)) end
        p:close()
        fill(self, r, p, col)
    end
    band(0, 0.25, rgb(214, 40, 40))
    band(0.25, 0.75, rgb(240, 240, 236))
    band(0.75, 1, rgb(214, 40, 40))
    local cedar = Path.new()
    local c0 = wave(0.5, 0.5)
    local cx = c0.x
    local cy = c0.y
    for k = 0, 2 do
        local ty = cy - 9 + k * 5
        local hw = 4 + k * 3
        cedar:moveTo(Vector.xy(cx, ty))
        cedar:lineTo(Vector.xy(cx + hw, ty + 6))
        cedar:lineTo(Vector.xy(cx - hw, ty + 6))
        cedar:close()
    end
    rect(cedar, cx - 1, cy + 6, 2, 4)
    fill(self, r, cedar, rgb(30, 140, 70))
end

local function drawStreetAlbedo(self: Scene, r: Renderer)
    local t = self.t
    -- no sky here: what stays transparent is sky, and the shader paints it
    for _, sh in self.static do
        fill(self, r, sh.path, sh.color)
    end
    -- the moteur, shaking on its mounts
    local gx = math.sin(t * 61) * 1.4 * self.rumble
    local gy = math.sin(t * 47 + 1) * 0.9 * self.rumble
    r:save()
    r:transform(Mat2D.values(1, 0, 0, 1, gx, gy))
    for _, sh in self.generator do
        fill(self, r, sh.path, sh.color)
    end
    r:restore()
    drawFlag(self, r)
    -- window glass (dark)
    local glass = Path.new()
    for _, w in self.windows do
        if w.arch then arch(glass, w.x, w.y, w.w, w.h) else rect(glass, w.x, w.y, w.w, w.h) end
    end
    fill(self, r, glass, GLASS)
    -- Umm Georges' laundry, swinging on the balcony
    local line = Path.new()
    line:moveTo(Vector.xy(580, 342))
    line:cubicTo(Vector.xy(620, 349), Vector.xy(660, 349), Vector.xy(700, 342))
    self.stroke.color = rgb(200, 200, 200)
    self.stroke.thickness = 1
    r:drawPath(line, self.stroke)
    local cloth = { { 588, 20, 30, rgb(220, 70, 70) }, { 616, 26, 40, rgb(240, 240, 230) }, { 652, 18, 26, rgb(80, 120, 200) }, { 676, 16, 22, rgb(250, 200, 60) } }
    local silewa = self.creatures[2]
    local gust = if silewa ~= nil then silewa.heat * 6 else 0
    for i, cl in cloth do
        local cx = cl[1] :: number
        local cw = cl[2] :: number
        local ch = cl[3] :: number
        local swing = math.sin(t * (1.6 + gust) + i) * (3 + gust) * (1 + self.dark)
        local cp = Path.new()
        local top = 345 + math.sin((cx - 580) / 120 * math.pi) * 5
        cp:moveTo(Vector.xy(cx, top))
        cp:lineTo(Vector.xy(cx + cw, top))
        cp:lineTo(Vector.xy(cx + cw + swing, top + ch))
        cp:lineTo(Vector.xy(cx + swing, top + ch))
        cp:close()
        fill(self, r, cp, cl[4] :: Color)
    end
    -- the jinn's bodies: dark matter, only the torch reveals them
    local pr = present(self)
    for _, c in self.creatures do
        local a = pr * c.alpha
        if self.phase ~= 3 and c.found and c.gone > 1.4 then
            a = 0
        end
        if a > 0.01 then
            drawParts(self, r, bodyParts(self, c), a, nil)
        end
    end
    drawCables(self, r)
    -- smoke
    for _, pf in self.puffs do
        local a = clamp01(1 - pf.life / pf.max) * 0.32
        local pp = Path.new()
        ellipse(pp, pf.x, pf.y, pf.r * (1 + pf.life), pf.r * (1 + pf.life))
        fill(self, r, pp, Color.rgba(120, 118, 126, math.floor(255 * a)))
    end
end

local function drawWindowLife(self: Scene, r: Renderer, w: Window, c: Color, lit: number)
    local t = self.t
    -- the lamp: a warm pool near the ceiling
    local lamp = Path.new()
    ellipse(lamp, w.x + w.w / 2, w.y + 9, w.w * 0.3, 8)
    fill(self, r, lamp, mixc(BLACK, mixc(c, rgb(255, 236, 200), 0.3), lit * 0.92))
    local bulb = Path.new()
    ellipse(bulb, w.x + w.w / 2, w.y + 7, 3, 3)
    fill(self, r, bulb, mixc(BLACK, rgb(255, 250, 235), lit))
    -- the floor and furniture, darker
    local low = Path.new()
    rect(low, w.x, w.y + w.h * 0.78, w.w, w.h * 0.22)
    fill(self, r, low, mixc(BLACK, c, lit * 0.55))
    local kind = hash(w.phase * 3.7)
    if not w.tv and kind < 0.6 then
        -- curtains, with a fold of light in each
        local cw = w.w * 0.26
        local cp = Path.new()
        rect(cp, w.x, w.y, cw, w.h)
        rect(cp, w.x + w.w - cw, w.y, cw, w.h)
        fill(self, r, cp, mixc(BLACK, w.curtain, lit * 0.85))
        local fold = Path.new()
        rect(fold, w.x + cw * 0.45, w.y, 2, w.h)
        rect(fold, w.x + w.w - cw * 0.55, w.y, 2, w.h)
        fill(self, r, fold, mixc(BLACK, w.curtain, lit * 0.55))
    end
    if (kind > 0.45 and kind < 0.72) or w.tv then
        -- someone at home: walking past, or slumped in front of the TV
        local px = w.x + w.w * (0.5 + 0.28 * math.sin(t * 0.35 + w.phase))
        if w.tv then px = w.x + w.w * 0.36 end
        local base = w.y + w.h
        local who = Path.new()
        local hh = math.min(w.h * 0.62, 46)
        ellipse(who, px, base - hh, 5.5, 6.5)
        who:moveTo(Vector.xy(px - 3, base - hh + 5))
        who:lineTo(Vector.xy(px + 3, base - hh + 5))
        who:lineTo(Vector.xy(px + 3, base - hh + 9))
        who:cubicTo(Vector.xy(px + 12, base - hh + 10), Vector.xy(px + 13, base - hh + 16), Vector.xy(px + 13, base))
        who:lineTo(Vector.xy(px - 13, base))
        who:cubicTo(Vector.xy(px - 13, base - hh + 16), Vector.xy(px - 12, base - hh + 10), Vector.xy(px - 3, base - hh + 9))
        who:close()
        fill(self, r, who, mixc(BLACK, c, lit * 0.22))
    end
end

local function drawStreetEmit(self: Scene, r: Renderer, feather: number)
    self.paint.feather = feather
    local t = self.t
    local full = feather == 0
    -- moon
    local moon = Path.new()
    ellipse(moon, 1110, 118, 56, 56)
    fill(self, r, moon, rgb(232, 236, 250))
    if full then
        local crater = Path.new()
        ellipse(crater, 1092, 104, 12, 10)
        ellipse(crater, 1128, 134, 9, 8)
        ellipse(crater, 1120, 96, 6, 5)
        fill(self, r, crater, rgb(198, 204, 224))
        -- stars, more of them when the city goes dark
        local stars = Path.new()
        local n = math.floor(50 + 90 * self.dark)
        for i = 1, n do
            local sx = -80 + hash(i * 3.1) * (W + 160)
            local sy = -20 + hash(i * 7.7) * 320
            local tw = 0.6 + 0.4 * math.sin(t * (1 + hash(i)) * 2 + i)
            local s = (0.6 + hash(i * 1.9) * 1.1) * tw
            ellipse(stars, sx, sy, s, s)
        end
        fill(self, r, stars, rgb(200, 210, 255))
    end

    -- windows
    local gen = self.power == 2
    for _, w in self.windows do
        local on = self.lights
        if gen and not w.sub then
            on = 0
        end
        if on > 0.01 then
            local c = w.warm
            if w.tv then
                local f = 0.6 + 0.4 * math.sin(t * 7 + w.phase) * math.sin(t * 2.3 + w.phase)
                c = Color.lerp(rgb(110, 150, 255), rgb(200, 220, 255), f)
            end
            local p = Path.new()
            if w.arch then arch(p, w.x, w.y, w.w, w.h) else rect(p, w.x, w.y, w.w, w.h) end
            local flick = 1 - 0.06 * hash(math.floor(t * 12) + w.phase)
            local lit = on * flick
            fill(self, r, p, mixc(BLACK, c, lit * 0.8))
            if full then
                drawWindowLife(self, r, w, c, lit)
            end
        end
    end
    -- a candle in Teta's window when the power is cut
    if self.dark > 0.5 then
        local fl = 0.85 + 0.15 * math.sin(t * 17) * math.sin(t * 5.3)
        local sway = math.sin(t * 3.1) * 0.8
        local p = Path.new()
        p:moveTo(Vector.xy(870 + sway * 2, 634 - 4 * fl))
        p:cubicTo(Vector.xy(874, 640), Vector.xy(873.5, 646), Vector.xy(870, 646))
        p:cubicTo(Vector.xy(866.5, 646), Vector.xy(866, 640), Vector.xy(870 + sway * 2, 634 - 4 * fl))
        fill(self, r, p, rgb(255, 196, 96))
        if full then
            local core = Path.new()
            ellipse(core, 870, 643, 1.4, 2.4)
            fill(self, r, core, rgb(255, 250, 220))
            local wax = Path.new()
            rect(wax, 867, 647, 6, 16)
            fill(self, r, wax, rgb(120, 96, 70))
        else
            local halo = Path.new()
            ellipse(halo, 870, 644, 26 * fl, 26 * fl)
            fill(self, r, halo, rgb(150, 80, 30))
        end
    end
    -- street lamp
    if self.lights > 0.05 then
        local p = Path.new()
        ellipse(p, 918, 442, 18, 7)
        fill(self, r, p, mixc(BLACK, rgb(255, 200, 130), self.lights))
    end
    -- the generator's lamp
    if self.power == 2 then
        local p = Path.new()
        ellipse(p, 60, 640, 5, 5)
        fill(self, r, p, if math.floor(t * 2) % 2 == 0 then rgb(80, 255, 120) else rgb(10, 60, 20))
    end

    -- eyes in the dark, and the jinn caught mid-flight
    local pr = present(self)
    self.paint.feather = feather * 0.25
    for _, c in self.creatures do
        local shown = (not c.found) or self.phase == 3
        if shown and pr > 0.01 then
            local cycle = c.blink % 4.2
            local open = if cycle < 0.14 then math.abs(cycle - 0.07) / 0.07 else 1
            if c.kind == 'silewa' then open *= 1 - 0.4 * c.heat end
            local vis = pr * c.alpha
            if full and c.heat > 0.03 then
                drawParts(self, r, bodyParts(self, c), 1, mixc(BLACK, c.eyes, 0.35 * c.heat * vis), 1.4)
            end
            if full and self.phase == 3 then
                -- on the parapet the moteur's windows light them from below:
                -- a warm rim, so the six read against the night sky
                drawParts(self, r, bodyParts(self, c), 1, mixc(BLACK, rgb(255, 186, 112), 0.62 * vis), 1.8)
            end
            drawEyes(self, r, c, open * vis, full)
            drawJinnLights(self, r, c, vis)
        end
        if c.found and self.phase ~= 3 and c.gone < 1.4 and c.alpha > 0.01 then
            -- a caught jinn burns in its own colour as it flees
            local a = c.alpha * (1 - c.gone / 1.4)
            drawParts(self, r, bodyParts(self, c), a, mixc(BLACK, c.eyes, 0.55 * a))
        end
        -- the lock-on ring: how long you have held the light on it
        if full and not c.found and c.dwell > 0.04 and self.phase == 1 then
            local ring = Path.new()
            local prog = clamp01(c.dwell / DWELL)
            local rr = c.r * 0.95
            local n = math.max(2, math.floor(40 * prog))
            for i = 0, n do
                local a = -math.pi / 2 + (i / 40) * math.pi * 2
                local v = Vector.xy(c.x + math.cos(a) * rr, c.y + math.sin(a) * rr)
                if i == 0 then ring:moveTo(v) else ring:lineTo(v) end
            end
            self.stroke.color = mixc(BLACK, c.eyes, 0.85)
            self.stroke.thickness = 2.5
            r:drawPath(ring, self.stroke)
        end
    end
    -- sparks off the wires
    for _, sp in self.sparks do
        local a = clamp01(1 - sp.life / sp.max)
        local sk = Path.new()
        sk:moveTo(Vector.xy(sp.x, sp.y))
        sk:lineTo(Vector.xy(sp.x - sp.vx * 0.025, sp.y - sp.vy * 0.025))
        self.stroke.color = mixc(BLACK, mixc(rgb(255, 120, 40), rgb(255, 250, 210), a), a)
        self.stroke.thickness = if full then 2 else 5
        r:drawPath(sk, self.stroke)
    end
    -- the battery died: the whole building opens its eyes
    if self.dead >= 0 then
        local n = math.floor(math.min(70, self.dead * 55))
        for i = 1, n do
            local ex = -40 + hash(i * 2.7) * (W + 80)
            local ey = 120 + hash(i * 5.3) * (H - 200)
            local cycle = (t * 0.7 + hash(i)) % 3
            local open = if cycle < 0.12 then 0.2 else 1
            eyePair(self, r, ex, ey, 4.5 + hash(i) * 5, 2.6 + hash(i * 9) * 3.2, if hash(i * 11) > 0.5 then rgb(255, 60, 40) else rgb(255, 220, 120), open)
        end
    end
end

function draw(self: Scene, renderer: Renderer)
    local albedo = self.albedo
    local emit = self.emit
    local glow = self.glow
    local gpu = self.gpu
    local pipeline = self.pipeline
    local bind = self.bind
    local ubo = self.ubo
    if albedo == nil or emit == nil or glow == nil or gpu == nil or pipeline == nil or bind == nil or ubo == nil then
        return
    end
    local q = self.pxScale * quality(self)
    local a, bx, by = cam(self)
    local xf = Mat2D.values(a * q, 0, 0, a * q, bx * q, by * q)

    local ra = albedo:beginFrame()
    ra:save()
    ra:transform(xf)
    drawStreetAlbedo(self, ra)
    ra:restore()
    albedo:endFrame()

    local re = emit:beginFrame()
    re:save()
    re:transform(xf)
    drawStreetEmit(self, re, 0)
    re:restore()
    emit:endFrame()

    -- the same light, a quarter size and feathered: the shader's bloom and spill
    local rg = glow:beginFrame()
    rg:save()
    rg:transform(Mat2D.values(a * q / 4, 0, 0, a * q / 4, bx * q / 4, by * q / 4))
    drawStreetEmit(self, rg, 36)
    rg:restore()
    glow:endFrame()
    self.paint.feather = 0

    local torchOn = self.power == 0 and self.dead < 0 and self.phase ~= 3
    local torchI = if torchOn then 1 else 0
    if torchOn and self.battery < 12 then
        torchI = if hash(math.floor(self.t * 20)) > 0.35 then 1 else 0.25
    end
    local reach = 170 * (0.55 + 0.45 * self.battery / 100)

    local d = self.data
    buffer.writef32(d, 0, self.size.x * q)
    buffer.writef32(d, 4, self.size.y * q)
    buffer.writef32(d, 8, (self.torch.x * a + bx) * q)
    buffer.writef32(d, 12, (self.torch.y * a + by) * q)
    buffer.writef32(d, 16, self.t)
    buffer.writef32(d, 20, self.dark)
    buffer.writef32(d, 24, torchI)
    buffer.writef32(d, 28, reach * a * q)
    buffer.writef32(d, 32, self.lights)
    buffer.writef32(d, 36, 0.9 * self.dark * self.dark)
    buffer.writef32(d, 40, self.shock)
    buffer.writef32(d, 44, self.battery / 100)
    buffer.writef32(d, 48, a * q)
    buffer.writef32(d, 52, if self.dead >= 0 then 1 else 0)
    buffer.writef32(d, 56, self.rumble)
    buffer.writef32(d, 60, (by + 470 * a) * q) -- the horizon, in pixels
    buffer.writef32(d, 64, (1110 * a + bx) * q) -- the moon
    buffer.writef32(d, 68, (118 * a + by) * q)
    buffer.writef32(d, 72, 0)
    buffer.writef32(d, 76, 0)
    ubo:write(d)

    local pass = gpu:beginRenderPass({ color = { { loadOp = 'clear', storeOp = 'store', clearColor = { 0, 0, 0, 1 } } } })
    pass:setPipeline(pipeline)
    pass:setBindGroup(0, bind)
    pass:draw(3)
    pass:finish()
    renderer:save()
    renderer:transform(Mat2D.values(1 / q, 0, 0, 1 / q, 0, 0))
    renderer:drawImage(gpu.image, ImageSampler('clamp', 'clamp', 'bilinear'), 'srcOver', 1)
    renderer:restore()
end

return function(context: Context): Layout<Scene>
    return {
        ctx = context,
        size = Vector.xy(0, 0),
        pxScale = 1,
        t = 0,
        mouse = Vector.xy(640, 430),
        torch = Vector.xy(640, 430),
        albedo = nil,
        emit = nil,
        glow = nil,
        gpu = nil,
        pipeline = nil,
        ubo = nil,
        bind = nil,
        sampler = GPUSampler.new({ min = 'linear', mag = 'linear' }),
        data = buffer.create(80),
        paint = Paint.with({ color = Color.rgb(255, 255, 255) }),
        stroke = Paint.with({ style = 'stroke', thickness = 2, color = Color.rgb(0, 0, 0), cap = 'round', join = 'round' }),
        static = {},
        generator = {},
        windows = {},
        creatures = {},
        cables = {},
        puffs = {},
        sparks = {},
        power = 1,
        phase = 0,
        cutT = 0,
        endT = 0,
        dark = 0,
        lights = 1,
        rumble = 0,
        battery = 100,
        found = 0,
        shock = 0,
        dead = -1,
        sparkClock = 1.5,
        caption = '',
        captionAr = '',
        vmPower = nil,
        vmBattery = nil,
        vmLevel = nil,
        vmFound = nil,
        vmFoundCount = nil,
        vmCaption = nil,
        vmCaptionAr = nil,
        vmCardAr = nil,
        vmCardEn = nil,
        vmPhase = nil,
        vmAuto = nil,
        vmLights = nil,
        vmQuality = nil,
        auto = false,
        init = init,
        resize = resize,
        advance = advance,
        pointerMove = pointerMove,
        pointerDown = pointerDown,
        draw = draw,
    }
end
