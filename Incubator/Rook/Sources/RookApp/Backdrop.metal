#include <metal_stdlib>
using namespace metal;

// The window's backdrop effects, drawn by a render thread of their own so the main thread never
// takes part in a frame. Each returns the ink's coverage at a point; positions are in points.

struct BackdropUniforms {
    float2 size;
    float scale;
    float time;
    float4 ink;
    int effect;
    float2 origin;
    float strength;
};

/// What the chess and maze effects are showing, played on the render thread.
struct GameUniforms {
    int moveFrom, moveTo, movePiece;
    float moveProgress;
    int lastFrom, lastTo;
    int gridWidth, gridHeight;
    float2 pac;
    float pacAngle, mouth;
    float4 ghosts[4];
    int power;
    float cell;
};

struct BackdropVertex {
    float4 position [[position]];
};

/// One triangle that covers the whole layer.
vertex BackdropVertex rookBackdropVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    return { float4(corner * 2.0 - 1.0, 0, 1) };
}

/// A stable pseudo-random number in 0..<2^32 for an integer.
static uint hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352d;
    x ^= x >> 15; x *= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

static float unit(uint x) { return float(hash(x) & 0xffff) / 65535.0; }

// MARK: Falling glyphs

/// Hex digits on a 3 by 5 grid, top row first, the leftmost dot in the highest bit.
constant uint hexFont[16] = {
    0b111101101101111, 0b010110010010111, 0b111001111100111, 0b111001111001111,
    0b101101111001001, 0b111100111001111, 0b111100111101111, 0b111001001001001,
    0b111101111101111, 0b111101111001111, 0b010101111101101, 0b110101110101110,
    0b011100100100011, 0b110101101101110, 0b111100111100111, 0b111100111100100,
};

/// Columns of hex falling at their own pace, each with a brighter head and a fading trail.
static float glyphs(float2 position, float2 size, float time) {
    const float2 cell = float2(14, 18);
    int column = int(position.x / cell.x), row = int(position.y / cell.y);
    int rows = int(size.y / cell.y) + 1;
    uint seed = hash(uint(column) * 2654435761u);
    float speed = 2.0 + float(seed % 5);
    int trail = 6 + int(seed % 14);
    int span = rows + trail + 8 + int(seed % 23);
    // A pass takes a fixed time, that of a window about 900 points tall, and resizing only stretches the path: had the
    // window's height set the period, every column would leap to another row at each step of a resize.
    float cycle = float(50 + trail + 8 + int(seed % 23)) / speed;
    int head = int(fract(time / cycle + float(seed % 997) / 997.0) * float(span));
    int offset = head - row;
    if (offset < 0 || offset >= trail) return 0;

    uint glyph = hexFont[hash(uint(row) * 31u + seed + uint(time * 2.0)) % 16u];
    // A 6 by 10 point glyph in the middle of its cell, each dot a soft square of 2 points.
    float2 local = position - float2(column, row) * cell - (cell - float2(6, 10)) / 2;
    if (local.x < 0 || local.y < 0 || local.x >= 6 || local.y >= 10) return 0;
    int2 dot = int2(local / 2);
    if (((glyph >> (14 - (dot.y * 3 + dot.x))) & 1u) == 0) return 0;
    float2 inside = abs(fract(local / 2) - 0.5);
    float edge = 1.0 - smoothstep(0.3, 0.5, max(inside.x, inside.y));

    float fade = 1.0 - float(offset) / float(trail);
    return (offset == 0 ? 0.26 : 0.1) * fade * edge;
}

// MARK: Grid

