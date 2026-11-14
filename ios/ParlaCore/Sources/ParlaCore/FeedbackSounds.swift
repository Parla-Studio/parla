import Foundation

/// The short feedback sounds, generated in code exactly like shared/audio/FeedbackSounds.kt: a soft pop when a
/// word or an answer is picked, a warm two-note chime for a correct answer, a small chime for a found pair, a
/// gentle low tone for a wrong answer and a rising four-note chime when a lesson is finished. Each sound is
/// returned as a complete WAV file (16-bit mono, 44.1 kHz) that AVAudioPlayer can play directly.
public enum FeedbackSounds {
    public static let sampleRate = 44_100

    private struct Note {
        var freq: Double
        var start: Double
        var length: Double
        var volume: Double
        var decay: Double
        var attack: Double = 0.008
        var octave: Double = 0
        var glideTo: Double? = nil
    }

    public static let tap: Data = wav(render([
        Note(freq: 700, start: 0, length: 0.08, volume: 0.07, decay: 45, attack: 0.003, glideTo: 560),
    ], echo: false))

    public static let correct: Data = wav(render([
        Note(freq: 659.25, start: 0, length: 0.5, volume: 0.11, decay: 6, octave: 0.12),     // E5
        Note(freq: 880.0, start: 0.085, length: 0.7, volume: 0.12, decay: 5, octave: 0.12),  // A5
    ]))

    public static let pair: Data = wav(render([
        Note(freq: 880.0, start: 0, length: 0.35, volume: 0.08, decay: 10, octave: 0.1),     // A5
    ]))

    public static let wrong: Data = wav(render([
        Note(freq: 392.0, start: 0, length: 0.25, volume: 0.09, decay: 9, attack: 0.012, octave: 0.06),     // G4
        Note(freq: 329.63, start: 0.11, length: 0.35, volume: 0.09, decay: 8, attack: 0.012, octave: 0.06), // E4
    ]))

    public static let lessonComplete: Data = wav(render([
        Note(freq: 523.25, start: 0, length: 0.45, volume: 0.10, decay: 6, octave: 0.12),    // C5
        Note(freq: 659.25, start: 0.11, length: 0.45, volume: 0.10, decay: 6, octave: 0.12), // E5
        Note(freq: 783.99, start: 0.22, length: 0.5, volume: 0.10, decay: 5.5, octave: 0.12),// G5
        Note(freq: 1046.5, start: 0.33, length: 1.0, volume: 0.11, decay: 3.5, octave: 0.10),// C6
        // Soft chord underneath the last note
        Note(freq: 523.25, start: 0.33, length: 1.0, volume: 0.035, decay: 2.5, attack: 0.04),
        Note(freq: 659.25, start: 0.33, length: 1.0, volume: 0.035, decay: 2.5, attack: 0.04),
        Note(freq: 783.99, start: 0.33, length: 1.0, volume: 0.035, decay: 2.5, attack: 0.04),
    ]))

    private static let lead = 0.005  // seconds of silence before the sound
    private static let tail = 0.12   // seconds of silence after it (plus the echo)

    /// 16-bit samples of the sound (same maths as the Kotlin version).
    private static func render(_ notes: [Note], echo: Bool = true) -> [Int16] {
        let rate = Double(sampleRate)
        let leadSamples = Int(lead * rate)
        let echo1 = Int(0.075 * rate)
        let echo2 = Int(0.15 * rate)
        let body = notes.map { Int($0.start * rate) + Int($0.length * rate) }.max() ?? 0
        let n = leadSamples + body + (echo ? echo2 : 0) + Int(tail * rate)
        var dry = [Double](repeating: 0, count: n)
        for note in notes {
            let from = leadSamples + Int(note.start * rate)
            let len = Int(note.length * rate)
            var phase = 0.0
            for i in 0..<len {
                let t = Double(i) / rate
                let f = note.glideTo.map { note.freq + ($0 - note.freq) * (Double(i) / Double(len)) } ?? note.freq
                phase += 2 * Double.pi * f / rate
                // Smooth attack, exponential decay and a 20 ms fade at the end, so no note ends abruptly.
                let attack = min(1.0, t / note.attack)
                let env = attack * attack * exp(-note.decay * t) * min(1.0, Double(len - i) / (rate * 0.02))
                let v = sin(phase) + note.octave * sin(2 * phase)
                dry[from + i] += v * env * note.volume
            }
        }
        var wet = dry
        if echo {
            for i in 0..<n {
                var v = dry[i]
                if i >= echo1 { v += 0.18 * dry[i - echo1] }
                if i >= echo2 { v += 0.07 * dry[i - echo2] }
                wet[i] = v
            }
        }
        // Gentle one-pole low-pass (about 3.5 kHz) takes the edge off.
        let alpha = 1 - exp(-2 * Double.pi * 3500 / rate)
        var y = 0.0
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            y += alpha * (wet[i] - y)
            out[i] = Int16(max(-1.0, min(1.0, y)) * Double(Int16.max))
        }
        return out
    }

    /// Wraps 16-bit mono samples in a WAV container.
    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let pcmBytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + pcmBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                          // chunk size
        append16(1)                           // PCM
        append16(1)                           // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))      // byte rate
        append16(2)                           // block align
        append16(16)                          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(pcmBytes)
        for s in samples { append16(UInt16(bitPattern: s)) }
        return data
    }
}
