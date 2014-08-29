#!/bin/bash

rm new_*
for file in *.svg ; do
	python pix.py $file > new_$file
done