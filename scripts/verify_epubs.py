"""Validate downloaded books against expectations recorded by browser tests."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile, ZIP_STORED

folder = Path(sys.argv[1] if len(sys.argv) > 1 else "smoke-artifacts")
expectations = json.loads((folder / "epub-expectations.json").read_text())
assert expectations, "No expected browser downloads were recorded"
for expected in expectations:
    file = folder / expected["filename"]
    with ZipFile(file) as archive:
        names = archive.namelist()
        assert names[0] == "mimetype", (file.name, names[:3])
        assert archive.getinfo("mimetype").compress_type == ZIP_STORED
        assert archive.read("mimetype") == b"application/epub+zip"
        for name in names:
            if name.endswith((".xhtml", ".opf", ".xml", ".ncx")):
                ET.fromstring(archive.read(name))
        package = ET.fromstring(archive.read("OEBPS/content.opf"))
        ns = {"opf": "http://www.idpf.org/2007/opf",
              "dc": "http://purl.org/dc/elements/1.1/"}
        language = package.findtext("opf:metadata/dc:language", namespaces=ns)
        assert language == expected["language"], (file.name, language)
        spine = package.findall("opf:spine/opf:itemref", ns)
        assert len(spine) == expected["chapters"], (file.name, len(spine))
        identifier = package.findtext("opf:metadata/dc:identifier", namespaces=ns)
        assert identifier.startswith("urn:uuid:"), identifier
        chapter_files = [n for n in names if n.startswith("OEBPS/c") and n.endswith(".xhtml")]
        combined = "\n".join(archive.read(n).decode("utf-8") for n in chapter_files)
        for phrase in expected.get("contains", []):
            assert phrase in combined, (file.name, "Missing expected text", phrase)
        print(f"PASS {file.name}: {len(spine)} sections, {language}, {file.stat().st_size} bytes")
