#!/usr/bin/env python3
"""Writes scene.rml: the words, the cards, the HUD and the changeover switch
around the scripted street, and the state machine that runs the story.

Generated so the switch rows, the six card states and their keyed animations
stay in step, but every number in here (positions, frames, curves) was placed
and tuned by hand against screenshots. Run from the project root:

    python3 tools/gen_scene.py && rive . --verify

Draw order in Rive: earlier siblings draw ON TOP, so every group lists its
foreground first and its background last.
"""

FONT = {'display': '0:31', 'regular': '0:32', 'semibold': '0:33'}
FAMILY = {'display': ('Lalezar', 'Regular'), 'regular': ('IBM Plex Sans Arabic', 'Regular'),
          'semibold': ('IBM Plex Sans Arabic', 'SemiBold')}

_ids = iter(range(2000, 9000))


def nid():
    return f'0:{next(_ids)}'


# The script draws the street through a camera (main.luau: ZOOM, CAM_Y).
# Anything in the markup that sits ON the street goes through the same map.
ZOOM, CAM_Y = 0.88, 22


def street(x, y):
    return round(640 + (x - 640) * ZOOM, 1), round(y * ZOOM + CAM_Y, 1)


def text(name, x, y, content, font, size, color, bind=None, extra='', spacing=0, ind=8, tid=None, op_bind=None):
    fam, sty = FAMILY[font]
    sid = nid()
    pad = ' ' * ind
    ls = f' letterSpacing="{spacing}"' if spacing else ''
    run_bind = f'\n{pad}        <DataBindContext sourcePathIds="0:900-{bind}" propertyKey="268"/>\n{pad}    ' if bind else ''
    run = (f'<TextValueRun styleId="{sid}" text="{content}" name="Run">{run_bind}</TextValueRun>' if bind
           else f'<TextValueRun styleId="{sid}" text="{content}" name="Run"/>')
    opb = ''
    if op_bind:
        src, conv = op_bind
        cv = f' converterId="{conv}"' if conv else ''
        opb = f'\n{pad}    <DataBindContext sourcePathIds="0:900-{src}" propertyKey="18"{cv}/>'
    return f'''{pad}<Text x="{x}" y="{y}" {extra} name="{name}" id="{tid or nid()}">{opb}
{pad}    <TextStylePaint fontSize="{size}" fontAssetId="{FONT[font]}" familyName="{fam}" styleName="{sty}"{ls} name="{name} Style" id="{sid}">
{pad}        <Fill name="Fill"><SolidColor colorValue="{color}" name="C"/></Fill>
{pad}    </TextStylePaint>
{pad}    {run}
{pad}</Text>'''


def rrect(name, x, y, w, h, r, fill=None, stroke=None, sw=2, ox=0, oy=0, ind=8, rect_inner='', sid=None,
          fill_id=None, grad=None, extra=''):
    pad = ' ' * ind
    parts = [f'{pad}<Shape x="{x}" y="{y}" {extra} name="{name}" id="{sid or nid()}">']
    rad = f' cornerRadiusTL="{r}" cornerRadiusTR="{r}" cornerRadiusBL="{r}" cornerRadiusBR="{r}" linkCornerRadius="false"' if r else ''
    if rect_inner:
        parts.append(f'{pad}    <Rectangle width="{w}" height="{h}" originX="{ox}" originY="{oy}"{rad} name="Path" id="{nid()}">{rect_inner}</Rectangle>')
    else:
        parts.append(f'{pad}    <Rectangle width="{w}" height="{h}" originX="{ox}" originY="{oy}"{rad} name="Path"/>')
    if grad:
        stops = ''.join(f'<GradientStop colorValue="{c}" position="{p}"/>' for c, p in grad[4])
        parts.append(f'{pad}    <Fill name="Fill"><LinearGradient startX="{grad[0]}" startY="{grad[1]}" endX="{grad[2]}" endY="{grad[3]}" name="G">{stops}</LinearGradient></Fill>')
    if fill:
        fid = f' id="{fill_id}"' if fill_id else ''
        parts.append(f'{pad}    <Fill name="Fill"><SolidColor colorValue="{fill}" name="C"{fid}/></Fill>')
    if stroke:
        parts.append(f'{pad}    <Stroke thickness="{sw}" name="Stroke"><SolidColor colorValue="{stroke}" name="C"/></Stroke>')
    parts.append(f'{pad}</Shape>')
    return '\n'.join(parts)


