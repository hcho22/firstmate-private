#!/bin/sh
printf '%s\n' '> Validate the change through no-mistakes' '' \
  '  Bash(no-mistakes axi run --intent-file .fm/intent.md)' \
  '  waiting synchronously on the validation run ...' ''
exec sleep 7200
