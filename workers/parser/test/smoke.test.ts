import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

describe("parser test harness", () => {
  it("LIBRARY DO binding resolves locally", async () => {
    const stub = (env as unknown as { LIBRARY: DurableObjectNamespace<import("../../api/src/library-do.ts").LibraryDO> }).LIBRARY.getByName("u1");
    expect(await stub.ping()).toBe("pong");
  });
});
