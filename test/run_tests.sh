#!/bin/sh
podman build --tag run_ruby_tests_image .

podman run \
  --rm \
  --log-driver=none \
  --tmpfs /tmp:rw,size=512m,mode=1777 \
  -v "$(pwd)/../":/documents/:Z \
  run_ruby_tests_image \
  sh -c 'ruby test/test_*.rb'
