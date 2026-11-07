# PS4 Mode Design (PS5PCEM)

Goal: experimental PS4 compatibility inside PS5PCEM without separate emulator.

## Components
1. Loader: PS4 ELF/SELF, param SFO, LoadExec restart.
2. HLE: PS4 libs (GNM, VideoOut, audio, NP, save data) adapted to PS5PCEM HLE.
3. Graphics: GCN/GNM frontend translating command buffers, shaders, descriptors, tessellation, tiling into RDNA2/Vulkan path.
4. Memory: reuse guest memory + GPU dirty tracking; add PS4-specific layouts.
5. Runtime/CLI/GUI: detect PS4 titles, launch mode, badges, trophies, patches.
6. Diagnostics: env-gated compatibility diagnostics.

## Non-goals initially
- Full PS4 accuracy/performance; refine later.
