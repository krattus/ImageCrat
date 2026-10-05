#!/bin/zsh
# Fails if app code plays the alert sound directly. Every beep must go through `Beep.play()`
# (Sources/Lumen/App/Beep.swift), which is silent in self tests, perf tests, menu fuzzing and droplet/script runs.
# String literals and // comments are ignored, so docs and the beep self test may name the forbidden calls.
cd "$(dirname "$0")/.." || exit 2
hits=$(find Sources/Lumen -name '*.swift' ! -path 'Sources/Lumen/App/Beep.swift' -print0 | xargs -0 perl -ne '
  my $l = $_; $l =~ s/"(?:\\.|[^"\\])*"//g; $l =~ s{//.*$}{};
  print "$ARGV:$.: $_" if $l =~ /\bNSSound\s*\.\s*beep\s*\(|\bNSBeep\s*\(/;
  close ARGV if eof;')
if [ -n "$hits" ]; then
  echo "check_no_raw_beep: raw beeps found; use Beep.play() instead:"
  echo "$hits"
  exit 1
fi
echo "check_no_raw_beep: OK"
