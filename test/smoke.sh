#!/bin/sh
# Smoke test a built image: start it, then send a book through each conversion as an
# e-reader would and check the result.
#
#   test/smoke.sh <image> <kindlegen expected: true|false>
#
# Needs docker, curl and python3 on the host.
set -eu

image=$1
want_kindlegen=$2
name=send2ereader-smoke
port=3001
base=http://127.0.0.1:$port
work=$(mktemp -d)
kobo='Mozilla/5.0 (Linux; U; Android 2.0; en-us;) AppleWebKit/538.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/538.1 (Kobo Touch 0377/4.20.14622)'
kindle='Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+'

cleanup() {
  if [ "$1" != 0 ]; then
    echo "--- container log"
    docker logs "$name" 2>&1 || true
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap 'cleanup $?' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A minimal EPUB, and a one-page PDF made with the image's own PyMuPDF
python3 - "$work/book.epub" <<'EOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip')
z.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
z.writestr('OEBPS/content.opf', '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Smoke test</dc:title><dc:language>en</dc:language><dc:identifier id="id">smoke-test</dc:identifier></metadata><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="c1"/></spine></package>')
z.writestr('OEBPS/toc.ncx', '<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="smoke-test"/></head><docTitle><text>Smoke test</text></docTitle><navMap><navPoint id="n1" playOrder="1"><navLabel><text>One</text></navLabel><content src="c1.xhtml"/></navPoint></navMap></ncx>')
z.writestr('OEBPS/c1.xhtml', '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body><p>Hello from the smoke test.</p></body></html>')
z.close()
EOF
docker run --rm "$image" /opt/pdfcropmargins/bin/python -c '
import sys, pymupdf
d = pymupdf.open(); d.new_page().insert_text((200, 400), "smoke test"); sys.stdout.buffer.write(d.tobytes())
' > "$work/doc.pdf"

docker run -d --name "$name" -p "$port:3001" "$image" >/dev/null
for i in $(seq 1 30); do
  curl -sf "$base/tools" >/dev/null 2>&1 && break
  [ "$i" = 30 ] && fail "the app did not answer within 30 seconds"
  sleep 1
done

tools=$(curl -sf "$base/tools")
echo "tools: $tools"
expected="{\"kepubify\":true,\"kindlegen\":$want_kindlegen,\"pdfcropmargins\":true}"
[ "$tools" = "$expected" ] || fail "expected $expected"

# send <agent> <file> <option>: generate a key as the reader, upload as a browser.
# Prints the upload's answer, then the file name the reader is offered.
send() {
  key=$(curl -sf -X POST -A "$1" "$base/generate")
  answer=$(curl -s -w ' [%{http_code}]' -F "key=$key" -F "file=@$work/$2" -F "$3=on" "$base/upload")
  offered=$(curl -sf -A "$1" "$base/status/$key")
  echo "$answer"
  echo "$offered"
}

expect() {
  label=$1; out=$2; want=$3
  echo "$label: $(echo "$out" | head -1)"
  case "$out" in
    *"$want"*) ;;
    *) fail "$label: expected '$want' in: $out" ;;
  esac
}

out=$(send "$kobo" book.epub kepubify)
expect "kobo + kepubify" "$out" '"name":"book.kepub.epub"'
expect "kobo + kepubify" "$out" "converted with kepubify"

out=$(send "$kindle" book.epub kindlegen)
if [ "$want_kindlegen" = true ]; then
  expect "kindle + kindlegen" "$out" '"name":"book.mobi"'
else
  # No kindlegen here: the EPUB is sent as it is rather than failing
  expect "kindle, no kindlegen" "$out" '"name":"book.epub"'
fi
expect "kindle" "$out" "[200]"

out=$(send "$kobo" doc.pdf pdfcropmargins)
expect "pdf + pdfcropmargins" "$out" '"name":"doc.pdf"'
expect "pdf + pdfcropmargins" "$out" "[200]"

echo "PASS"
