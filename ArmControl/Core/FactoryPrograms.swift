import Foundation

// MARK: - The factory arm programs, as data
//
// 🔑 **GENERATED FROM THE xARM STUDIO EXPORT — do not hand-edit; regenerate from the source.**
// Source: the Blockly-generated Python that runs ON the xArm controller (`robottheword.txt`,
// received 2026-09-10). Its `run()` loop polls six digital inputs on the controller and branches on
// their binary pattern — six bits, 64 values, matching `ProgramNumber 0–63` on the Siemens PLC. So
// the architecture is: **the PLC drives the rail itself and raises the program number on six output
// wires; the xArm decodes them and runs the matching branch.** That is `RobotOfflineTask`, and it is
// why program 14 moves the arm although the Siemens holds no arm trajectory.
//
// Every `set_servo_angle` in that file is a pose below, with the `_angle_speed` and `_angle_acc`
// in effect when it was issued, and any following `set_pause_time` folded into `dwell`.
//
// ⚠️ **What this import cannot carry:** `set_position` (cartesian moves), `move_circle` (arcs) and
// `move_gohome`. Programs that use them are marked in `caveats` — they are the joint-space part of
// the program, not the whole of it. Blending radius is also dropped: the app's player is
// point-to-point. For program 14 that is exact (every radius there is 0).
//
// 🔑 **THE JOINT ENVELOPE THE FACTORY ACTUALLY USES**, across all 37 programs:
//   J1 −174.5 … 180.0 · J2 −99.9 … 117.4 · J3 −213.5 … −12.5 · J4 −91.7 … 166.2 · J5 −215.5 … 90.0
// These replace every guessed limit in this app. They are proven on this mechanism the way the
// rail's 143 mm/s is: the manufacturer's own programs drive there, as delivered.

enum FactoryPrograms {

    /// Joint ranges the factory programs actually reach. Used as the simulator's envelope and the
    /// editor's slider bounds. NOT the mechanism's absolute limits — the working range that is
    /// demonstrably safe.
    static let envelope: [ClosedRange<Double>] = [
        -174.5...180.0,
        -99.9...117.4,
        -213.5...(-12.5),
        -91.7...166.2,
        -215.5...90.0,
    ]

    /// Fastest joint speed any factory program commands, °/s.
    static let maxSpeed: Double = 180