def dot(name, x, y, rx, ry, fill, ind=8, sid=None):
    pad = ' ' * ind
    return f'''{pad}<Shape x="{x}" y="{y}" name="{name}" id="{sid or nid()}">
{pad}    <Ellipse width="{rx * 2}" height="{ry * 2}" originX="0.5" originY="0.5" name="Path"/>
{pad}    <Fill name="Fill"><SolidColor colorValue="{fill}" name="C"/></Fill>
{pad}</Shape>'''


# --- keyframe helpers. Every curve below was picked by eye, not by preset.
def kf(value, frame, ease=None):
    """ease: None = hold, 'lin', ('cubic', x1, y1, x2, y2), ('elastic', amp, period)"""
    if ease is None:
        return f'<KeyFrameDouble value="{value}" frame="{frame}"/>'
    if ease == 'lin':
        return f'<KeyFrameDouble value="{value}" frame="{frame}" interpolationType="linear"/>'
    if ease[0] == 'cubic':
        _, x1, y1, x2, y2 = ease
        return (f'<KeyFrameDouble value="{value}" frame="{frame}" interpolationType="cubic">'
                f'<CubicEaseInterpolator x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"/></KeyFrameDouble>')
    _, amp, period = ease
    return (f'<KeyFrameDouble value="{value}" frame="{frame}" interpolationType="elastic">'
            f'<ElasticInterpolator easingValue="1" amplitude="{amp}" period="{period}"/></KeyFrameDouble>')


def keyed(obj, prop, frames):
    return (f'            <KeyedObject objectId="{obj}"><KeyedProperty propertyKey="{prop}">'
            + ''.join(frames) + '</KeyedProperty></KeyedObject>')


def keyed_color(obj, frames):
    body = ''.join(f'<KeyFrameColor value="{c}" frame="{f}"' + (' interpolationType="linear"/>' if lin else '/>')
                   for c, f, lin in frames)
    return f'            <KeyedObject objectId="{obj}"><KeyedProperty propertyKey="37">{body}</KeyedProperty></KeyedObject>'


# Curves with names, so the intent reads in the file:
SNAP_OUT = ('cubic', 0.16, 1, 0.3, 1)      # fast out, long soft landing: cards, titles
SLOW_IN = ('cubic', 0.55, 0, 0.85, 0.4)    # things leaving, unhurried
SETTLE = ('elastic', 0.6, 0.35)            # a small wobble, like a sticker slapped on
THROW = ('cubic', 0.3, 1.45, 0.55, 1)      # the lever: overshoot past the detent
X, Y, ROT, SX, SY, OP = 13, 14, 15, 16, 17, 18

CREAM = 'FFF2E8D5'
GOLD = 'FFFFC861'
MUTED = 'FFB9B3A6'
INK = 'E00A0C12'

# (power value, y offset, Arabic, English, lamp colour)
ROWS = [
    (1, -58, 'دولة', 'STATE POWER', 'FFFFC861'),
    (0, 0, 'مقطوعة', 'POWER CUT', 'FFE0484A'),
    (2, 58, 'موتير', 'GENERATOR', 'FF7CFF9A'),
]
CX, CY, SW_SCALE = 1180, 683, 0.86

# ids that animations key
TITLE, HINT, CARD, ENDCARD, PLATE, LEVER = '0:200', '0:210', '0:300', '0:400', '0:150', '0:120'
BATT_FILL, BATT_CASE = '0:220', '0:221'
DOTS = [f'0:{310 + i}' for i in range(6)]

out = []
A = out.append
A('<Rive version="1" kind="fragment">')
A('    <Artboard defaultStateMachineId="0:500" viewModelId="0:900" viewModelInstanceId="0:920" clip="true" width="1280" height="800" styleId="0:3" name="Kahraba" id="0:2">')
A('        <Fill name="Background"><SolidColor colorValue="FF05070D" name="C"/></Fill>')
A('        <LayoutComponentStyle name="Artboard Style" id="0:3"/>')

