#!/bin/sh
# Offline thumbnail transport: exact curl stdout/status and bounded fixture IO.
set -eu
for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  eval "value=\${$key-}"
  if [ -n "$value" ]; then echo "inherited proxy: $key" >&2; exit 90; fi
done
output= proxy= bypass= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2;;
    --proxy) proxy=$2; shift 2;;
    --noproxy) bypass=$2; shift 2;;
    --max-time|--connect-timeout|--write-out) shift 2;;
    -*) shift;;
    *) url=$1; shift;;
  esac
done
printf '%s|proxy=%s|bypass=%s\n' "$url" "$proxy" "$bypass" >> "$YOUTUBE_IMAGE_TRACE"
case "$url" in
  */hq720_custom_1.jpg) printf '404'; echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22;;
  */hqdefault.jpg) cp "$YOUTUBE_IMAGE_FIXTURE" "$output"; printf '200';;
  *) printf '403'; echo 'curl: (22) The requested URL returned error: 403' >&2; exit 22;;
esac
