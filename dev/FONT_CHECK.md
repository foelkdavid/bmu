# Font rendering regression check

Run with a visible window:

```sh
c3c build font-check && ./build/font-check
```

Checks native atlas sizes at 75%, 100%, 125%, 150%, 200% and 300% zoom,
physical-pixel alignment, draw/measure agreement, cache reuse, eviction while
rendering, the 192 px rasterization cap, extra glyphs, and repeated unload/reload.
The probe then draws and measures ten sizes for 120 frames. Timings exclude
presentation/VSync; `open` includes window initialization.

Local sample (2026-11-22, same machine; not a speedup claim):

| renderer | open | first ten-size draw | warm draw + measurement |
|---|---:|---:|---:|
| old 64 px trilinear atlas | 127 ms | 0.09 ms | 0.15 ms |
| cached native-size atlases | 133 ms | 30.27 ms | 0.22 ms |

Native rasterization improves clarity, not startup speed. It adds synchronous
work on first use of each size (also after a zoom/cache eviction); warmed sizes
reuse GPU atlases. Applications using more than 32 additional physical sizes
per frame can thrash the cache. See API §2 and §16 for the cache bounds.
