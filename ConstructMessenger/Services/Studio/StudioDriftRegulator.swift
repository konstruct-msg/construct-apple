//
//  StudioDriftRegulator.swift
//  Construct Messenger
//
//  Holds the studio playout buffer at its target depth by nudging the playback rate. The host's
//  sound card and the listener's run at slightly different rates (tens of ppm), so without this
//  the buffer slowly fills or empties; a fill above target plays slightly faster, below slightly
//  slower. The rate goes to the output's varispeed — the asynchronous sample-rate conversion the
//  decision calls for, with no resampler of our own.
//
//  A PI loop on the smoothed fill error. With the gains below it is critically damped with a
//  natural period of about ten minutes: far slower than the jitter of packets arriving (which the
//  smoothing also absorbs) and fast enough for drift, which is constant. The rate is clamped to
//  ±500 ppm — under one cent of pitch — and the integral stops growing while it is clamped.
//

import Foundation

struct StudioDriftRegulator {
    var targetSeconds: Double
    var proportional = 0.02
    var integralGain = 0.0001
    /// Largest departure of the rate from 1.
    var maxDeviation = 500e-6
    /// Time constant of the fill smoothing, seconds.
    var smoothing = 2.0

    private var integral = 0.0
    private var smoothedFill: Double?

    init(targetSeconds: Double) {
        self.targetSeconds = targetSeconds
    }

    /// Feed the fill measured `dt` seconds after the previous one; returns the playback rate.
    mutating func update(fillSeconds: Double, dt: Double) -> Double {
        let alpha = min(1, dt / smoothing)
        let fill = smoothedFill.map { $0 + alpha * (fillSeconds - $0) } ?? fillSeconds
        smoothedFill = fill
        let error = fill - targetSeconds
        let unclamped = proportional * error + integralGain * (integral + error * dt)
        let deviation = max(-maxDeviation, min(maxDeviation, unclamped))
        if deviation == unclamped { integral += error * dt }
        return 1 + deviation
    }

    /// After an underrun the buffer refills from empty; what the loop learned about the error is
    /// no longer true of it. The drift it integrated still is, so the integral is kept.
    mutating func refilled() {
        smoothedFill = nil
    }
}