# ---- the changeover switch, bottom-right: on top of everything so it always takes the click
A(f'        <Node x="{CX}" y="{CY}" scaleX="{SW_SCALE}" scaleY="{SW_SCALE}" name="Switch" id="0:100">')
for i, (pv, dy, ar, en, lamp) in enumerate(ROWS):
    # transparent hit rows go first so nothing above them eats the click
    A(rrect(f'Hit {en}', 0, dy, 184, 58, 0, fill='00000000', ox=0.5, oy=0.5, ind=12, sid=f'0:{110 + i}'))
A(f'            <Node name="Plate Group" id="{PLATE}">')
A(f'                <Node x="-50" y="-58" name="Lever" id="{LEVER}">')
A(rrect('Knob Shine', 0, -5, 30, 4, 2, fill='66FFFFFF', ox=0.5, oy=0.5, ind=20))
A(rrect('Knob', 0, 0, 42, 28, 7, fill='FFB3261E', stroke='FF3A0C08', ox=0.5, oy=0.5, ind=20))
A('                </Node>')
for i, (pv, dy, ar, en, lamp) in enumerate(ROWS):
    A(f'''                <Shape x="-10" y="{dy}" name="Lamp {en}" id="0:{130 + i}">
                    <Ellipse width="11" height="11" originX="0.5" originY="0.5" name="Path"/>
                    <Fill name="Fill"><SolidColor colorValue="FF2A2C33" name="C" id="0:{135 + i}"/></Fill>
                </Shape>''')
    A(text(f'Label {en} Ar', 2, dy - 24, ar, 'display', 23, 'FF26221C', extra='sizingValue="autoWidth"', ind=16))
    A(text(f'Label {en} En', 3, dy + 6, en, 'semibold', 10, 'FF5C5446', extra='sizingValue="autoWidth"', spacing=1.2, ind=16))
A(rrect('Slot', -50, 0, 14, 140, 7, fill='FF1A1B20', ox=0.5, oy=0.5, ind=16))
A(text('Switch Title', -66, -112, 'INVERSEUR  ·  مفتاح', 'semibold', 10, 'FF5C5446', extra='sizingValue="autoWidth"', spacing=2, ind=16))
A(rrect('Screw TL', -78, -110, 6, 6, 3, fill='FFB8AE98', ox=0.5, oy=0.5, ind=16))
A(rrect('Screw BR', 78, 110, 6, 6, 3, fill='FFB8AE98', ox=0.5, oy=0.5, ind=16))
A(rrect('Plate', 0, 0, 184, 248, 16, fill='FFE9E1CC', stroke='FF8C8270', sw=3, ox=0.5, oy=0.5, ind=16))
A('            </Node>')
A(rrect('Plate Shadow', 5, 8, 184, 248, 16, fill='99000000', ox=0.5, oy=0.5, ind=12))
A('        </Node>')

# ---- the end card, centre
A(f'        <Node x="640" y="372" opacity="0" name="End Card" id="{ENDCARD}">')
A(text('End Ar', 0, -82, 'هالوين سعيد من بيروت', 'display', 58, GOLD, extra='sizingValue="autoWidth" originX="0.5"', ind=12))
A(text('End En', 0, 2, 'HAPPY HALLOWEEN FROM BEIRUT', 'semibold', 18, CREAM, extra='sizingValue="autoWidth" originX="0.5"', spacing=4, ind=12))
A(text('End Note', 0, 40, 'Six jinn found. Abu Ali\'s moteur saved the night.', 'regular', 15, MUTED, extra='sizingValue="autoWidth" originX="0.5"', ind=12))
A(text('End Again', 0, 70, 'Flip the switch to the dark to play again  ·  اقلب المفتاح عالعتمة لتلعب كمان', 'regular', 13, 'FF8F887B', extra='sizingValue="autoWidth" originX="0.5"', ind=12))
A(rrect('End Rule', 0, 34, 80, 2, 1, fill=GOLD, ox=0.5, oy=0.5, ind=12))
A(rrect('End Panel', 0, 0, 640, 228, 22, fill='EE0A0C12', stroke='66FFC861', sw=1.5, ox=0.5, oy=0.5, ind=12))
A('        </Node>')

