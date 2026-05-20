# .bomb File Format

**Source:** `Game.Logic/Phy/Maps/Tile.cs` (`Tile(string file, bool digable)` constructor)

## Purpose

Each `.bomb` file is a precomputed 1-bit collision mask representing the crater shape that a weapon carves into the terrain when it detonates. The physics engine (via `BallMgr` + `Tile.Dig()`) stamps this mask onto the map's terrain tile, clearing any solid pixel where the bomb shape has a 1-bit.

Files live at `bomb/{itemID}.bomb` relative to the service working directory. IDs match weapon/item template IDs in the game database.

## Binary Layout

No magic bytes or file signature. Pure little-endian binary.

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 4 | `int32 LE` | `width` — pixel width of the collision mask |
| 4 | 4 | `int32 LE` | `height` — pixel height of the collision mask |
| 8 | `(width/8 + 1) × height` | `byte[]` | packed 1-bit pixel data, row-major, MSB first |

**Stride:** `bw = width / 8 + 1` bytes per row (not rounded to byte-exact — always one extra byte per row).

**Bit order:** within each byte, bit 7 (MSB) is the leftmost pixel. Pixel `(x, y)` is at byte `y * bw + x/8`, bit `7 - (x % 8)`.

## Reading in C#

```csharp
var reader = new BinaryReader(File.Open(path, FileMode.Open));
int width  = reader.ReadInt32();
int height = reader.ReadInt32();
int bw     = width / 8 + 1;
byte[] data = reader.ReadBytes(bw * height);

// test pixel (x, y):
bool solid = (data[y * bw + x / 8] & (0x01 << (7 - x % 8))) != 0;
```

## Observed Shapes

All sampled bombs contain elliptical/circular shapes — the alpha-channel silhouette of the weapon's explosion sprite, baked offline. Sizes observed:

| ID | Width | Height | Approx. solid % | Notes |
|----|-------|--------|-----------------|-------|
| 0 | 342 | 342 | 0% | Null/no-bomb sentinel — all zeros |
| 4061 | 118 | 108 | ~32% | Clean oval |
| 11043 | 162 | 132 | ~34% | Larger oval |
| 78425 | 124 | 84 | ~38% | Slightly asymmetric circle |

Solid pixel density of ~30–40% is typical for a filled ellipse inscribed in its bounding box.

## How Dig Works

`Tile.Dig(cx, cy, surface, border)` in `Tile.cs:108`:
1. Centers the bomb mask at `(cx, cy)` on the map terrain tile
2. Calls `Remove()` — ANDs the inverted bomb bits into the terrain, clearing solid pixels (blasting a hole)
3. If a `border` tile is provided, calls `Add()` to paint a rubble ring around the edge (partially implemented — `Add()` body is commented out)

## Generating .bomb Files

The `Tile(Bitmap, bool)` constructor shows the original generation pipeline: any RGBA image can be converted — pixels with alpha > 100 become solid (1), the rest empty (0). The `.bomb` files are the pre-baked output of running weapon explosion sprites through this conversion.
