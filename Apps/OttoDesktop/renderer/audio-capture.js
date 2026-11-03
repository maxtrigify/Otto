// AudioWorklet: hands microphone frames (already at the context's 24 kHz) to the page in
// 40 ms blocks with their loudness, so the page can stream PCM16 and spot speech.
class PCMCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.block = new Float32Array(960);
    this.filled = 0;
  }

  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    let offset = 0;
    while (offset < channel.length) {
      const take = Math.min(channel.length - offset, this.block.length - this.filled);
      this.block.set(channel.subarray(offset, offset + take), this.filled);
      this.filled += take;
      offset += take;
      if (this.filled === this.block.length) {
        let energy = 0;
        for (const sample of this.block) energy += sample * sample;
        this.port.postMessage({ samples: this.block.slice(), rms: Math.sqrt(energy / this.block.length) });
        this.filled = 0;
      }
    }
    return true;
  }
}

registerProcessor('pcm-capture', PCMCapture);
