// Half-second, 48 kHz mono PCM fixture for prepared-listening UI tests.
// Self-contained so the browser preload can serialize it without dependencies.
export function wavFixture() {
  const buffer = new ArrayBuffer(48044), view = new DataView(buffer)
  const text = (offset, value) => [...value].forEach((char, i) => view.setUint8(offset + i, char.charCodeAt(0)))
  text(0, 'RIFF'); view.setUint32(4, 48036, true); text(8, 'WAVE')
  text(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true)
  view.setUint16(22, 1, true); view.setUint32(24, 48000, true)
  view.setUint32(28, 96000, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true)
  text(36, 'data'); view.setUint32(40, 48000, true)
  for (let i = 0; i < 24000; i++) view.setInt16(44 + i * 2, Math.sin(i * .03) * 3000, true)
  return buffer
}
