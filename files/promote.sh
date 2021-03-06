#!/bin/bash -xe

if [ -z "$1" ]; then
    echo "Please give me a hash to point at!"
    exit 1
fi

if [ -z "$2" ]; then
    echo "Please specify the delorean instance to use!"
    exit 1
fi

cd /home/${2}/data/repos

# verify uniqueness
a="$(find . -maxdepth 3 -mindepth 3 -type d -name \*${1}\* | wc -l)"
if [ "$a" != "1" ]; then
    echo "Uniqueness must be enforced!"
    exit 1
fi

ln -nsvf */*/*${1}* current-passed-ci
echo "$1" >> promote.log
