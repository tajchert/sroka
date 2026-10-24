/** Minimal valid PDF builders for tests (correct xref table; text via Helvetica Tj). */
export function buildPdf(opts: { pages?: string[]; title?: string; author?: string; lang?: string; encrypt?: boolean }): Uint8Array {
  const pages = opts.pages ?? ["Hello"];
  const esc = (s: string) => s.replace(/[\\()]/g, "\\$&");
  const objs: string[] = [];
  const n = pages.length;
  // 1 catalog, 2 pages, 3 font, 4 info, 5 encrypt, then page/content pairs from 6
  objs[1] = `<< /Type /Catalog /Pages 2 0 R${opts.lang ? ` /Lang (${opts.lang})` : ""} >>`;
  objs[2] = `<< /Type /Pages /Count ${n} /Kids [${pages.map((_, i) => `${6 + i * 2} 0 R`).join(" ")}] >>`;
  objs[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";
  objs[4] = `<< ${opts.title !== undefined ? `/Title (${esc(opts.title)})` : ""} ${opts.author ? `/Author (${esc(opts.author)})` : ""} >>`;
  objs[5] = "<< /Filter /Standard /V 1 /R 2 /O (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) /U (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) /P -4 >>";
  pages.forEach((text, i) => {
    const stream = text ? `BT /F1 12 Tf 72 720 Td (${esc(text)}) Tj ET` : "";
    objs[6 + i * 2] = `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${7 + i * 2} 0 R >>`;
    objs[7 + i * 2] = `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`;
  });
  let out = "%PDF-1.4\n";
  const offsets: number[] = [];
  for (let i = 1; i < objs.length; i++) {
    offsets[i] = out.length;
    out += `${i} 0 obj\n${objs[i]}\nendobj\n`;
  }
  const xref = out.length;
  out += `xref\n0 ${objs.length}\n0000000000 65535 f \n`;
  for (let i = 1; i < objs.length; i++) out += `${String(offsets[i]).padStart(10, "0")} 00000 n \n`;
  out += `trailer\n<< /Size ${objs.length} /Root 1 0 R /Info 4 0 R${opts.encrypt ? " /Encrypt 5 0 R /ID [<00112233445566778899aabbccddeeff> <00112233445566778899aabbccddeeff>]" : ""} >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(out);
}
