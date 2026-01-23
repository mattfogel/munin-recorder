# Munin TODO

## Audio Quality

- [ ] **Microphone audio has slight robotic artifacts** - mixing works but quality could be improved
  - Potential fixes:
    - Add ring buffer to smooth timing jitter between incoming samples
    - Match audio formats exactly (skip conversion if mic already 48kHz mono float)
    - Increase mixer tap buffer size (trades latency for smoother audio)
    - Investigate AVAudioPlayerNode scheduling approach
