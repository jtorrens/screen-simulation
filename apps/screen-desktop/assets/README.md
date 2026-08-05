# Bundled reference sources

`editorial-text-reference.svg` is the deterministic editable authority for the bundled 3840×2160 editorial text reference. `editorial-text-reference.png` is its current rasterized sRGB device-signal asset.

`camera-color-reference.png` is an original 3840×2160 sRGB device-signal asset generated for this project with OpenAI image generation. It is designed to exercise skin tones, saturated textiles, neutral patches, smooth gradients, foliage, fine fabric, matte objects and specular surfaces. It contains no copied chart layout, brand, logo, text or watermark.

Both PNGs are explicit bounded `[0,1]` device signals. They enter the same prepared-device-signal and physical panel pipeline as an explicitly interpreted sRGB raster; they are not display-transform references and never replace an authored media source.
