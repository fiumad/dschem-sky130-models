# dschem-sky130-models

SkyWater sky130 ngspice models for [DSchem](https://github.com/fiumad/dschem),
served over GitHub Pages so the browser version of DSchem can fetch them
(GitHub release assets cannot be fetched cross-origin; Pages can).

- PDK: `sky130A` from open_pdks 1.0.608
  (`1689ac3f2dc763876eaf967227c7dfe831b031ae`), the version IIC-OSIC-TOOLS
  uses, from the ciel release archives
- Contents: `sky130A/libs.tech/ngspice/` and
  `sky130A/libs.ref/sky130_fd_pr/spice/`, unmodified
- `manifest.json`: every file with its size and SHA-256, the process corners,
  and `required`, the files ngspice opens for
  `.lib sky130A/libs.tech/ngspice/sky130.lib.spice <corner>`

## How DSchem uses it

DSchem fetches `manifest.json`, downloads the `required` files (319 files,
34 MiB, about 4 MiB compressed in transfer), checks their SHA-256, caches them
in the browser's origin-private file system (OPFS), and writes them into
ngspice's in-memory file system under `/pdk` before a simulation. ngspice
reads the include files of every section of `sky130.lib.spice`, not only the
selected corner, so the same files are needed for every corner. That list was
checked against the files ngspice 47 actually opens.

## Temporary: ngspice for the browser

`ngspice/47/` holds DSchem's WebAssembly build of ngspice 47 (`ngspice.mjs` +
`ngspice.wasm`, analog simulation only). It is here only because this
repository already has a public Pages site; it will move when DSchem's web app
gets its own hosting, and does not belong to the model data.

- `BUILD.json`: ngspice source tarball and SHA-256, patches, Emscripten
  version, the DSchem commit it was built from, and the SHA-256 of both files
- `COPYING`: ngspice's licenses. Most of ngspice is Modified BSD; the KLU
  solver and numparam, both in this build, are LGPL-2.1, so the exact sources
  and build steps are provided: the tarball named in `BUILD.json`, `patches/`
  and `build_ngspice_wasm.sh` (it reads its version pins from DSchem's
  `pins.toml`; the same values are in `BUILD.json`)

## Rebuilding

```sh
scripts/build.py
git diff --stat
```

The script downloads the pinned archives, checks their SHA-256, replaces
`sky130A/` and rewrites `manifest.json`.

## License

The model files are Apache-2.0 (SkyWater PDK); see `NOTICE` and `LICENSE`.
