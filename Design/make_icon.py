"""Renders the Photos Heat Map app icon: macOS squircle, pale map background with
faint roads, and a heat blob drawn with the app's own Soft ramp + log mapping."""
import json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SS = 2                       # supersampling
N = 1024 * SS
out_dir = sys.argv[1]

# ---------- macOS icon shape (Apple's template: 824/1024 plate, ~22.37% corner radius) ----------
plate = int(824 * SS)
margin = (N - plate) // 2
radius = plate * 0.2237

def squircle_mask(size, r, n=4.5):
    """Continuous-curvature rounded square (superellipse corners), anti-aliased."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    # distance into the corner region
    cx = np.clip(np.abs(x - size / 2) - (size / 2 - r), 0, None) / r
    cy = np.clip(np.abs(y - size / 2) - (size / 2 - r), 0, None) / r
    d = (cx ** n + cy ** n) ** (1 / n)          # 1.0 on the corner boundary
    edge = 1.5 / r
    return np.clip((1 - d) / edge + 0.5, 0, 1)  # soft 1.5 px edge

mask = squircle_mask(plate, radius)

# ---------- background: pale map with a coastline ----------
y, x = np.mgrid[0:plate, 0:plate].astype(np.float64) / plate
land_top = np.array([0.95, 0.97, 0.94]); land_bot = np.array([0.88, 0.93, 0.87])
land = land_top[None, None, :] * (1 - y[..., None]) + land_bot[None, None, :] * y[..., None]
water_top = np.array([0.78, 0.88, 0.98]); water_bot = np.array([0.62, 0.78, 0.95])
water = water_top[None, None, :] * (1 - y[..., None]) + water_bot[None, None, :] * y[..., None]
coast = 0.74 + 0.07 * np.sin(2.6 * x + 0.8) + 0.03 * np.sin(6.0 * x)   # gentle shoreline
w = 1 / (1 + np.exp(-(y - coast) / 0.004))
bg = land * (1 - w[..., None]) + water * w[..., None]
# faint shore glow
shore = np.exp(-((y - coast) / 0.03) ** 2) * (1 - w)
bg = bg * (1 - 0.35 * shore[..., None]) + np.array([0.86, 0.92, 0.97]) * (0.35 * shore[..., None])
img = Image.fromarray((bg * 255).astype(np.uint8), "RGB").convert("RGBA")

# ---------- two soft roads ----------
roads = Image.new("RGBA", (plate, plate), (0, 0, 0, 0))
d = ImageDraw.Draw(roads)
def bez(p0, p1, p2, p3, steps=200):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        pts.append(tuple(((1-t)**3)*np.array(p0) + 3*((1-t)**2)*t*np.array(p1)
                         + 3*(1-t)*t*t*np.array(p2) + t**3*np.array(p3)))
    return pts
P = lambda u, v: (u * plate, v * plate)
for pts, wdt in [
    (bez(P(-0.05, 0.48), P(0.30, 0.40), P(0.55, 0.62), P(1.05, 0.52)), 0.030),
    (bez(P(0.34, -0.05), P(0.40, 0.30), P(0.62, 0.40), P(0.70, 1.05)), 0.024),
]:
    d.line(pts, fill=(255, 255, 255, 255), width=int(wdt * plate), joint="curve")
roads = roads.filter(ImageFilter.GaussianBlur(1.0 * SS))
r = np.array(roads).astype(np.float64); r[..., 3] *= 0.75
roads = Image.fromarray(r.astype(np.uint8), "RGBA")
img = Image.alpha_composite(img, roads)

# ---------- heat layer: same model as the app (radial stamps, log mapping, Soft ramp) ----------
ramp = [(0.00, 0.45, 0.32, 0.95), (0.30, 0.72, 0.34, 0.92), (0.55, 0.97, 0.45, 0.60),
        (0.78, 1.00, 0.64, 0.25), (1.00, 1.00, 0.93, 0.35)]
def ramp_color(t):
    for i in range(1, len(ramp)):
        a, b = ramp[i-1], ramp[i]
        if t <= b[0]:
            u = (t - a[0]) / (b[0] - a[0])
            return np.array(a[1:]) * (1 - u) + np.array(b[1:]) * u
    return np.array(ramp[-1][1:])

alpha_edge, edge_alpha, alpha_full, max_alpha = 0.10, 0.30, 0.55, 0.85
def alpha_of(t):
    if t < alpha_edge: return 0.0
    return edge_alpha + (max_alpha - edge_alpha) * min(1, (t - alpha_edge) / (alpha_full - alpha_edge))

# stamps: (u, v, sigma as fraction of plate, stacked-photo count)
stamps = [
    (0.60, 0.50, 0.072, 150),   # main cluster, slightly up-right of centre
    (0.52, 0.58, 0.050, 30),    # its tail along the road
    (0.30, 0.30, 0.050, 12),    # a quieter place
    (0.25, 0.70, 0.030, 2.5),   # a lone shot
]
density = np.zeros((plate, plate))
for (u, v, s_, n) in stamps:
    density += n * np.exp(-(((x - u) ** 2 + (y - v) ** 2)) / (2 * s_ * s_))
t = np.clip(np.log1p(density) / np.log1p(300), 0, 1)
lut_rgb = np.array([ramp_color(i / 255) for i in range(256)])
lut_a = np.array([alpha_of(i / 255) for i in range(256)])
idx = (t * 255 + 0.5).astype(int)
heat = np.dstack([lut_rgb[idx], lut_a[idx][..., None]])
heat_img = Image.fromarray((heat * 255).astype(np.uint8), "RGBA")
heat_img = heat_img.filter(ImageFilter.GaussianBlur(0.8 * SS))
img = Image.alpha_composite(img, heat_img)

# ---------- glossy inner highlight (very subtle, Apple-style) ----------
gloss = np.clip(1 - y * 2.2, 0, 1) ** 2 * 0.10
gloss_img = Image.fromarray(np.dstack([np.ones((plate, plate, 3)), gloss[..., None]]).astype(np.float64).__mul__(255).astype(np.uint8), "RGBA")
img = Image.alpha_composite(img, gloss_img)

# ---------- cut to plate shape, inner hairline, drop shadow ----------
arr = np.array(img).astype(np.float64)
arr[..., 3] = mask * 255
plate_img = Image.fromarray(arr.astype(np.uint8), "RGBA")

canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
sh = Image.fromarray(np.dstack([np.zeros((plate, plate, 3)), mask[..., None] * 255 * 0.28]).astype(np.uint8), "RGBA")
shadow.paste(sh, (margin, margin + int(10 * SS)), sh)
shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SS))
canvas = Image.alpha_composite(canvas, shadow)
canvas.paste(plate_img, (margin, margin), plate_img)

master = canvas.resize((1024, 1024), Image.LANCZOS)
master.save(os.path.join(out_dir, "icon_1024.png"))

# ---------- Xcode asset catalog ----------
sizes = [16, 32, 128, 256, 512]
images = []
for s in sizes:
    for scale in (1, 2):
        px = s * scale
        name = f"icon_{s}x{s}@{scale}x.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{s}x{s}"})
with open(os.path.join(out_dir, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
print("ok")
