# Ordal: Logo Guidelines

## 1. The logo
- **Idea:** a custom lowercase *ordal* whose **o** holds a table cell, so the round world of data gets a structure.
- **Versions:** horizontal lockup (tile + wordmark, primary in app/web headers), stacked lockup, wordmark only (primary in text-heavy contexts: README, docs), app tile / symbol only.
- **Files:** `ordal-*.svg` masters · `wordmark/`, `horizontal/` black/white/jade SVG + PNG · `symbol/` favicon + web icons + `<head>` snippet · `app-icon/` 16–1024 px PNG.

## 2. Construction
Grid: x-height 100u, ascender 140u, stem 22u, round letters overshoot 1u, round horizontals thinned to 21u.
The o's counter is a 54 × 56u rounded rectangle (radius 16u). The small-size symbol (`ordal-symbol-small.svg`, ≤ 32 px) uses a 50 × 52u counter with radius 17u so the ring stays solid.

## 3. Clear space
Keep **1 × the o's counter width** (≈ half the x-height) clear on every side. For the tile, keep ¼ of the tile width.

## 4. Minimum size
| Version | Screen | Print |
|---|---|---|
| Horizontal lockup | 96 px wide | 25 mm wide |
| Wordmark | 64 px wide | 18 mm wide |
| App tile | 16 px (favicon files) | 6 mm |

## 5. Colour
| Name | HEX | RGB | CMYK | Pantone (verify on a swatch book) |
|---|---|---|---|---|
| Ordal Jade | #0D7F62 | 13 127 98 | 90 0 23 50 | ≈ 3415 C |
| Ink | #15171C | 21 23 28 | 75 68 67 90 | Black 6 C |
| Paper | #FFFFFF | 255 255 255 | 0 0 0 0 | n/a |

- White on Jade has a contrast of 4.97:1 (WCAG AA). Use Jade for the logo tile and as the single UI accent.
- For dark UI, set accent text in a lighter jade (#3DD6A3) on Ink. The logo tile stays #0D7F62.
- **Approved pairs:** Ink wordmark on white · white wordmark on Ink · white or Ink wordmark next to a Jade tile · one-colour Jade on white · black or white only when colour isn't available.

## 6. Typography
The wordmark is custom-drawn: never retype it in a font. UI and documents use the platform's system font (SF Pro on macOS, Segoe UI Variable on Windows, Cantarell/Inter on Linux), consistent with Ordal being a native app.

## 7. Don'ts
Don't stretch, rotate or recolour outside the palette · don't round off the o's square counter or replace it with a circle · don't add shadows, outlines or gradients · don't change the tile corner radius · don't rearrange or resize the parts of a lockup · don't place the wordmark on busy backgrounds without the tile.

## 8. Notes
- The marks are original constructions, but no trademark search has been run. Do one before adopting.
- Masters are SVG; for PDF/EPS, open the SVG in Illustrator/Inkscape and save, converting colours to the CMYK values above.
