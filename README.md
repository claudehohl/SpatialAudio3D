# SpatialAudio3D
SpatialAudio3D is a drop-in Godot 4 plugin that transforms `AudioStreamPlayer3D` into a full spatial acoustics system. It fires raycasts from each sound source to detect nearby surfaces, placing virtual reflection points that play back reverb with delay and room size derived from the actual geometry around them. Occlusion behind walls smoothly rolls off high frequencies, and a dual-player crossfade system eliminates the audible clicks that occur when changing audio delay mid-playback. The result is an environment that sounds like it has walls, rooms, and air — with no manual setup beyond dropping the node into your scene.

## See it in action

[![Godot: SpatialAudio3D](https://img.youtube.com/vi/656lTI7Tu8s/hqdefault.jpg)](https://youtu.be/656lTI7Tu8s)

## Features

Realistic spatial acoustics for Godot 4, driven entirely by your level geometry.

- **Distance delay** — sound reaches the player at the correct time based on speed of sound
- **Raycast reverb** — reflection points are placed automatically at surrounding surfaces
- **Room size detection** — reverb tail length adapts to the measured dimensions of the space
- **Occlusion filtering** — walls between source and listener smoothly cut high frequencies
- **Proximity bass** — low-end increases naturally as you approach a reflecting surface
- **Crack-free crossfading** — dual-player A/B system avoids audio glitches when delay changes
- **Zero manual setup** — extends AudioStreamPlayer3D , works with your existing collision geometry

## Configuration options

![Config Options](/screenshots/config-options.png)
  
## Installation

-   Drop `addons/spatial_audio_3d` into your project
-   Add Child Node: ![Add node](/screenshots/add-node.png)
