import re
import sys
from pathlib import Path
import pdfplumber

INPUT_PDF = Path(sys.argv[1])
OUTPUT_DIR = Path(sys.argv[2])
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

HEADER_PATTERN = re.compile(
    r'^(?P<title>[A-Z][A-Za-z\-]+(?:\s+[A-Za-z\-]+)*)'      # Arabischer Titel
    r'(?:\s*-\s*|\s+)'                                     # optionaler Bindestrich
    r'(?P<eng>[A-Za-z][A-Za-z\s,\-]+)\n'                    # Englischer Titel
    r'Chapter\s+(?P<num>\d+)\s+'                            # Kapitelnummer
    r'(?P=title)\s+'                                        # exakt gleicher Titel
    r'(?P<verses>\d+)\s+verses,\s+'                         # Versanzahl
    r'(?P<place>Mecca|Medina|Madina)',                      # Offenbarungsort
    re.MULTILINE
)

SANITIZE_PATTERN = re.compile(r'[^A-Za-z0-9\-]+')

def extract_text(pdf_path: Path) -> str:
    chunks = []
    append = chunks.append
    with pdfplumber.open(pdf_path) as pdf:
        for page in pdf.pages:
            text = page.extract_text()
            if text:
                append(text)
    return "\n".join(chunks)

def main():
    full_text = extract_text(INPUT_PDF)

    matches = list(HEADER_PATTERN.finditer(full_text))
    if not matches:
        return

    for i, match in enumerate(matches):
        start = match.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(full_text)

        section_text = full_text[start:end].strip()

        safe_title = f"{match.group('num')}_{match.group('title')}"
        safe_title = SANITIZE_PATTERN.sub("_", safe_title).strip("_")

        output_path = OUTPUT_DIR / f"{safe_title}.txt"
        with open(output_path, "w", encoding="utf-8", buffering=1024 * 1024) as f:
            f.write(section_text)

if __name__ == "__main__":
    main()