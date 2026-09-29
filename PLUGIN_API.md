# NeonAmp portable plugin API

NeonAmp plugins are JSON packages so the same extension can be imported on Windows and Android. A plugin is a validated manifest; it does not execute downloaded code or require a platform-specific binary.

## Package format

```json
{
  "id": "community.synthwave",
  "name": "Synthwave Pack",
  "version": "1.2.0",
  "description": "Community equalizer presets",
  "capabilities": ["equalizer-presets"],
  "equalizerPresets": {
    "Neon drive": [0, 2, 4, 5, 4, 2, 0, -2, -3, -1]
  }
}
```

`id` may contain letters, numbers, dots, underscores, and hyphens. Each equalizer preset must contain ten values between -12 and +12 dB. Invalid packages are rejected before they are saved.

Installed plugins can be enabled, disabled, or removed from the Plugins panel. Enabled preset contributions appear alongside NeonAmp's built-in equalizer presets.


## Included starter packs

The `plugins/` directory contains ten portable starter packs. Import any `.neonamp-plugin` file from the Plugins panel on Windows or Android; they use only the validated EQ and effect capabilities described above.
