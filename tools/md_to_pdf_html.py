from pathlib import Path
import html
import re


def parse_inline(text: str) -> str:
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def markdown_to_html(markdown: str) -> str:
    lines = markdown.splitlines()
    body: list[str] = []
    in_code = False
    code_lines: list[str] = []
    in_ul = False
    i = 0

    def close_ul() -> None:
        nonlocal in_ul
        if in_ul:
            body.append("</ul>")
            in_ul = False

    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            if not in_code:
                close_ul()
                in_code = True
                code_lines = []
            else:
                body.append(
                    "<pre><code>"
                    + html.escape("\n".join(code_lines))
                    + "</code></pre>"
                )
                in_code = False
            i += 1
            continue

        if in_code:
            code_lines.append(line)
            i += 1
            continue

        if not line.strip():
            close_ul()
            i += 1
            continue

        if line.startswith("#"):
            close_ul()
            level = len(line) - len(line.lstrip("#"))
            heading = parse_inline(line[level:].strip())
            level = min(level, 3)
            body.append(f"<h{level}>{heading}</h{level}>")
            i += 1
            continue

        if (
            line.startswith("|")
            and i + 1 < len(lines)
            and lines[i + 1].startswith("|")
            and not set(lines[i + 1].replace("|", "").replace(":", "").replace("-", "").strip())
        ):
            close_ul()
            headers = [cell.strip() for cell in line.strip("|").split("|")]
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([cell.strip() for cell in lines[i].strip("|").split("|")])
                i += 1

            body.append(
                "<table><thead><tr>"
                + "".join(f"<th>{parse_inline(header)}</th>" for header in headers)
                + "</tr></thead><tbody>"
            )
            for row in rows:
                body.append(
                    "<tr>"
                    + "".join(f"<td>{parse_inline(cell)}</td>" for cell in row)
                    + "</tr>"
                )
            body.append("</tbody></table>")
            continue

        if line.startswith("- "):
            if not in_ul:
                body.append("<ul>")
                in_ul = True
            body.append(f"<li>{parse_inline(line[2:].strip())}</li>")
            i += 1
            continue

        close_ul()
        body.append(f"<p>{parse_inline(line.strip())}</p>")
        i += 1

    close_ul()
    return "\n".join(body)


def main() -> None:
    md_path = Path("test_execution_report.md")
    out_path = Path("test_execution_report.html")
    html_body = markdown_to_html(md_path.read_text(encoding="utf-8"))
    html_doc = f"""<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<title>EnsembleSync 테스트 실행 및 수정 기록</title>
<style>
@page {{ size: A4; margin: 14mm; }}
* {{ box-sizing: border-box; }}
body {{
  font-family: "Malgun Gothic", "Apple SD Gothic Neo", Arial, sans-serif;
  color: #111827;
  line-height: 1.58;
  font-size: 12.5px;
}}
h1 {{
  font-size: 25px;
  border-bottom: 3px solid #6d28d9;
  padding-bottom: 10px;
  margin: 0 0 18px;
}}
h2 {{
  font-size: 18px;
  margin: 26px 0 10px;
  border-bottom: 1px solid #d1d5db;
  padding-bottom: 5px;
  page-break-after: avoid;
}}
h3 {{
  font-size: 15px;
  margin: 18px 0 8px;
  page-break-after: avoid;
}}
p {{ margin: 6px 0; }}
table {{
  width: 100%;
  border-collapse: collapse;
  margin: 10px 0 16px;
  page-break-inside: auto;
}}
tr {{ page-break-inside: avoid; page-break-after: auto; }}
th, td {{
  border: 1px solid #d1d5db;
  padding: 7px 8px;
  vertical-align: top;
}}
th {{ background: #f3f4f6; font-weight: 700; }}
code {{
  font-family: Consolas, "Courier New", monospace;
  background: #f3f4f6;
  padding: 1px 4px;
  border-radius: 3px;
}}
pre {{
  background: #111827;
  color: #f9fafb;
  padding: 10px 12px;
  border-radius: 6px;
  overflow-wrap: anywhere;
  white-space: pre-wrap;
  page-break-inside: avoid;
}}
pre code {{ background: transparent; color: inherit; padding: 0; }}
ul {{ margin: 6px 0 12px 20px; padding: 0; }}
li {{ margin: 3px 0; }}
</style>
</head>
<body>
{html_body}
</body>
</html>
"""
    out_path.write_text(html_doc, encoding="utf-8")
    print(out_path.resolve())


if __name__ == "__main__":
    main()
