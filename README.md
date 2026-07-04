# OpenSurreal
A Swift package for using **Surreal Touch** 6DOF controllers in visionOS apps. Discover and connect over Bluetooth LE, stream pose / buttons / haptics, and fuse the controller with **ARKit hand tracking** to place it accurately in the headset's world space.

## Features
- **One type to adopt: `SurrealControllerSession`** — manages the player's controllers and vends their input as async streams.
- **Drop-in management UI:** `SurrealControllerView(session:)` is a complete connect / pair / manage view.
- **Fully-featured:** buttons, analogue stick, analogue trigger & grip, haptics, and 6DOF pose — controller-frame and world-space.

## Installation
### Required Info.plist keys
| Key | When | Why |
|-----|------|-----|
| `NSBluetoothAlwaysUsageDescription` | always | Bluetooth is required in order to communicate with the Surreal Touch controllers.|
| `NSHandsTrackingUsageDescription` | spatial tracking | Hand tracking is required in order to maintain accurate positioning of the controllers.|

## Quick start
Create a `SurrealControllerSession`, show its vended UI so the player can connect/pair their controllers, and read input from its streams. Every event is tagged with the hand it came from, so there are no controller objects to juggle.

```swift
import SwiftUI
import OpenSurreal

struct GameView: View {
    @State private var session = SurrealControllerSession()   // auto-reconnects last controllers
    @State private var showingControllerSettings = false

    var body: some View {
        MyGameView()
            .sheet(isPresented: $showingControllerSettings) {
                // Drop-in connect / pair / manage UI from OpenSurreal. onDone adds
                // a Done toolbar button — sheets have no built-in dismiss control.
                SurrealControllerView(session: session) { showingControllerSettings = false }
            }
            .task {
                for await pose in session.poseUpdates {
                    // 6DOF pose for either the left or right controller.
                    renderer.update(pose.handedness, pose.position, pose.orientation)
                }
            }
            .task {
                for await update in session.buttonUpdates {
                    // Some button state has changed.            
                    if update.primaryButton { fire(update.handedness) }
                }
            }
    }
}
```

## Connection state
The session publishes its overall connection state both as an observable property you can inspect and as an event stream you can await:

```swift
// Inspect the current value any time (observable):
switch session.connectionState {
case .disconnected, .connecting:                 break
case .leftConnected, .rightConnected:            // one controller up
case .bothConnected:                             // both up
}

// Or react to changes and to pause/resume as they happen:
for await event in session.stateUpdates {
    switch event {
    case .connection(let state): 
        updateHUD(state)
    case .paused(let hand):  
        // controller and hands are not moving together, so updates are paused
    case .resumed(let hand):
        // controller was picked up again, so updates are resumed
    }
}
```

## Haptics
Send a haptic pulse from code with `vibrate` — for example in response to game events:

```swift
session.vibrate(.right, amplitude: 0.8, frequency: 170, duration: 0.1)
```

- `amplitude` is normalized `0...1`; `frequency` is Hz, clamped to the device's `20...300`; `duration` is seconds, raised to the device minimum of 30 ms.
- Pass `.unspecified` to buzz every connected controller.
- Calls are fire-and-forget and safe at high rates: a pulse requested while the device is already vibrating resolves as a no-op.

The bundled `SurrealControllerView` also has a per-controller "Vibrate" test button.

