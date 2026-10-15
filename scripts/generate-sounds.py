"""Recreate Flozi's original soft audio cues with the Python standard library."""
import math
import pathlib
import struct
import wave

root = pathlib.Path(__file__).resolve().parent.parent / "Sources/Flozi/Resources"
root.mkdir(parents=True, exist_ok=True)
cues = {
    "start": [(523.25, 0, .16), (783.99, .085, .20)],
    "complete": [(659.25, 0, .18), (830.61, .09, .18), (987.77, .18, .28)],
    "waiting": [(698.46, 0, .24), (523.25, .17, .26)],
    "attention": [(392, 0, .23), (369.99, .13, .28)],
}
rate = 44100
for name, notes in cues.items():
    length = max(start + duration for _, start, duration in notes) + .05
    samples = []
    for i in range(int(length * rate)):
        t = i / rate
        value = 0.0
        for frequency, start, duration in notes:
            u = t - start
            if 0 <= u < duration:
                envelope = (1 - math.exp(-u * 100)) * math.exp(-u * 13) * (1 - u / duration)
                glide = frequency * (1 + .012 * math.exp(-u * 18))
                value += .18 * envelope * (math.sin(2 * math.pi * glide * u) + .16 * math.sin(2 * math.pi * frequency * 2 * u))
        samples.append(struct.pack("<h", int(max(-1, min(1, value)) * 32767)))
    with wave.open(str(root / f"flozi-{name}.wav"), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(b"".join(samples))
