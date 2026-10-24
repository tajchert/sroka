/** Tiny FIFO job queue that runs at most `limit` jobs at once. */
export class RunQueue {
  private waiting: string[] = [];
  private active = 0;
  constructor(
    private limit: number,
    private runner: (key: string) => Promise<void>,
  ) {}

  /** Enqueue; returns true if it started immediately, false if it is waiting. */
  add(key: string): boolean {
    this.waiting.push(key);
    this.pump();
    return !this.waiting.includes(key);
  }

  /** Remove a waiting key; true if it was waiting. */
  remove(key: string): boolean {
    const i = this.waiting.indexOf(key);
    if (i < 0) return false;
    this.waiting.splice(i, 1);
    return true;
  }

  private pump(): void {
    while (this.active < this.limit && this.waiting.length) {
      const key = this.waiting.shift()!;
      this.active++;
      void this.runner(key)
        .catch(() => undefined)
        .finally(() => {
          this.active--;
          this.pump();
        });
    }
  }
}