    /// Every program that has at least one joint pose, keyed by number.
    static let all: [ArmMotion] = [
        ArmMotion(name: "Program 1", poses: [
            ArmPose(joints: [-90.0, -0.4, -183.7, -16.5, -90.0], speed: 120, dwell: 0.00, rail: nil, acc: 500),
            ArmPose(joints: [-90.0, -99.9, -164.7, 84.2, -90.0], speed: 120, dwell: 1.00, rail: nil, acc: 500),
            ArmPose(joints: [-90.0, -0.4, -183.7, -16.5, -90.0], speed: 55, dwell: 0.00, rail: nil, acc: 500),
        ], program: 1, caveats: []),
        ArmMotion(name: "Program 2", poses: [
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 180, dwell: 1.00, rail: nil, acc: 1146),
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 80, dwell: 0.00, rail: nil, acc: 1146),
        ], program: 2, caveats: ["cartesian set_position (not a joint pose)"]),
        ArmMotion(name: "Program 3", poses: [
            ArmPose(joints: [-87.1, 65.8, -136.0, 70.2, -203.8], speed: 125, dwell: 0.00, rail: nil, acc: 600),
            ArmPose(joints: [91.7, 65.8, -136.0, 72.2, 25.4], speed: 125, dwell: 0.00, rail: nil, acc: 600),
            ArmPose(joints: [-87.1, 65.8, -136.0, 70.2, -203.8], speed: 125, dwell: 0.00, rail: nil, acc: 600),
        ], program: 3, caveats: []),
        ArmMotion(name: "Program 4", poses: [
            ArmPose(joints: [-1.4, 116.6, -134.5, 5.3, -89.7], speed: 170, dwell: 0.00, rail: nil, acc: 1000),
            ArmPose(joints: [4.6, -9.5, -135.7, 160.5, -84.9], speed: 170, dwell: 0.00, rail: nil, acc: 1000),
            ArmPose(joints: [2.9, 41.7, -129.7, 88.1, -85.5], speed: 170, dwell: 0.00, rail: nil, acc: 500),
            ArmPose(joints: [69.4, 12.6, -113.2, 100.6, 2.9], speed: 170, dwell: 0.00, rail: nil, acc: 500),
            ArmPose(joints: [-0.5, 107.2, -119.6, -12.0, -89.1], speed: 170, dwell: 0.00, rail: nil, acc: 500),
            ArmPose(joints: [-90.1, -11.5, -71.7, 83.3, -214.5], speed: 170, dwell: 0.00, rail: nil, acc: 500),
            ArmPose(joints: [-1.4, 116.6, -134.5, 5.3, -89.7], speed: 170, dwell: 0.00, rail: nil, acc: 500),
        ], program: 4, caveats: []),
        ArmMotion(name: "Program 5", poses: [
            ArmPose(joints: [0.0, -65.1, -12.7, 77.8, -90.0], speed: 150, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [0.0, -53.6, -50.7, 117.3, -90.0], speed: 150, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [90.2, 63.4, -135.8, 72.4, 31.1], speed: 150, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [4.5, -22.5, -13.2, 35.6, -85.0], speed: 150, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [-86.6, 63.4, -135.8, 72.4, -215.5], speed: 150, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [0.0, 86.6, -175.9, 83.9, -90.0], speed: 150, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [2.5, 6.7, -119.4, 130.9, -86.6], speed: 150, dwell: 1.00, rail: nil, acc: 700),
            ArmPose(joints: [0.0, -65.1, -12.7, 77.8, -90.0], speed: 50, dwell: 0.00, rail: nil, acc: 600),
        ], program: 5, caveats: ["move_circle"]),
        ArmMotion(name: "Program 6", poses: [
            ArmPose(joints: [0.0, -50.3, -97.0, 164.2, -90.0], speed: 90, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [0.0, 50.1, -135.3, 85.1, -89.4], speed: 90, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [0.0, 117.4, -124.6, -12.2, -90.0], speed: 90, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [0.0, -52.3, -20.6, 76.3, -89.4], speed: 90, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [75.1, 35.3, -110.6, 75.3, 5.3], speed: 140, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [-68.8, 35.3, -110.6, 75.3, -189.3], speed: 140, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [0.0, -50.3, -97.0, 164.2, -90.0], speed: 110, dwell: 0.00, rail: nil, acc: 300),
        ], program: 6, caveats: []),
        ArmMotion(name: "Program 7", poses: [
            ArmPose(joints: [-90.0, 90.0, -180.0, 90.0, -201.1], speed: 100, dwell: 0.00, rail: nil, acc: 100),
            ArmPose(joints: [90.0, 90.0, -180.0, 90.0, 19.0], speed: 100, dwell: 0.00, rail: nil, acc: 100),
            ArmPose(joints: [-90.0, 90.0, -180.0, 90.0, -201.1], speed: 100, dwell: 0.00, rail: nil, acc: 100),
        ], program: 7, caveats: []),
        ArmMotion(name: "Program 9", poses: [
            ArmPose(joints: [0.0, -86.8, -12.5, 99.3, -90.0], speed: 180, dwell: 0.00, rail: nil, acc: 400),
            ArmPose(joints: [0.0, 35.0, -129.6, 103.1, -90.1], speed: 180, dwell: 0.00, rail: nil, acc: 400),
            ArmPose(joints: [0.0, -86.8, -12.5, 99.3, -90.0], speed: 180, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [88.5, 65.9, -137.7, 71.8, 28.6], speed: 180, dwell: 0.00, rail: nil, acc: 200),
            ArmPose(joints: [1.3, 57.7, -137.7, 79.9, -87.5], speed: 180, dwell: 0.00, rail: nil, acc: 200),
        ], program: 9, caveats: []),
        ArmMotion(name: "Program 11", poses: [
            ArmPose(joints: [-74.5, 58.8, -150.9, 92.1, -187.4], speed: 100, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [-2.1, 116.3, -129.4, -17.2, -90.0], speed: 100, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [82.5, 58.8, -150.9, 92.1, 20.0], speed: 100, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [-2.1, 116.3, -129.4, -17.2, -90.0], speed: 100, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [-74.5, 58.8, -150.9, 92.1, -187.4], speed: 100, dwell: 0.00, rail: nil, acc: 300),
        ], program: 11, caveats: []),
        ArmMotion(name: "Program 12", poses: [
            ArmPose(joints: [90.0, 90.0, -180.0, 90.0, 25.7], speed: 90, dwell: 0.00, rail: nil, acc: 600),
            ArmPose(joints: [90.0, 90.0, -180.0, 90.0, 25.7], speed: 90, dwell: 0.00, rail: nil, acc: 600),
        ], program: 12, caveats: []),
        ArmMotion(name: "Program 14", poses: [
            ArmPose(joints: [90.0, 1.4, -148.3, 166.2, -90.0], speed: 115, dwell: 0.00, rail: nil, acc: 600),
            ArmPose(joints: [90.0, 59.0, -127.4, 68.4, -90.0], speed: 115, dwell: 0.30, rail: nil, acc: 600),
            ArmPose(joints: [180.0, 62.7, -126.2, 63.5, 15.3], speed: 100, dwell: 0.00, rail: nil, acc: 200),
            ArmPose(joints: [0.0, 62.7, -126.2, 63.5, -199.0], speed: 100, dwell: 0.00, rail: nil, acc: 200),
            ArmPose(joints: [90.0, 59.0, -127.4, 68.4, -90.0], speed: 100, dwell: 0.00, rail: nil, acc: 200),
            ArmPose(joints: [90.0, 1.4, -148.3, 166.2, -90.0], speed: 100, dwell: 0.00, rail: nil, acc: 200),
        ], program: 14, caveats: []),
        ArmMotion(name: "Program 15", poses: [
            ArmPose(joints: [-62.8, 55.8, -116.8, 31.0, -178.0], speed: 110, dwell: 0.00, rail: nil, acc: 350),
            ArmPose(joints: [-62.8, 55.8, -116.8, 91.0, -178.0], speed: 110, dwell: 0.00, rail: nil, acc: 350),
            ArmPose(joints: [62.8, 55.8, -116.8, 31.0, 15.2], speed: 110, dwell: 0.00, rail: nil, acc: 350),
            ArmPose(joints: [62.8, 55.8, -116.8, 91.0, 15.2], speed: 110, dwell: 0.00, rail: nil, acc: 350),
        ], program: 15, caveats: []),
        ArmMotion(name: "Program 16", poses: [
            ArmPose(joints: [52.8, 75.6, -123.9, 48.3, -12.6], speed: 150, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [73.5, 52.7, -161.2, 108.5, 4.7], speed: 150, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [-52.8, 75.6, -123.9, 48.3, -169.2], speed: 150, dwell: 0.00, rail: nil, acc: 300),
        ], program: 16, caveats: []),
        ArmMotion(name: "Program 17", poses: [
            ArmPose(joints: [0.0, 22.2, -88.6, 66.3, -96.8], speed: 150, dwell: 0.00, rail: nil, acc: 900),
        ], program: 17, caveats: []),
        ArmMotion(name: "Program 18", poses: [
            ArmPose(joints: [-39.5, 20.0, -71.2, 51.2, -149.1], speed: 100, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [9.9, 46.4, -127.2, 84.2, -87.4], speed: 100, dwell: 0.00, rail: nil, acc: 300),
            ArmPose(joints: [87.8, 71.1, -145.4, 74.3, 24.2], speed: 100, dwell: 1.00, rail: nil, acc: 300),
        ], program: 18, caveats: []),
        ArmMotion(name: "Program 19", poses: [
            ArmPose(joints: [4.0, 57.1, -126.0, 70.0, -81.1], speed: 90, dwell: 0.00, rail: nil, acc: 200),
            ArmPose(joints: [7.6, -4.4, -123.4, 145.9, -80.3], speed: 50, dwell: 0.20, rail: nil, acc: 200),
        ], program: 19, caveats: []),
        ArmMotion(name: "Program 22", poses: [
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 180, dwell: 1.00, rail: nil, acc: 1146),
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 80, dwell: 0.00, rail: nil, acc: 1146),
        ], program: 22, caveats: ["cartesian set_position (not a joint pose)"]),
        ArmMotion(name: "Program 24", poses: [
            ArmPose(joints: [-90.0, -0.4, -183.7, -19.6, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 50),
            ArmPose(joints: [-90.0, -99.9, -164.7, 80.8, -90.0], speed: 70, dwell: 1.00, rail: nil, acc: 50),
            ArmPose(joints: [-90.0, -0.4, -183.7, -19.6, -90.0], speed: 50, dwell: 0.00, rail: nil, acc: 50),
        ], program: 24, caveats: []),
        ArmMotion(name: "Program 25", poses: [
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 100, dwell: 1.00, rail: nil, acc: 50),
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 80, dwell: 0.00, rail: nil, acc: 200),
        ], program: 25, caveats: ["cartesian set_position (not a joint pose)"]),
        ArmMotion(name: "Program 26", poses: [
            ArmPose(joints: [-3.0, 11.1, -102.4, 91.3, -200.6], speed: 180, dwell: 0.00, rail: nil, acc: 50),
            ArmPose(joints: [150.5, 49.3, -110.4, 61.0, -16.1], speed: 180, dwell: 2.00, rail: nil, acc: 50),
            ArmPose(joints: [-3.0, 11.1, -102.4, 91.3, -200.6], speed: 60, dwell: 0.00, rail: nil, acc: 50),
        ], program: 26, caveats: []),
        ArmMotion(name: "Program 27", poses: [
            ArmPose(joints: [-90.0, 0.0, -177.5, -23.4, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 40),
            ArmPose(joints: [-90.0, -93.7, -209.4, 123.8, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 40),
            ArmPose(joints: [-174.5, -98.9, -213.5, 133.2, 9.7], speed: 70, dwell: 1.00, rail: nil, acc: 40),
            ArmPose(joints: [-90.0, 0.0, -177.5, -23.4, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 40),
        ], program: 27, caveats: []),
        ArmMotion(name: "Program 28", poses: [
            ArmPose(joints: [0.0, 73.3, -160.6, -91.7, 90.0], speed: 180, dwell: 1.00, rail: nil, acc: 60),
        ], program: 28, caveats: []),
        ArmMotion(name: "Program 30", poses: [
            ArmPose(joints: [-90.0, -0.4, -183.7, -19.6, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 50),
            ArmPose(joints: [-90.0, -99.9, -164.7, 80.8, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 50),
            ArmPose(joints: [-146.1, -98.2, -164.7, 83.5, -14.8], speed: 70, dwell: 0.00, rail: nil, acc: 50),
            ArmPose(joints: [-33.9, -98.2, -164.7, 83.5, -164.0], speed: 70, dwell: 1.00, rail: nil, acc: 50),
            ArmPose(joints: [-90.0, -0.4, -183.7, -19.6, -90.0], speed: 50, dwell: 0.00, rail: nil, acc: 50),
        ], program: 30, caveats: []),
        ArmMotion(name: "Program 31", poses: [
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 50),
            ArmPose(joints: [150.5, 11.2, -83.8, 72.7, -15.9], speed: 30, dwell: 1.00, rail: nil, acc: 50),
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 80, dwell: 0.00, rail: nil, acc: 200),
        ], program: 31, caveats: ["cartesian set_position (not a joint pose)"]),
        ArmMotion(name: "Program 32", poses: [
            ArmPose(joints: [-2.2, 60.6, -137.7, 77.1, -201.5], speed: 100, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [90.0, 30.1, -142.3, 116.3, -91.7], speed: 100, dwell: 0.00, rail: nil, acc: 700),
            ArmPose(joints: [-2.2, 60.6, -137.7, 77.1, -201.5], speed: 30, dwell: 0.00, rail: nil, acc: 700),
        ], program: 32, caveats: []),
        ArmMotion(name: "Program 36", poses: [
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 60, dwell: 1.00, rail: nil, acc: 500),
            ArmPose(joints: [90.0, 16.3, -159.5, 151.0, -90.0], speed: 55, dwell: 1.00, rail: nil, acc: 200),
            ArmPose(joints: [90.0, -72.8, -21.9, 94.7, -90.0], speed: 60, dwell: 0.00, rail: nil, acc: 200),
        ], program: 36, caveats: ["cartesian set_position (not a joint pose)"]),
        ArmMotion(name: "Program 37", poses: [
            ArmPose(joints: [-90.0, -99.9, -164.7, 80.8, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 50),
            ArmPose(joints: [-90.0, -0.4, -183.7, -19.6, -90.0], speed: 70, dwell: 1.00, rail: nil, acc: 50),
            ArmPose(joints: [-90.0, -99.9, -164.7, 80.8, -90.0], speed: 50, dwell: 0.00, rail: nil, acc: 50),
        ], program: 37, caveats: []),
        ArmMotion(name: "Program 38", poses: [
            ArmPose(joints: [90.0, 46.5, -137.6, 91.1, -90.0], speed: 70, dwell: 2.00, rail: nil, acc: 390),
            ArmPose(joints: [90.0, 46.5, -137.6, 91.1, -90.0], speed: 70, dwell: 0.00, rail: nil, acc: 390),
        ], program: 38, caveats: ["cartesian set_position (not a joint pose)"]),
    ]

    static func program(_ n: Int) -> ArmMotion? { all.first { $0.program == n } }
}
