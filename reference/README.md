# The arm's own program

`xarm-studio-export.py` is the Blockly-generated Python that runs **on the xArm controller**
(received 2026-09-10). Its `run()` loop polls six digital inputs and branches on their binary
pattern — six bits, 64 values, matching `ProgramNumber 0–63` on the Siemens PLC.

So the rig works like this: **the PLC drives the rail itself and raises the program number on
six output wires; the xArm decodes them and runs the matching branch.** The Siemens holds no
arm trajectory. This file does.

`generate-factory-programs.py` parses every `set_servo_angle` (with the speed/acc in effect and
any following `set_pause_time`) into `ArmControl/Core/FactoryPrograms.swift`. Re-run it if the
export changes:

    python3 reference/generate-factory-programs.py

What it cannot carry: `set_position` (cartesian), `move_circle`, `move_gohome`, and blend
radius. Programs using those are marked `caveats` in the generated Swift.