/// A faint dot grid that a slow horizontal scan brightens as it passes, with pings rippling out from
/// places across it, lifting and pushing the dots they pass like a sonar sweep.
static float grid(float2 position, float2 size, float time) {
    const float step = 22;
    // A sweep takes a fixed 28 seconds however tall the window, so a resize moves the scan smoothly rather than
    // throwing it elsewhere, as a period set by the height did.
    float scan = fract(time / 28.0) * (size.y + 240.0) - 120.0;
    float2 home = (floor(position / step) + 0.5) * step;
    float near = max(0.0, 1.0 - abs(home.y - scan) / 120.0);
    float2 push = 0;
    for (int k = 0; k < 3; k++) {
        const float period = 7.0;
        float clock = time + float(k) * period / 3.0;
        uint cycle = uint(clock / period) * 3u + uint(k);
        float age = fmod(clock, period);
        float2 origin = float2(unit(cycle * 2u + 11u), unit(cycle * 2u + 12u)) * size;
        float2 away = home - origin;
        float reach = length(away);
        float front = exp(-pow((reach - age * 170.0) / 26.0, 2.0)) * (1.0 - age / period);
        near = max(near, front);
        if (reach > 0.001) push += away / reach * front * 3.0;
    }
    float2 centre = home + push;
    float radius = 0.9 + near * 0.9;
    float coverage = 1.0 - smoothstep(radius - 0.5, radius + 0.5, distance(position, centre));
    return (0.09 + near * 0.26) * coverage;
}

// MARK: Scanlines

/// Fine lines as on a terminal's glass. A refresh beam sweeps down them, leaving a fading trail, and
/// now and then a short stretch of interference flickers across a line and is gone.
static float scanlines(float2 position, float2 size, float time) {
    if (fmod(position.y, 3.0) >= 1.0) return 0;
    float alpha = 0.03;
    // The beam, bright where it is and dimming behind it.
    // A fixed 10 seconds a pass, for the same reason as the grid's scan.
    float beam = fract(time / 10.0) * (size.y + 300.0) - 60.0;
    float behind = beam - position.y;
    alpha += 0.16 * exp(-pow(behind / 5.0, 2.0));
    if (behind > 0) alpha += 0.07 * exp(-behind / 140.0);
    // Interference: each of a few slots picks a line and a stretch of it for a moment, and flickers there.
    for (int k = 0; k < 3; k++) {
        float span = 1.7 + float(k) * 0.6;
        uint slot = uint(time / span) * 7u + uint(k) * 131u;
        float age = fmod(time, span) / span;
        if (age > 0.35) continue;
        float row = floor(unit(slot) * size.y / 3.0) * 3.0;
        if (abs(position.y - row) > 0.5) continue;
        float from = unit(slot + 1u) * size.x, length = 80.0 + unit(slot + 2u) * 260.0;
        float along = (position.x - from) / length;
        if (along < 0.0 || along > 1.0) continue;
        float flicker = 0.5 + 0.5 * sin(time * 90.0 + float(k) * 2.0);
        alpha = max(alpha, 0.2 * flicker * sin(along * 3.14159) * (1.0 - age / 0.35));
    }
    return alpha;
}

// MARK: Network

/// One point per cell, wandering slowly inside it.
static float2 node(int2 cell, float time, float span) {
    uint seed = hash(uint(cell.x) * 73856093u ^ uint(cell.y) * 19349663u);
    float phase = unit(seed) * 6.283, speed = 0.15 + unit(seed + 1) * 0.25;
    float2 home = float2(0.2 + unit(seed + 2) * 0.6, 0.2 + unit(seed + 3) * 0.6);
    float2 drift = 0.18 * float2(sin(time * speed + phase), cos(time * speed * 1.3 + phase));
    return (float2(cell) + home + drift) * span;
}

static float segment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return distance(p, a + ab * t);
}

/// Points drifting slowly, joined by faint lines while they are close: a topology seen from far off.
static float network(float2 position, float time) {
    const float span = 150, reach = 190;
    int2 here = int2(floor(position / span));
    float2 points[9];
    for (int i = 0; i < 9; i++) points[i] = node(here + int2(i % 3 - 1, i / 3 - 1), time, span);

    float alpha = 0;
    for (int i = 0; i < 9; i++) {
        alpha = max(alpha, 0.22 * (1.0 - smoothstep(1.1, 2.1, distance(position, points[i]))));
        for (int j = i + 1; j < 9; j++) {
            float length = distance(points[i], points[j]);
            if (length >= reach) continue;
            float line = 1.0 - smoothstep(0.0, 0.9, segment(position, points[i], points[j]));
            alpha = max(alpha, 0.12 * (1.0 - length / reach) * line);
        }
    }
    return alpha;
}

