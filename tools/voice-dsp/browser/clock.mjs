// Input is available only after the final sample in its block has arrived.
export const blockReleaseMs = (start, count) => (start + count) / 48
