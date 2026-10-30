#!/usr/bin/env python
"""Convert a Markdown file to PDF (tables, fenced code blocks, headings)."""
import sys

import markdown
from xhtml2pdf import pisa

CSS = """
<style>
  body { font-family: Helvetica, Arial, sans-serif; font-size: 10.5pt; line-height: 1.4; }
  h1 { font-size: 18pt; border-bottom: 2px solid #76b900; padding-bottom: 4px; }
  h2 { font-size: 14pt; color: #2b2b2b; border-bottom: 1px solid #ccc; padding-bottom: 2px; margin-top: 20px; }
  h3 { font-size: 12pt; color: #2b2b2b; margin-top: 14px; }
  code { font-family: Courier, monospace; background-color: #f2f2f2; padding: 1px 3px; }
  pre { font-family: Courier, monospace; background-color: #f2f2f2; padding: 8px; font-size: 9pt;
        white-space: pre-wrap; border: 1px solid #ddd; }
  pre code { background-color: transparent; padding: 0; }
  table { border-collapse: collapse; width: 100%; margin: 10px 0; }
  th, td { border: 1px solid #999; padding: 5px 8px; font-size: 9.5pt; text-align: left; }
  th { background-color: #e8e8e8; }
  blockquote { border-left: 3px solid #76b900; margin: 8px 0; padding: 2px 12px; color: #333;
               background-color: #f7f9f2; }
  a { color: #0a6; }
</style>
"""


def convert(md_path: str, pdf_path: str) -> None:
    with open(md_path, encoding="utf-8") as f:
        text = f.read()

    html_body = markdown.markdown(
        text, extensions=["extra", "sane_lists", "toc", "fenced_code", "tables"]
    )
    html = f"<html><head>{CSS}</head><body>{html_body}</body></html>"

    with open(pdf_path, "wb") as out:
        result = pisa.CreatePDF(html, dest=out)
    if result.err:
        sys.exit(f"Failed to generate PDF ({result.err} errors)")
    print(f"Wrote {pdf_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: md_to_pdf.py <input.md> <output.pdf>")
    convert(sys.argv[1], sys.argv[2])
