import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AddFab } from "./AddFab.tsx";

describe("AddFab", () => {
  afterEach(cleanup);

  it("opens the popup, saves a link and closes", async () => {
    const onAdd = vi.fn().mockResolvedValue(true);
    render(<AddFab onAdd={onAdd} onPickPdf={() => {}} />);
    expect(screen.queryByRole("dialog")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    const input = screen.getByLabelText("Page address");
    expect(document.activeElement).toBe(input);
    fireEvent.change(input, { target: { value: "example.com/a" } });
    fireEvent.submit(input.closest("form")!);
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(onAdd).toHaveBeenCalledWith("example.com/a");
  });

  it("keeps the popup open when saving fails", async () => {
    const onAdd = vi.fn().mockResolvedValue(false);
    render(<AddFab onAdd={onAdd} onPickPdf={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    const input = screen.getByLabelText("Page address");
    fireEvent.change(input, { target: { value: "bad" } });
    fireEvent.submit(input.closest("form")!);
    await waitFor(() => expect(onAdd).toHaveBeenCalled());
    expect(screen.getByRole("dialog")).toBeTruthy();
    expect((screen.getByLabelText("Page address") as HTMLInputElement).value).toBe("bad");
  });

  it("offers PDF upload and closes on Escape", () => {
    const onPickPdf = vi.fn();
    render(<AddFab onAdd={vi.fn()} onPickPdf={onPickPdf} />);
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByRole("dialog")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    fireEvent.click(screen.getByRole("button", { name: "upload a PDF" }));
    expect(onPickPdf).toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