# ---- the jinn card, left, under the title
A(f'        <Node x="34" y="116" opacity="0" name="Jinn Card" id="{CARD}">')
A(text('Card Ar', 300, 0, 'الغول', 'display', 46, GOLD, bind='0:910', extra='sizingValue="autoWidth" originX="1"', ind=12))
A(text('Card En', 22, 66, 'THE GHOUL', 'semibold', 12, CREAM, bind='0:911', extra='sizingValue="autoWidth"', spacing=2, ind=12))
A(rrect('Card Accent', 8, 14, 4, 74, 2, fill=GOLD, ind=12))
A(rrect('Card Panel', 0, 0, 320, 98, 16, fill=INK, ind=12))
A('        </Node>')

# ---- HUD chips, top right
A(text('Battery Text', 808, 30, '100%', 'semibold', 17, CREAM, bind='0:903', extra='sizingValue="autoWidth"'))
A(rrect('Battery Level', 759, 36, 34, 12, 2, fill='FF7CFF9A', fill_id=BATT_FILL,
        rect_inner='\n                <DataBindContext sourcePathIds="0:900-0:902" propertyKey="20" converterId="0:960"/>\n            '))
A(rrect('Battery Nub', 797, 38, 3, 8, 0, fill=CREAM))
A(f'        <Node x="776" y="42" name="Battery Case Group" id="{BATT_CASE}">')
A(rrect('Battery Case', 0, 0, 40, 18, 4, stroke=CREAM, sw=2, ox=0.5, oy=0.5, ind=12))
A('        </Node>')
A(rrect('Battery Chip', 740, 22, 142, 40, 20, fill=INK))
A(text('Jinn Count', 1236, 31, '0 / 6', 'semibold', 16, GOLD, bind='0:904', extra='sizingValue="autoWidth" originX="1"'))
for i, did in enumerate(DOTS):
    x = 1030 + i * 24
    A(f'        <Node x="{x}" y="42" opacity="0.22" name="Jinn Dot {i + 1}" id="{did}">')
    A(dot('Eye L', -4, 0, 2.6, 2.6, GOLD, ind=12))
    A(dot('Eye R', 4, 0, 2.6, 2.6, GOLD, ind=12))
    A('        </Node>')
A(text('Jinn Label', 914, 33, 'JINN FOUND', 'semibold', 12, MUTED, extra='sizingValue="autoWidth"', spacing=2))
A(rrect('Jinn Chip', 894, 22, 360, 40, 20, fill=INK))

# ---- title, top-left over the sky
A(f'        <Node x="0" y="0" name="Title" id="{TITLE}">')
A(text('Title Ar', 34, 6, 'كهربا', 'display', 80, GOLD, extra='sizingValue="autoWidth"', ind=12))
A(text('Title En', 190, 30, 'KAHRABA', 'display', 31, CREAM, extra='sizingValue="autoWidth"', spacing=3, ind=12))
A(text('Subtitle', 192, 70, 'a Beirut power-cut ghost story', 'regular', 15, MUTED, extra='sizingValue="autoWidth"', ind=12))
A('        </Node>')

# ---- subtitles, bottom-left, over the pavement
A(text('Caption En', 46, 729, 'Beirut, 8 PM. The state power is on. For now.', 'semibold', 18, CREAM, bind='0:905',
       extra='width="1004" height="28" sizingValue="fixed" overflowValue="fitFontSize"'))
A(text('Caption Ar', 46, 755, 'بيروت، الساعة ٨. كهربا الدولة جايي. هلّق.', 'regular', 19, GOLD, bind='0:906',
       extra='width="1004" height="32" sizingValue="fixed" alignValue="right" overflowValue="fitFontSize"'))
A(rrect('Caption Bar', 24, 722, 1052, 70, 16, fill='D80A0C12'))

# ---- things painted on the street itself: neon, the generator's sign, graffiti.
# Their opacity is bound to the street light the script reports, so the cut
# takes them with it.
bx, by = street(453, 711)
A(text('Neon Bakery', bx, by, 'فرن ومناقيش', 'display', 20, 'FFFFE9C2', extra='sizingValue="autoWidth" originX="0.5" originY="0.5"',
       op_bind=('0:912', '0:961')))
