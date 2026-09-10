import SwiftUI

// MARK: - The recording, as tracks you can drag
//
// 🔑 **THE POINT: every channel on one shared clock.** The rail and five joints are six things moving
// at once, and the only way to answer "what is J2 doing while the carriage is out at 400mm" is to
// draw them against the same time axis. Each track shows the recorded curve with draggable keyframes
// at the moments that channel changed direction.
//
// ⚠️ **Flat tracks are labelled, not hidden.** A channel that never moved draws greyed with "didn't
// move" beside it, because an empty track and a broken recording look identical otherwise — and
// which one it is decides whether you go and check a cable.
struct TimelineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = RigRecorder.shared
    @StateObject private var motions = ArmMotionStore.shared

    let trace: RigTrace

    /// Keyframes per channel: channel → [(time, value)]. Seeded from the recording's turnarounds.
    @State private var keys: [Int: [Keyframe]] = [:]
    @State private var selected: Int = -1
    @State private var saveName = ""
    @State private var showSave = false
    @State private var includeRail = true

    struct Keyframe: Identifiable, Equatable {
        let id = UUID()
        var t: Double
        var v: Double
    }

    private var channels: [Int] { [-1] + Array(0..<XArmLink.jointCount) }

    private func label(_ c: Int) -> String { c < 0 ? "Rail" : "J\(c + 1)" }
    private func unit(_ c: Int) -> String { c < 0 ? "mm" : "°" }

    /// Vertical span for a channel, padded so a flat line does not sit exactly on the edge.
    private func span(_ c: Int) -> ClosedRange<Double> {
        guard let r = trace.range(c), r.max - r.min > 1 else {
            let mid = trace.range(c)?.min ?? 0
            return (mid - 10)...(mid + 10)
        }
        let pad = (r.max - r.min) * 0.15
        return (r.min - pad)...(r.max + pad)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary

                    ForEach(channels, id: \.self) { c in
                        track(c)
                    }

                    if let ks = keys[selected], !ks.isEmpty {
                        inspector(ks)
                    }
                }
                .padding()
            }
            .navigationTitle(trace.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make a movement") {
                        saveName = trace.name
                        showSave = true
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("Name this movement", isPresented: $showSave) {
                TextField("Name", text: $saveName)
                Button("Save") { makeMotion() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Builds an editable movement from the keyframes on these tracks.")
            }
            .onAppear(perform: seed)
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "%.1fs · %d samples", trace.duration, trace.samples.count))
                .font(.subheadline.monospacedDigit())
            let movedList = channels.filter { trace.moved($0) }.map(label)
            if movedList.isEmpty {
                // The single most useful thing this screen can say when a test goes wrong.
                Label("Nothing moved during this recording.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Pivot.caution)
            } else {
                Text("Moved: \(movedList.joined(separator: ", "))")
                    .font(.subheadline).foregroundStyle(Pivot.mint)
            }
            if let p = trace.program {
                Text("Recorded while running program \(p).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Include the rail in the movement", isOn: $includeRail)
                .font(.subheadline)
                .disabled(!trace.hasRail)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .pivotGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: One track

    private func track(_ c: Int) -> some View {
        let moved = trace.moved(c)
        let r = span(c)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label(c))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(moved ? .primary : .secondary)
                if !moved {
                    Text("didn't move").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let rr = trace.range(c), moved {
                    Text(String(format: "%.0f → %.0f %@", rr.min, rr.max, unit(c)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(moved ? 0.06 : 0.03))

                    if moved {
                        // The recorded curve.
                        Path { p in
                            let pts = trace.track(c)
                            guard let f = pts.first else { return }
                            p.move(to: point(f.t, f.v, w, h, r))
                            for s in pts.dropFirst() { p.addLine(to: point(s.t, s.v, w, h, r)) }
                        }
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)

                        // The editable keyframe line on top of it.
                        Path { p in
                            let ks = (keys[c] ?? []).sorted { $0.t < $1.t }
                            guard let f = ks.first else { return }
                            p.move(to: point(f.t, f.v, w, h, r))
                            for k in ks.dropFirst() { p.addLine(to: point(k.t, k.v, w, h, r)) }
                        }
                        .stroke(c == selected ? Pivot.mint : Pivot.blue, lineWidth: 2)

                        ForEach(keys[c] ?? []) { k in
                            Circle()
                                .fill(c == selected ? Pivot.mint : Pivot.blue)
                                .frame(width: 16, height: 16)
                                .position(point(k.t, k.v, w, h, r))
                                .gesture(
                                    DragGesture()
                                        .onChanged { g in
                                            selected = c
                                            move(c, k, to: g.location, w: w, h: h, range: r)
                                        }
                                )
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = c }
            }
            .frame(height: 96)
        }
        .padding(10)
        .pivotGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func point(_ t: Double, _ v: Double, _ w: CGFloat, _ h: CGFloat,
                       _ r: ClosedRange<Double>) -> CGPoint {
        let x = trace.duration > 0 ? CGFloat(t / trace.duration) * w : 0
        let f = (v - r.lowerBound) / max(0.001, r.upperBound - r.lowerBound)
        return CGPoint(x: x, y: h - CGFloat(f) * h)
    }

    /// Drag a keyframe. Time is clamped between its neighbours so a drag cannot reorder the move —
    /// a keyframe that jumps past the next one turns a smooth travel into a jerk backwards.
    private func move(_ c: Int, _ k: Keyframe, to loc: CGPoint, w: CGFloat, h: CGFloat,
                      range r: ClosedRange<Double>) {
        guard var ks = keys[c], let i = ks.firstIndex(where: { $0.id == k.id }) else { return }
        let tRaw = Double(max(0, min(w, loc.x)) / max(1, w)) * trace.duration
        let lower = i > 0 ? ks[i - 1].t + 0.05 : 0
        let upper = i < ks.count - 1 ? ks[i + 1].t - 0.05 : trace.duration
        ks[i].t = min(max(tRaw, lower), min(upper, trace.duration))

        let f = Double((h - max(0, min(h, loc.y))) / max(1, h))
        ks[i].v = r.lowerBound + f * (r.upperBound - r.lowerBound)
        keys[c] = ks
    }

    // MARK: Numeric inspector

    private func inspector(_ ks: [Keyframe]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(label(selected)) keyframes")
                .font(.headline)
            Text("Drag a dot on the track, or nudge it here.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(Array(ks.sorted { $0.t < $1.t }.enumerated()), id: \.element.id) { idx, k in
                HStack(spacing: 10) {
                    Text(String(format: "%.2fs", k.t))
                        .font(.caption.monospacedDigit())
                        .frame(width: 56, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f %@", k.v, unit(selected)))
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                    Spacer()
                    Button { nudge(k, by: -1) } label: { Text("−1").frame(width: 36) }
                        .buttonStyle(.bordered)
                    Button { nudge(k, by: 1) } label: { Text("+1").frame(width: 36) }
                        .buttonStyle(.bordered)
                    Button { nudge(k, by: -5) } label: { Text("−5").frame(width: 36) }
                        .buttonStyle(.bordered)
                    Button { nudge(k, by: 5) } label: { Text("+5").frame(width: 36) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .pivotGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func nudge(_ k: Keyframe, by d: Double) {
        guard var ks = keys[selected], let i = ks.firstIndex(where: { $0.id == k.id }) else { return }
        ks[i].v += d
        keys[selected] = ks
    }

    // MARK: Seeding and export

    private func seed() {
        var out: [Int: [Keyframe]] = [:]
        for c in channels where trace.moved(c) {
            out[c] = trace.keyTimes(c).map { Keyframe(t: $0, v: trace.value(c, at: $0)) }
        }
        keys = out
        selected = channels.first { trace.moved($0) } ?? -1
        includeRail = trace.hasRail
    }

    /// Build a movement from the EDITED keyframes, not from the raw recording — otherwise every
    /// change made on this screen is silently discarded at the one moment it matters.
    private func makeMotion() {
        var times: Set<Double> = []
        for (_, ks) in keys { times.formUnion(ks.map(\.t)) }
        let sorted = times.sorted()
        var merged: [Double] = []
        for t in sorted where merged.last.map({ t - $0 > 0.15 }) ?? true { merged.append(t) }
        guard merged.count > 1 else { return }

        func valueAt(_ c: Int, _ t: Double) -> Double {
            guard let ks = keys[c]?.sorted(by: { $0.t < $1.t }), let f = ks.first else {
                return trace.value(c, at: t)
            }
            if t <= f.t { return f.v }
            guard let l = ks.last else { return f.v }
            if t >= l.t { return l.v }
            for i in 1..<ks.count where ks[i].t >= t {
                let a = ks[i - 1], b = ks[i]
                let s = b.t - a.t
                guard s > 0 else { return b.v }
                return a.v + (b.v - a.v) * ((t - a.t) / s)
            }
            return l.v
        }

        var poses: [ArmPose] = []
        for i in 1..<merged.count {
            let t = merged[i]
            let dt = max(0.05, t - merged[i - 1])
            let js = (0..<XArmLink.jointCount).map { valueAt($0, t) }
            let prev = (0..<XArmLink.jointCount).map { valueAt($0, merged[i - 1]) }
            let sweep = zip(js, prev).map { abs($0 - $1) }.max() ?? 0
            poses.append(ArmPose(joints: js,
                                 speed: min(60, max(5, sweep / dt)),
                                 dwell: 0,
                                 rail: includeRail && trace.hasRail ? valueAt(-1, t) : nil))
        }

        let m = ArmMotion(name: saveName.isEmpty ? trace.name : saveName, poses: poses)
        motions.save(m)
        dismiss()
    }
}
