import re, json, sys
src = open('reference/xarm-studio-export.py').read()

# Split into program branches on the print("PROGRAM N") markers
parts = re.split(r'print\("PROGRAM (\d+)"\)', src)
programs = {}
for i in range(1, len(parts), 2):
    num = int(parts[i]); body = parts[i+1]
    # cut at the next `if self._arm.get_cgpio_digital` guard so we only keep this branch
    m = re.search(r'\n\s*if (?:not \()?self\._arm\.get_cgpio_digital', body)
    if m: body = body[:m.start()]
    programs[num] = body

speeds_seen, accs_seen, joints_seen = set(), set(), []
out = {}
for num in sorted(programs):
    body = programs[num]
    speed = None; acc = None
    poses = []; notes = []
    for line in body.splitlines():
        s = line.strip()
        m = re.match(r'self\._angle_speed = (\d+(?:\.\d+)?)', s)
        if m: speed = float(m.group(1)); speeds_seen.add(speed); continue
        m = re.match(r'self\._angle_acc = (\d+(?:\.\d+)?)', s)
        if m: acc = float(m.group(1)); accs_seen.add(acc); continue
        m = re.search(r'set_servo_angle\(angle=\[([^\]]+)\].*?radius=([\d.]+)', s)
        if m:
            j = [float(x) for x in m.group(1).split(',')]
            joints_seen.append(j)
            poses.append({'joints': j[:5], 'speed': speed, 'acc': acc,
                          'radius': float(m.group(2)), 'dwell': 0.0})
            continue
        m = re.search(r'set_pause_time\(([\d.]+)\)', s)
        if m and poses:
            poses[-1]['dwell'] += float(m.group(1)); continue
        if 'set_position(' in s: notes.append('cartesian set_position (not a joint pose)')
        if 'move_circle(' in s: notes.append('move_circle')
        if 'move_gohome(' in s: notes.append('move_gohome')
    out[num] = {'poses': poses, 'notes': sorted(set(notes))}

print(f"programs found: {sorted(out)}")
print(f"count: {len(out)}")
print(f"angle speeds used: {sorted(speeds_seen)}")
print(f"accs used: {sorted(accs_seen)}")
import itertools
for jn in range(5):
    vals = [j[jn] for j in joints_seen]
    print(f"J{jn+1} range across ALL programs: {min(vals):.1f} .. {max(vals):.1f}")
print()
for num in sorted(out):
    p = out[num]
    print(f"Program {num:2d}: {len(p['poses'])} joint poses" + (f"  [{', '.join(p['notes'])}]" if p['notes'] else ""))
json.dump(out, open('xarm_programs.json','w'), indent=1)