// MARK: Chess

/// Pieces on a 10 by 10 grid, top row first, the leftmost dot in bit 9: pawn, knight, bishop, rook, queen, king.
constant ushort pieceSprites[6][10] = {
    { 0x000, 0x030, 0x078, 0x078, 0x030, 0x078, 0x0fc, 0x0fc, 0x1fe, 0x000 },
    { 0x000, 0x070, 0x0fc, 0x1fc, 0x1bc, 0x03c, 0x07c, 0x0fc, 0x1fe, 0x000 },
    { 0x000, 0x030, 0x058, 0x068, 0x078, 0x030, 0x078, 0x0fc, 0x1fe, 0x000 },
    { 0x000, 0x1b6, 0x1fe, 0x0fc, 0x0fc, 0x0fc, 0x0fc, 0x1fe, 0x1fe, 0x000 },
    { 0x000, 0x132, 0x1b6, 0x1fe, 0x0fc, 0x0fc, 0x078, 0x0fc, 0x1fe, 0x000 },
    { 0x030, 0x078, 0x030, 0x0fc, 0x1fe, 0x1fe, 0x0fc, 0x0fc, 0x1fe, 0x000 },
};

static bool spriteDot(int kind, int2 dot) {
    if (dot.x < 0 || dot.y < 0 || dot.x > 9 || dot.y > 9) return false;
    return (pieceSprites[kind][dot.y] >> (9 - dot.x)) & 1;
}

/// A piece's ink at a point: white pieces solid, black ones drawn in outline over a faint fill.
static float piece(int code, float2 position, float2 centre, float side) {
    if (code == 0) return 0;
    float2 local = (position - centre) / side + 0.5;
    if (any(local < 0.0) || any(local >= 1.0)) return 0;
    float2 grid = local * 10.0;
    int2 dot = int2(grid);
    int kind = (code - 1) % 6;
    if (!spriteDot(kind, dot)) return 0;
    float2 inside = abs(fract(grid) - 0.5);
    float edge = 1.0 - smoothstep(0.38, 0.5, max(inside.x, inside.y));
    if (code <= 6) return 0.11 * edge;
    bool rim = !spriteDot(kind, dot + int2(1, 0)) || !spriteDot(kind, dot + int2(-1, 0))
        || !spriteDot(kind, dot + int2(0, 1)) || !spriteDot(kind, dot + int2(0, -1));
    return (rim ? 0.11 : 0.025) * edge;
}

/// A famous game replayed on a board stretched across the whole window.
static float chess(float2 position, float2 size, constant GameUniforms &game, constant uchar *board) {
    float2 cell = size / 8.0;
    int2 square = clamp(int2(position / cell), int2(0), int2(7));
    int index = (7 - square.y) * 8 + square.x;
    float alpha = ((square.x + square.y) & 1) ? 0.022 : 0.0;
    if (index == game.lastFrom || index == game.lastTo) alpha += 0.025;
    float side = min(cell.x, cell.y) * 0.62;
    if (index != game.moveFrom) alpha = max(alpha, piece(board[index], position, (float2(square) + 0.5) * cell, side));
    if (game.movePiece != 0) {
        float2 from = float2(game.moveFrom % 8, 7 - game.moveFrom / 8), to = float2(game.moveTo % 8, 7 - game.moveTo / 8);
        float t = game.moveProgress;
        float eased = t * t * (3.0 - 2.0 * t);
        alpha = max(alpha, piece(game.movePiece, position, (mix(from, to, eased) + 0.5) * cell, side));
    }
    return alpha;
}

// MARK: Maze

