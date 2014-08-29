#!/usr/bin/env python
from __future__ import print_function

# Hey Basti,
#
# Hier ist das Skript was ich mal geschrieben habe, um SVGs zu drehen.
# Das kannst du sicher an deinen Anwendungsfall anpassen.

import sys
import re

if len(sys.argv) != 2:
    sys.exit("usage: {0} source.svg > destination.svg".format(sys.argv[0]))

# zerschneiden
segments = [[]]
bars = []
def parse(handle):
    for line in handle:
        if '94%,94%,94%' in line:
            bars.append(line)
            continue
# graue Trackbeschriftung
        if line.startswith('<g style="fill:rgb(70%,70%,70%)') or line.startswith('<g id='):
            segments.append([])
            #sys.stderr.write('{0} paths in a row\n'.format(run))

        segments[-1].append(line)

parse(open(sys.argv[1]))
sys.stderr.write('segments: {0}\n'.format(len(segments)))
for s in segments:
    sys.stderr.write('- {0}\n'.format(len(s)))

a = []
a.insert(0, segments[-1].pop(-1))
a.insert(0, segments[-1].pop(-1))
segments.append(a)

# SVG einlesen
doc = open(sys.argv[1]).read()
# regulaere Ausdruecke! 
first_y_re = re.compile(r'y="(\d+\.\d+)"')
svg_re = re.compile(r'<svg[^>]*>')
height_re = re.compile(r'height="(\d+)pt"')
width_re = re.compile(r'width="(\d+)pt"')

h = int(height_re.search(doc).group(1))
w = int(width_re.search(doc).group(1))

blue_top = float(first_y_re.search(''.join(segments[4])).group(1))
blue_height = h - blue_top

# Wichtig ist, die Dimensionen anzupassen:
svg = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{1}pt" height="{0}pt" viewBox="0 0 {1} {0}" version="1.1">'.format(w, h)

# ausgabe
print(svg_re.sub(svg, ''.join(segments[0])))
# Hier drehe ich den Inhalt:
print('<g transform="translate({0}, 0)"><g transform="rotate(90, 0, 0)">'.format(h))
print('{4}<g transform="translate(0, {3})">{0}{1}{2}'.format(
    ''.join(segments[1]),
    ''.join(segments[2]),
    ''.join(segments[3]),
    blue_height,
    ''.join(bars)))
print('</g></g><g transform="translate(0, {2})"><g transform="scale(1,-1)"><g transform="translate(0, {1})">{0}</g></g></g></g>'.format(
    ''.join(segments[4]),
    -blue_top,
    blue_height))
print('{0}'.format(''.join(segments[5])))

# Ich hoffe das hilft dir weiter. Lieben Gruss, Justus