mx, my = street(827, 711)
A(text('Neon Market', mx, my, 'ميني ماركت', 'display', 20, 'FFD9F6FF', extra='sizingValue="autoWidth" originX="0.5" originY="0.5"',
       op_bind=('0:912', '0:961')))
gx, gy = street(117, 643)
A(text('Generator Sign', gx, gy, 'موتير أبو علي', 'display', 22, 'FF2A2118', extra='sizingValue="autoWidth" originX="0.5" originY="0.5"',
       op_bind=('0:912', '0:962')))
fx, fy = street(642, 648)
A(text('Graffiti', fx, fy, 'وين الدولة؟', 'display', 27, 'FFC8473C', extra='sizingValue="autoWidth" originX="0.5" originY="0.5" rotation="-0.07"',
       op_bind=('0:912', '0:963')))

# ---- the street, last so it draws underneath everything
A('''        <LayoutComponent width="1280" height="800" styleId="0:11" name="Stage" id="0:10">
            <LayoutComponentStyle layoutWidthScaleType="1" layoutHeightScaleType="1" widthUnitsValue="3" heightUnitsValue="3" name="Stage Style" id="0:11"/>
            <ScriptedLayout scriptAssetId="0:80" name="Street" id="0:12"/>
        </LayoutComponent>''')


def cond(prop, value, ind, op='equal'):
    pad = ' ' * ind
    return f'''{pad}<TransitionViewModelCondition opValue="{op}">
{pad}    <TransitionPropertyViewModelComparator>
{pad}        <BindablePropertyNumber>
{pad}            <DataBindContext sourcePathIds="0:900-{prop}" propertyKey="636"/>
{pad}        </BindablePropertyNumber>
{pad}    </TransitionPropertyViewModelComparator>
{pad}    <TransitionValueNumberComparator value="{value}"/>
{pad}</TransitionViewModelCondition>'''


def transition(to, conds, ind=20, duration=0, interp=None):
    pad = ' ' * ind
    dur = f' duration="{duration}"' if duration else ''
    itype = ''
    inner = ''
    if interp:
        _, x1, y1, x2, y2 = interp
        itype = ' interpolationType="cubic"'
        inner = f'\n{pad}    <CubicEaseInterpolator x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"/>'
    lines = [f'{pad}<StateTransition stateToId="{to}"{dur}{itype}>' + inner]
    for c in conds:
        lines.append(cond(*c, ind=ind + 4))
    lines.append(f'{pad}</StateTransition>')
    return '\n'.join(lines)


# ---------------------------------------------------------------- state machine
LEVER_STATE = {1: '0:511', 0: '0:512', 2: '0:513'}
LEVER_ANIM = {1: '0:601', 0: '0:602', 2: '0:603'}
PHASES = [(0, 'Intro'), (1, 'Hunt'), (2, 'Rescued'), (3, 'Ending')]
STORY_STATE = {p: f'0:{530 + p}' for p, _ in PHASES}
STORY_ANIM = {p: f'0:{610 + p}' for p, _ in PHASES}
CARD_STATE = {k: f'0:{540 + k}' for k in range(7)}
CARD_ANIM = {k: f'0:{620 + k}' for k in range(7)}
BATT_STATE = {'ok': '0:550', 'low': '0:551'}
BATT_ANIM = {'ok': '0:630', 'low': '0:631'}

A('        <StateMachine name="Kahraba" id="0:500">')
# layer 1: the lever follows `power`, whoever set it (you, or the story)
A('            <StateMachineLayer name="Lever" id="0:501">')
A('                <AnyState x="760" y="-120"/>')
A('                <ExitState x="960" y="-120"/>')
A(f'                <EntryState><StateTransition stateToId="{LEVER_STATE[1]}"/></EntryState>')
for k, (pv, *_r) in enumerate(ROWS):
    A(f'                <AnimationState x="{160 + k * 220}" y="140" animationId="{LEVER_ANIM[pv]}" reset="true" id="{LEVER_STATE[pv]}">')
    for (pv2, *_s) in ROWS:
        if pv2 != pv:
            A(transition(LEVER_STATE[pv2], [('0:901', pv2)], duration=240, interp=THROW))
    A('                </AnimationState>')
A('            </StateMachineLayer>')