/// A maze's ink: its walls traced as a line inside each wall, dots and power pellets in the corridors,
/// the hunter, and the ghosts. Cells hold 1 for a wall, 2 for a dot and 4 for a pellet.
static float maze(float2 position, float2 size, float time, constant GameUniforms &game, constant uchar *cells) {
    float cellSize = game.cell;
    int2 count = int2(game.gridWidth, game.gridHeight);
    float2 origin = (size - float2(count) * cellSize) / 2.0;
    float2 grid = (position - origin) / cellSize;
    int2 here = int2(floor(grid));
    if (any(here < 0) || any(here >= count)) return 0;
    uchar data = cells[here.y * count.x + here.x];
    float2 local = grid - float2(here);
    float alpha = 0;

    if (data & 1) {
        // Distance to the nearest corridor, so outer corners round off and inner ones close.
        float nearest = 9.0;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            int2 other = here + int2(dx, dy);
            if (any(other < 0) || any(other >= count) || (cells[other.y * count.x + other.x] & 1)) continue;
            float2 lo = float2(dx, dy), hi = lo + 1.0;
            float2 gap = max(max(lo - local, local - hi), 0.0);
            nearest = min(nearest, length(gap));
        }
        alpha = 0.085 * (1.0 - smoothstep(0.035, 0.085, abs(nearest - 0.3)));
    } else if (data & 4) {
        float pulse = 0.17 + 0.04 * sin(time * 5.0);
        alpha = 0.12 * (1.0 - smoothstep(pulse - 0.04, pulse + 0.02, distance(local, float2(0.5))));
    } else if (data & 2) {
        alpha = 0.1 * (1.0 - smoothstep(0.06, 0.1, distance(local, float2(0.5))));
    }

    // The hunter, its mouth opening towards where it goes.
    float2 toPac = grid - game.pac;
    float r = length(toPac);
    if (r < 0.42) {
        float angle = atan2(toPac.y, toPac.x) - game.pacAngle;
        angle = abs(atan2(sin(angle), cos(angle)));
        float body = 1.0 - smoothstep(0.38, 0.42, r);
        if (angle > game.mouth * 0.75) alpha = max(alpha, 0.16 * body);
    }

    for (int g = 0; g < 4; g++) {
        float4 ghost = game.ghosts[g];
        if (ghost.w == 0) continue;
        float2 p = grid - ghost.xy;
        if (any(abs(p) > 0.45)) continue;
        // A dome over a body with a rippling hem, and two eyes looking the way it goes.
        float hem = 0.36 - 0.05 * (1.0 + sin(p.x * 26.0 + time * 12.0));
        bool inside = (p.y < -0.04 && length(p - float2(0, -0.04)) < 0.36) || (p.y >= -0.04 && abs(p.x) < 0.36 && p.y < hem);
        if (!inside) continue;
        float2 eye = float2(abs(p.x) - 0.13, p.y + 0.08);
        float2 look = float2(cos(ghost.z), sin(ghost.z)) * 0.04;
        float shade = game.power > 0 ? 0.04 : 0.09;
        if (length(eye) < 0.09) shade = length(float2(abs(p.x) - 0.13 - look.x * sign(p.x), p.y + 0.08 - look.y)) < 0.045 ? 0.16 : 0.0;
        alpha = max(alpha, shade);
    }
    return alpha;
}

/// The effect's ink, premultiplied, at a pixel.
fragment half4 rookBackdropFragment(BackdropVertex in [[stage_in]], constant BackdropUniforms &uniforms [[buffer(0)]],
                                    constant GameUniforms &game [[buffer(1)]], constant uchar *cells [[buffer(2)]]) {
    // In window points, wherever in the window this piece of the backdrop is.
    float2 position = in.position.xy / uniforms.scale + uniforms.origin;
    float alpha = 0;
    switch (uniforms.effect) {
    case 1: alpha = glyphs(position, uniforms.size, uniforms.time); break;
    case 2: alpha = grid(position, uniforms.size, uniforms.time); break;
    case 3: alpha = scanlines(position, uniforms.size, uniforms.time); break;
    case 4: alpha = network(position, uniforms.time); break;
    case 5: alpha = chess(position, uniforms.size, game, cells); break;
    case 6: alpha = maze(position, uniforms.size, uniforms.time, game, cells); break;
    default: break;
    }
    return half4(uniforms.ink * alpha * uniforms.strength);
}
