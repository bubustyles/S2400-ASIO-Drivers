"""Baut das Handbuch: setzt Bilder/Platzhalter ein und druckt mit Edge als PDF.

Aufruf (im Ordner Handbuch):  python -I build_handbuch.py 1.5.3
Bilder liegen in img/<name>.png. Fehlt eines, erscheint ein Platzhalter.
"""
import datetime
import pathlib
import re
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"


def build(lang, version):
    src = (HERE / f'handbuch_{lang}.html').read_text(encoding='utf-8')
    missing = []

    def fig(m):
        name, cap = m.group(1).strip(), m.group(2).strip()
        img = HERE / 'img' / f'{name}.png'
        if img.exists():
            body = f'<img src="img/{name}.png" alt="">'
        else:
            missing.append(name)
            body = f'<div class="ph">Bild folgt: <code>img/{name}.png</code></div>'
        return f'<figure>{body}<figcaption>{cap}</figcaption></figure>'

    out = re.sub(r'\{\{IMG\s+([^|}]+)\|([^}]*)\}\}', fig, src)
    out = out.replace('{{VERSION}}', version)
    fmt = '%d.%m.%Y' if lang == 'de' else '%Y-%m-%d'
    out = out.replace('{{DATUM}}', datetime.date.today().strftime(fmt))
    tmp = HERE / f'_build_{lang}.html'
    tmp.write_text(out, encoding='utf-8')
    name = 'Software-Handbuch' if lang == 'de' else 'Software-Manual'
    pdf = HERE / f'S2400_ASIO_Drivers_{name}_{lang.upper()}_{version}.pdf'
    profile = pathlib.Path(tempfile.gettempdir()) / 's2400_edge_pdf'
    if pdf.exists():
        pdf.unlink()  # sonst gilt ein altes PDF als fertig
    subprocess.run([EDGE, '--headless=new', '--disable-gpu', '--no-pdf-header-footer',
                    f'--user-data-dir={profile}', f'--print-to-pdf={pdf}', tmp.as_uri()],
                   check=True, timeout=120)
    for _ in range(50):
        if pdf.exists():
            break
        time.sleep(0.2)
    tmp.unlink()
    print(pdf.name, 'fehlende Bilder:', ', '.join(missing) or 'keine')


if __name__ == '__main__':
    for lang in ('de', 'en'):
        build(lang, sys.argv[1] if len(sys.argv) > 1 else '0.0')
