#!/usr/bin/env bash
# Fake `tailcat` used by backend unit tests. Mimics the real CLI's
# machine-readable surface (version/parse/genkey/printpub/ping/serve) closely
# enough to exercise our adapter's argv building and output parsing.
#
# The real binary's `tailcat parse` rejects tokens that aren't valid; here we
# use the prefix scheme tcGOOD.../tcEMBED.../tcBAD... to drive those cases.

set -u
FAKE_KEYS_DIR="${FAKE_KEYS_DIR:-/tmp/fake-tailcat-keys}"

sub=""
for a in "$@"; do
  case "$a" in
    version|parse|genkey|printpub|ping|serve|resolve|socks|recv|ls|ssh|cp)
      sub="$a"; break ;;
  esac
done

case "$sub" in
  version)
    echo "v0.1.0"
    ;;
  parse)
    tok=""
    for a in "$@"; do
      [[ "$a" != tc* ]] || tok="$a"
    done
    if [[ -z "$tok" ]]; then
      echo "parse: no address blob argument" >&2
      exit 1
    fi
    case "$tok" in
      tcEMBED*)
        echo '{"ServerPublic":"nodekey:aaaabbbbccccddddeeeeffff000011112222333344445555666677778888","ServerDiscoPublic":"AAAA","Region":[{"RegionID":302,"RegionCode":"sfo","RegionName":"San Francisco"}]}'
        ;;
      tcGOOD*)
        echo '{"ServerPublic":"nodekey:aaaabbbbccccddddeeeeffff000011112222333344445555666677778888","RegionID":302}'
        ;;
      *)
        echo "parse: invalid address blob" >&2
        exit 1
        ;;
    esac
    ;;
  genkey)
    keyname=""; client=0; delete=0; list=0
    for a in "$@"; do
      case "$a" in
        --key=*) keyname="${a#--key=}" ;;
        --client) client=1 ;;
        --delete) delete=1 ;;
        --list) list=1 ;;
      esac
    done
    if [[ "$list" == "1" ]]; then
      echo "default"
      echo "client-default"
      exit 0
    fi
    if [[ -z "$keyname" ]]; then
      echo "genkey requires a --key=<name>" >&2
      exit 1
    fi
    if [[ "$delete" == "1" ]]; then
      if [[ -e "$FAKE_KEYS_DIR/$keyname.private.json" ]]; then
        rm "$FAKE_KEYS_DIR/$keyname.private.json"
        exit 0
      fi
      echo "genkey: remove $FAKE_KEYS_DIR/$keyname.private.json: no such file or directory" >&2
      exit 1
    fi
    if [[ -e "$FAKE_KEYS_DIR/$keyname.private.json" ]]; then
      echo "genkey: $FAKE_KEYS_DIR/$keyname.private.json already exists; use --force to overwrite" >&2
      exit 1
    fi
    mkdir -p "$FAKE_KEYS_DIR"
    printf '{}' > "$FAKE_KEYS_DIR/$keyname.private.json"
    if [[ "$client" == "1" ]]; then
      echo "# wrote file to $FAKE_KEYS_DIR/$keyname.private.json" >&2
      echo "nodekey:clientpubkey000000000000000000000000000000000000000000000000"
    else
      echo "# wrote file to $FAKE_KEYS_DIR/$keyname.private.json" >&2
      printf 'tcGOOD%s%s\n' "$keyname" "$(printf 'X%.0s' {1..40})"
    fi
    ;;
  printpub)
    echo "nodekey:clientpubkey000000000000000000000000000000000000000000000000"
    ;;
  ping)
    until_direct=0; tok=""
    for a in "$@"; do
      case "$a" in
        --until-direct) until_direct=1 ;;
        --timeout=*) : ;;
        tc*|*.test|*.example.com) tok="$a" ;;
      esac
    done
    if [[ "$tok" == tcBAD* ]]; then
      echo "ping: invalid address blob" >&2
      exit 1
    fi
    if [[ "$until_direct" == "1" ]]; then
      echo "pong in 42.1ms via DERP(sfo)"
      echo "pong in 1.2ms via 203.0.113.7:41641"
    else
      echo "pong in 38.0ms via DERP(sfo)"
    fi
    ;;
  serve)
    key="new"
    for a in "$@"; do
      case "$a" in
        --key=*) key="${a#--key=}" ;;
      esac
    done
    addrfile="${TAILCAT_ADDR_FILE:-}"
    tok="tcGOOD$(printf 'S%.0s' {1..60})"
    if [[ -n "$addrfile" ]]; then
      printf '%s' "$tok" > "$addrfile"
    fi
    echo "# Selected bootstrap relay region 302, San Francisco" >&2
    if [[ "$key" == "new" ]]; then
      echo "# 🐈 Server listening with new address: $tok" >&2
    else
      echo "# 🐈 Server listening with saved key \"$key\": $tok" >&2
    fi
    # Block like a real server until signalled.
    while true; do sleep 5; done
    ;;
  *)
    echo "fake-tailcat: unknown subcommand" >&2
    exit 1
    ;;
esac
exit 0
