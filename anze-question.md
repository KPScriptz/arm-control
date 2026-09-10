# Draft email to Anže Arzenšek — Glamatic PLC behaviour

**Subject:** Glamatic slider — unexpected movement after a manual-mode move completes

---

Hi Anže,

We've built an iPad app that drives the Glamatic slider over the web interface
(`/awp/Glamatic/IOServer.htm`, the `"IOMotor".*` tags). Selecting and running your stored programs
works reliably. Where we're stuck is with **manual moves** — writing `Position` / `Velocety` and
pulsing `Execute` — and I'd rather ask than keep experimenting on the machine.

## What happens

A manual move completes normally, we de-energise, and then **the carriage starts moving on its own
a short time later** — travelling back and forth continuously until the E-stop is pressed. It has
happened three times, always after an app-driven manual move, and never after running one of your
stored programs.

Here is the complete command sequence we send, with nothing omitted:

```
"IOMotor".Manual   = 1
"IOMotor".Enable   = 1
        (400 ms pause)
"IOMotor".Velocety = 85
"IOMotor".Position = 600
        (200 ms pause)
"IOMotor".Execute  = 1
        (300 ms pause)
"IOMotor".Execute  = 0
        (poll CurrentPosition until it arrives)

"IOMotor".Velocety = 85
"IOMotor".Position = 0
"IOMotor".Execute  = 1 → 0        (same pulse)
        (arrives at 0)

"IOMotor".Enable   = 0
```

Both legs completed correctly and `CurrentPosition` confirmed arrival at each. After `Enable = 0`
the app sent **no further commands at all** — we log every write, and the log is silent for the
whole period during which the carriage was moving.

## What we would like to understand

1. **On re-energising (`Enable` 0 → 1) with a `Position` setpoint still loaded, does the drive act
   on that stale setpoint?** We leave the last commanded position in the tag; we don't clear it.

2. **Is `Execute` edge-triggered or level-triggered?** We pulse it 1 → 0 after ~300 ms. If it is
   level-triggered, or if the falling edge means something different from what we assume, we may be
   re-triggering moves without intending to.

3. **Is there internal state that can re-trigger a move after one completes** — a retry, a
   watchdog, a "return to start" behaviour, or anything that resumes on its own?

4. **What is the correct shutdown sequence** to leave the rail in a safe, quiescent state? At the
   moment we clear `RunProgram`, `Execute` and `ExecuteHoming` to 0, set `Enable = 0`, then
   `Manual = 0`. Is that right, and is the ordering correct?

5. **Can the trigger tags be read back?** `RunProgram`, `Execute`, `ExecuteHoming`, `Enable` and
   `Manual` all appear write-only — the `IOServer.htm` response returns only `StatusError`,
   `Velocety`, `Position`, `StatusHomed`, `CurrentPosition`, `RobotError`, `RobotOfflineTask` and
   `ProgramNum`. We can write a 0 but never confirm it took, which makes this class of fault very
   hard to diagnose. Is there any way to read them?

6. **What is the actual maximum velocity?** The documentation we have says 70–100 mm/s, but your own
   stored programs clearly exceed it — program 14 covers 600 mm in 4.2 s (≈143 mm/s) and program 1
   appears faster still. We have limited our app to 143 mm/s on the basis that your program 14 runs
   there, but we'd rather use the real figure than infer one.

Also worth mentioning: the built-in web server stops issuing usable sessions after a busy period —
`Intro.mwsl` and the ENTER handshake return 200 and the login POST succeeds, but every subsequent
read redirects to the login page until the control box is power-cycled. When that happens we have no
way to stop the rail from software, which is what makes question 3 the pressing one.

Thanks very much — happy to send full logs or a capture of the traffic if that would help.

Best regards,
Kyle

---

## Notes for Kyle (not part of the email)

- I don't have Anže's address; add it before sending.
- Question 6 is worth asking even though it isn't about the fault — the answer changes what the
  movement editor can offer, and right now we're guessing from trace measurements.
- If he asks for logs: `Documents/glamatic.log` on the iPad has every write with timestamps. The
  relevant window is 2026-09-10 17:18:39–17:18:57 (the clean run) and everything after it (silence,
  while the rail moved).