# layer 2: the story, driven by `phase` which the script advances
A('            <StateMachineLayer name="Story" id="0:502">')
A('                <AnyState x="760" y="-120"/>')
A('                <ExitState x="960" y="-120"/>')
A(f'                <EntryState><StateTransition stateToId="{STORY_STATE[0]}"/></EntryState>')
for k, (p, name) in enumerate(PHASES):
    A(f'                <AnimationState x="{160 + k * 200}" y="{140 + (k % 2) * 120}" animationId="{STORY_ANIM[p]}" reset="true" id="{STORY_STATE[p]}">')
    for p2, _n in PHASES:
        if p2 != p and p2 != 0:
            A(transition(STORY_STATE[p2], [('0:907', p2)]))
    A('                </AnimationState>')
A('            </StateMachineLayer>')

# layer 3: the jinn cards. One state per jinn found; each plays its own card.
A('            <StateMachineLayer name="Cards" id="0:503">')
A('                <AnyState x="760" y="-260"/>')
A('                <ExitState x="960" y="-260"/>')
A(f'                <EntryState><StateTransition stateToId="{CARD_STATE[0]}"/></EntryState>')
for k in range(7):
    A(f'                <AnimationState x="{160 + k * 150}" y="{60 + (k % 2) * 110}" animationId="{CARD_ANIM[k]}" reset="true" id="{CARD_STATE[k]}">')
    if k < 6:
        A(transition(CARD_STATE[k + 1], [('0:909', k + 1)]))
    if k > 0:
        A(transition(CARD_STATE[0], [('0:909', 0)]))
    A('                </AnimationState>')
A('            </StateMachineLayer>')

# layer 4: the battery warns you below 20%
A('            <StateMachineLayer name="Battery" id="0:504">')
A('                <AnyState x="560" y="-120"/>')
A('                <ExitState x="760" y="-120"/>')
A(f'                <EntryState><StateTransition stateToId="{BATT_STATE["ok"]}"/></EntryState>')
A(f'                <AnimationState x="160" y="140" animationId="{BATT_ANIM["ok"]}" id="{BATT_STATE["ok"]}">')
A(transition(BATT_STATE['low'], [('0:902', 20, )], duration=150).replace('opValue="equal"', 'opValue="lessThan"'))
A('                </AnimationState>')
A(f'                <AnimationState x="380" y="140" animationId="{BATT_ANIM["low"]}" id="{BATT_STATE["low"]}">')
A(transition(BATT_STATE['ok'], [('0:902', 20)], duration=300).replace('opValue="equal"', 'opValue="greaterThanOrEqual"'))
A('                </AnimationState>')
A('            </StateMachineLayer>')

for i, (pv, dy, ar, en, lamp) in enumerate(ROWS):
    A(f'''            <StateMachineListenerSingle targetId="0:{110 + i}" listenerTypeValue="click" name="Pick {en}" id="0:{520 + i}">
                <ListenerViewModelChange>
                    <BindablePropertyNumber propertyValue="{pv}">
                        <DataBindContext sourcePathIds="0:900-0:901" propertyKey="636" direction="true"/>
                    </BindablePropertyNumber>
                </ListenerViewModelChange>
            </StateMachineListenerSingle>''')
A('        </StateMachine>')

# ---------------------------------------------------------------- animations
# The lever: the state transition carries the throw (THROW overshoots past the
# detent); the animation adds the knock of the plate on the wall and the lamp
# flaring white before it settles to its colour.
for (pv, dy, ar, en, lamp) in ROWS:
    A(f'        <LinearAnimation fps="60" duration="30" name="Lever {en}" id="{LEVER_ANIM[pv]}">')
    A(keyed(LEVER, Y, [kf(dy, 0)]))
    A(keyed(PLATE, ROT, [kf(0, 0, ('cubic', 0.2, 0.9, 0.4, 1)), kf(0.03, 3, ('cubic', 0.4, 0, 0.6, 1)),
                          kf(-0.016, 10, ('cubic', 0.4, 0, 0.6, 1)), kf(0.006, 17, ('cubic', 0.4, 0, 0.6, 1)), kf(0, 24)]))
    A(keyed(PLATE, Y, [kf(0, 0, 'lin'), kf(2.5, 3, ('cubic', 0.3, 0, 0.3, 1)), kf(0, 12)]))
    for j, (pv2, dy2, ar2, en2, lamp2) in enumerate(ROWS):
        if pv2 == pv:
            A(keyed_color(f'0:{135 + j}', [('FFFFFFFF', 0, True), (lamp2, 12, False)]))
        else:
            A(keyed_color(f'0:{135 + j}', [('FF2A2C33', 0, False)]))
    A('        </LinearAnimation>')

