FROM python:3.12-alpine
WORKDIR /app
# poppler-utils supplies pdftoppm, which the shim shells out to when it has to
# rasterize a PDF for a model that refuses a file part (RASTERIZE_PDF_MODELS;
# see server.py). apk, not a pip wheel: this base is musl and pypdfium2 ships
# manylinux wheels only, so pip would try to build pdfium from source.
#
# THE FONT PACKAGES ARE NOT OPTIONAL, AND LEAVING THEM OUT FAILS SILENTLY.
# A PDF that names a font instead of embedding it -- many invoicing tools
# name Arial -- renders with EVERY GLYPH MISSING when poppler has
# no font to substitute. Not an error, not a blank page: rules, logos, barcodes
# and shaded boxes all draw correctly and only the text disappears, so the
# result looks like a redacted document. pdftoppm says `Syntax Error: Couldn't
# find a font for 'Arial,Italic'` on stderr and exits 0.
#
# It once cost a full 106-document benchmark run. The model reported
# "all text fields render as redacted gray boxes" and that was an accurate
# description of what the gateway had sent it.
#
# ttf-liberation is the one that matters: it is metric-compatible with Arial,
# Times New Roman and Courier New, so substitution keeps the original layout.
# ttf-dejavu covers the rest, including the Slovak diacritics. The `fc-list`
# test at the end refuses to ship a shim that would rasterize an Arial PDF
# blank.
RUN apk add --no-cache poppler-utils ttf-liberation ttf-dejavu fontconfig \
 && pip install --no-cache-dir aiohttp==3.10.10 \
 && pdftoppm -v \
 && test "$(fc-list | wc -l)" -gt 0
COPY server.py /app/server.py
EXPOSE 4001
ENV PYTHONUNBUFFERED=1
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://127.0.0.1:4001/_shim_health >/dev/null || exit 1
CMD ["python", "/app/server.py"]