## Reconnecting without a scan
OpenSurreal remembers the last-connected **left** and **right** controller (each new connection replaces that hand's slot). 
By default, a session reconnects to both the first time Bluetooth powers on — no scan, no UI. An idle controller reconnects the moment you turn it on. 
Pass `SurrealControllerSession(autoReconnectLastControllers: false)` to opt out.

## World-space tracking
A controller reports pose in **its own** frame: an arbitrary origin and heading set at power-on, plus IMU drift. To place it in an immersive scene you need its pose in the headset's world frame. Start spatial tracking when your `ImmersiveSpace` content appears (ARKit hand tracking requires being inside one) and read `worldPoseUpdates`:

```swift
RealityView { content in
    content.add(root)
    await session.startSpatialTracking()
}
.task {
    for await pose in session.worldPoseUpdates {
        entity(for: pose.handedness).transform = Transform(matrix: pose.transform)
    }
}
.onDisappear { session.stopSpatialTracking() }
```

`WorldPose.transform` is `worldFromController`, ready to drop onto a RealityKit `Entity` (also available decomposed as `.position` / `.orientation`). It flows only while spatial tracking is running and the matching hand is calibrated.

If controllers render tilted in your app, tune the session's pitch correction. It's applied in the controller's own body frame (so it stays correct whichever way the controller points) and can be changed live:

```swift
session.pitchAdjustmentDegrees = 55   // positive pitches the controller up; default 55
```

### How the fusion works
World poses are a calculated metric that is derived from the player's wrist position when the wrists are in view of the Vision Pro's cameras:
- **Position & orientation** come from the tracked wrist. Its position pushed forward onto the controller's body, and its orientation with a fixed per-hand correction so the controller points where it physically points. In testing, hand tracking is more stable and has less drift than relying on the controller's own positional data. While wrist-based position & orientation is active, `WorldPose.confidence` is reported as `1.0`.
- On each update, the controller's own tracking frame is re-registered against the wrist, so the controller carries on seamlessly from the *same place* the instant the wrist is lost.
- **The re-registration is adaptively smoothed** so hand-tracking jitter doesn't shake a controller that's held still. Noise-sized wrist/controller disagreements (millimetres, a degree or two) are damped hard; genuine misalignment corrects within a few frames; gross disagreement (a fresh pickup) snaps outright. This adds no lag to real motion at any speed — movement always rides the controller's own tracking at full rate, and the smoothing only acts on the alignment between the two tracking frames.
- **For ~2 s after a pickup the calibration snaps straight to the wrist** instead of smoothing toward it: a controller's own tracker goes through a transient after sitting still, and per-frame wrist snapping masks it until it re-converges.
When the wrist isn't tracked, the controller **coasts on its own tracking**, calibrated to the last moment the wrist was visible — and `WorldPose.confidence` reports the controller's own device confidence instead of `1.0`. It snaps back onto the wrist as soon as the hand reappears.
**Velocity** is the complete world-space velocity: the controller's own reported velocity (rotated into world axes) composed with the motion of the re-registration frame itself while the wrist is authoritative — so arm sweeps carry full velocity for throws and server-side prediction. While coasting, the frame is frozen and only the controller's own motion contributes.
**Held vs. released** is a derived state which is inferred from motion coherence: if the hand moves but the controller doesn't move — or rotate — with it, the controller is assumed set down. In this case, the pose freezes where it sits (rather than chasing the empty hand) and the session reports `.paused`, then `.resumed` on pickup. Rotation counts as evidence of holding because a controller lying on a surface can't rotate, and gyro-derived attitude stays trustworthy even while position tracking is still re-converging right after a pickup — for the same reason, "set down" verdicts are ignored during the post-pickup recovery window.

## Public API surface

| Type | Member | Purpose |
|------|--------|---------|
| `SurrealControllerSession` | `connectionState` | Current `SurrealConnectionState` (observable) |
| | `stateUpdates` | `AsyncStream<SurrealControllerEvent>` — connection changes + pause/resume |
| | `poseUpdates` / `worldPoseUpdates` / `buttonUpdates` | Aggregated `AsyncStream`s across both hands, each event tagged with `handedness` |
| | `startSpatialTracking()` / `stopSpatialTracking()` (visionOS) | Run world-space calibration inside an `ImmersiveSpace` |
| | `vibrate(_:amplitude:frequency:duration:)` | Haptic pulse for one hand (`.unspecified` = all); normalized amplitude, Hz, seconds |
| | `pitchAdjustmentDegrees` (visionOS) | Body-frame pitch correction on world poses; positive pitches up, live-tunable (default 55) |
| | `init(autoReconnectLastControllers:)` | Create a session (auto-reconnect defaults to `true`) |
| `SurrealControllerView` | `init(session:onDone:)` | Drop-in SwiftUI connect / pair / manage UI; `onDone` adds a Done toolbar button (pass it when hosting in a sheet, which has no built-in dismiss control) |
| `SurrealConnectionState` | `.disconnected` / `.connecting` / `.leftConnected` / `.rightConnected` / `.bothConnected` | Whole-session connection snapshot |
| `SurrealControllerEvent` | `.connection(_:)` / `.paused(_:)` / `.resumed(_:)` | Events on `stateUpdates` |
| `WorldPose` | `handedness` / `transform` / `position` / `orientation` / `confidence` / `linearVelocity` / `angularVelocity` / `acceleration` / `timestamp` / `sampleTime` / `predictedTransform(at:maxPrediction:)` | World-space pose sample (`confidence` is `1.0` while the wrist is authoritative; complete world velocities; `sampleTime` is the measurement time on the `CACurrentMediaTime()` clock; `predictedTransform` extrapolates to a display time) |
| `ControllerPose` | `handedness` / `position` / `orientation` / `confidence` / velocities / `timestamp` | Controller-frame 6DOF sample |
| `ButtonUpdate` | `handedness` / `primaryButton` / `secondaryButton` / `menuButton` / `joystickClick` / `trigger` / `grip` / `joystick` | Button / trigger / joystick snapshot |
| `Handedness` | `.left` / `.right` / `.unspecified` | Which hand, parsed from the device name |