# The story beats.
A(f'        <LinearAnimation fps="60" duration="90" name="Intro" id="{STORY_ANIM[0]}">')
A(keyed(TITLE, OP, [kf(0, 0, SNAP_OUT), kf(1, 40)]))
A(keyed(TITLE, Y, [kf(-18, 0, SNAP_OUT), kf(0, 48)]))
A(keyed(ENDCARD, OP, [kf(0, 0)]))
A('        </LinearAnimation>')

A(f'        <LinearAnimation fps="60" duration="480" name="Hunt" id="{STORY_ANIM[1]}">')
A(keyed(TITLE, OP, [kf(1, 0)]))
A(keyed(ENDCARD, OP, [kf(1, 0, SLOW_IN), kf(0, 14)]))
A('        </LinearAnimation>')

A(f'        <LinearAnimation fps="60" duration="60" name="Rescued" id="{STORY_ANIM[2]}">')
A(keyed(ENDCARD, OP, [kf(0, 0)]))
A('        </LinearAnimation>')

# The ending waits for the parade on the parapet before the card lands.
A(f'        <LinearAnimation fps="60" duration="260" name="Ending" id="{STORY_ANIM[3]}">')
A(keyed(ENDCARD, OP, [kf(0, 0), kf(0, 190, SNAP_OUT), kf(1, 214)]))
A(keyed(ENDCARD, SX, [kf(0.86, 0), kf(0.86, 190, SETTLE), kf(1, 236)]))
A(keyed(ENDCARD, SY, [kf(0.86, 0), kf(0.86, 190, SETTLE), kf(1, 236)]))
A(keyed(ENDCARD, Y, [kf(390, 0), kf(390, 190, SNAP_OUT), kf(372, 222)]))
A(keyed(TITLE, OP, [kf(1, 0)]))
A('        </LinearAnimation>')

# The cards: k-th jinn found. The card slides in with a settle, holds long
# enough to read the Arabic, then leaves slower than it came.
for k in range(7):
    A(f'        <LinearAnimation fps="60" duration="{1 if k == 0 else 200}" name="{"Card Hidden" if k == 0 else f"Card {k}"}" id="{CARD_ANIM[k]}">')
    if k == 0:
        A(keyed(CARD, OP, [kf(0, 0)]))
        for d in DOTS:
            A(keyed(d, OP, [kf(0.22, 0)]))
            A(keyed(d, SX, [kf(1, 0)]))
            A(keyed(d, SY, [kf(1, 0)]))
    else:
        A(keyed(CARD, OP, [kf(0, 0, SNAP_OUT), kf(1, 9), kf(1, 160, SLOW_IN), kf(0, 196)]))
        A(keyed(CARD, X, [kf(4, 0, SETTLE), kf(34, 34), kf(34, 160, SLOW_IN), kf(22, 196)]))
        for i, d in enumerate(DOTS):
            if i + 1 < k:
                A(keyed(d, OP, [kf(1, 0)]))
            elif i + 1 == k:
                A(keyed(d, OP, [kf(0.22, 0, 'lin'), kf(1, 6)]))
                A(keyed(d, SX, [kf(2.2, 0, SETTLE), kf(1, 30)]))
                A(keyed(d, SY, [kf(2.2, 0, SETTLE), kf(1, 30)]))
            else:
                A(keyed(d, OP, [kf(0.22, 0)]))
    A('        </LinearAnimation>')

