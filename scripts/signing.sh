# Sourced by build.sh / test.sh. Chooses how to sign:
#   - Developer ID Application for team 3A3L2C6DFB when that identity is in the keychain
#     (the maintainer's release builds), or
#   - ad-hoc ("-") otherwise: anyone can build and run ComfyBar from source without an
#     Apple Developer account. Force either with SIGN=devid or SIGN=adhoc.
TEAM_ID="${TEAM_ID:-3A3L2C6DFB}"
if [ -z "${SIGN:-}" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: .*(${TEAM_ID})"; then
    SIGN=devid
  else
    SIGN=adhoc
  fi
fi
SIGN_ARGS=()
if [ "$SIGN" = adhoc ]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=)
fi
