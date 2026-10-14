import type { SaveResult } from "./save.ts";

export type Msg =
  | { type: "save-tab"; tab: { id?: number; url?: string; title?: string } }
  | { type: "refresh-badge"; tabId: number; url?: string }
  | { type: "process-queue" }
  | { type: "release-queue"; skipUrl?: string };

export type SaveTabReply = SaveResult;