# The battery: green and calm, or red and breathing.
A(f'        <LinearAnimation fps="60" duration="1" name="Battery OK" id="{BATT_ANIM["ok"]}">')
A(keyed_color(BATT_FILL, [('FF7CFF9A', 0, False)]))
A(keyed(BATT_CASE, OP, [kf(1, 0)]))
A('        </LinearAnimation>')
A(f'        <LinearAnimation fps="60" duration="42" loopValue="pingPong" name="Battery Low" id="{BATT_ANIM["low"]}">')
A(keyed_color(BATT_FILL, [('FFFF5A4E', 0, True), ('FFB3261E', 42, False)]))
A(keyed(BATT_CASE, OP, [kf(1, 0, ('cubic', 0.45, 0, 0.55, 1)), kf(0.35, 42)]))
A('        </LinearAnimation>')
A('    </Artboard>')

A('''    <DataConverterRangeMapper minInput="0" maxInput="100" minOutput="0" maxOutput="34" clampLower="true" clampUpper="true" name="Battery Width" id="0:960"/>
    <DataConverterRangeMapper minInput="0" maxInput="1" minOutput="0" maxOutput="1" clampLower="true" clampUpper="true" name="Neon" id="0:961"/>
    <DataConverterRangeMapper minInput="0" maxInput="1" minOutput="0.22" maxOutput="0.95" clampLower="true" clampUpper="true" name="Generator Sign" id="0:962"/>
    <DataConverterRangeMapper minInput="0" maxInput="1" minOutput="0.1" maxOutput="0.8" clampLower="true" clampUpper="true" name="Graffiti" id="0:963"/>
    <ViewModel defaultInstanceId="0:920" name="Street" id="0:900">
        <ViewModelPropertyNumber name="power" id="0:901"/>
        <ViewModelPropertyNumber name="batteryLevel" id="0:902"/>
        <ViewModelPropertyString name="batteryText" id="0:903"/>
        <ViewModelPropertyString name="foundText" id="0:904"/>
        <ViewModelPropertyString name="caption" id="0:905"/>
        <ViewModelPropertyString name="captionAr" id="0:906"/>
        <ViewModelPropertyNumber name="phase" id="0:907"/>
        <ViewModelPropertyNumber name="autoplay" id="0:908"/>
        <ViewModelPropertyNumber name="found" id="0:909"/>
        <ViewModelPropertyString name="cardAr" id="0:910"/>
        <ViewModelPropertyString name="cardEn" id="0:911"/>
        <ViewModelPropertyNumber name="lights" id="0:912"/>
        <ViewModelPropertyNumber name="quality" id="0:913"/>
        <ViewModelInstance exports="true" name="Default" id="0:920">
            <ViewModelInstanceNumber propertyValue="1" viewModelPropertyId="0:901"/>
            <ViewModelInstanceNumber propertyValue="100" viewModelPropertyId="0:902"/>
            <ViewModelInstanceString propertyValue="100%" viewModelPropertyId="0:903"/>
            <ViewModelInstanceString propertyValue="0 / 6" viewModelPropertyId="0:904"/>
            <ViewModelInstanceString propertyValue="Beirut, 8 PM. The state power is on. For now." viewModelPropertyId="0:905"/>
            <ViewModelInstanceString propertyValue="بيروت، الساعة ٨. كهربا الدولة جايي. هلّق." viewModelPropertyId="0:906"/>
            <ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="0:907"/>
            <ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="0:908"/>
            <ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="0:909"/>
            <ViewModelInstanceString propertyValue="الغول" viewModelPropertyId="0:910"/>
            <ViewModelInstanceString propertyValue="THE GHOUL" viewModelPropertyId="0:911"/>
            <ViewModelInstanceNumber propertyValue="1" viewModelPropertyId="0:912"/>
            <ViewModelInstanceNumber propertyValue="1" viewModelPropertyId="0:913"/>
        </ViewModelInstance>
    </ViewModel>
    <FontAsset file="Lalezar-Regular.ttf" name="Lalezar" id="0:31"/>
    <FontAsset file="IBMPlexSansArabic-Regular.ttf" name="IBM Plex Sans Arabic" id="0:32"/>
    <FontAsset file="IBMPlexSansArabic-SemiBold.ttf" name="IBM Plex Sans Arabic SemiBold" id="0:33"/>
    <ScriptAsset file="main.luau" name="main" id="0:80"/>
    <ShaderAsset file="light.wgsl" name="light" id="0:81"/>
</Rive>''')

open('scene.rml', 'w').write('\n'.join(out) + '\n')
print('scene.rml written')
