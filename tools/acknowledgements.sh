#!/bin/zsh
# Writes Resources/Acknowledgements.txt: the license of every package Quarry
# is built with (from the resolved checkouts), and Sequel Pro's, whose file
# formats and behavior Quarry follows. About Quarry > Acknowledgements shows it.
# Run after changing dependencies:  tools/acknowledgements.sh
set -euo pipefail
here=${0:A:h:h}
checkouts=${QUARRY_CHECKOUTS:-$HOME/Library/Developer/Quarry/test-build/checkouts}
[[ -d $checkouts ]] || checkouts=$here/.build/checkouts
out=$here/Resources/Acknowledgements.txt
{
  print "Quarry is built with these open-source packages. Their licenses follow.\n"
  print "================================================================"
  print "Sequel Pro (https://github.com/sequelpro/sequelpro)"
  print "Quarry is an updated rebuild of Sequel Pro and reads and writes its connection files."
  print "================================================================\n"
  cat $here/../sequelpro/LICENSE
  for dir in $checkouts/*(/N); do
    license=$(find $dir -maxdepth 1 -iname 'licen[cs]e*' | sort | head -1)
    [[ -n $license ]] || continue
    print "\n================================================================"
    print "${dir:t}"
    print "================================================================\n"
    cat $license
  done
} > $out
print "wrote $out"
