#!/usr/bin/env bash
# tools.sh: the tools that more than one CI script installs, each with its version and the SHA-256 value of its download. Source it, do not
# run it:
#
#   . ci/tools.sh
#   install_cosign     # cosign, which signs the release and the token proxy image
#   install_crane      # crane, which reads, tags and joins registry manifests without a Docker daemon
#   ... | signed_only_on REF   # the signing certificate of every Sigstore bundle on stdin names REF (below)
#
# They go to ${CI_TOOLS_BIN} (default ${RELEASE_BIN}, else ~/.local/bin), which the caller puts on PATH. A Renovate pull request changes
# a version only: put the new SHA-256 value next to it (docs/ci.md, "Pinned versions"). x86_64 Linux only, which every job that publishes is.

tools_bin="${CI_TOOLS_BIN:-${RELEASE_BIN:-${HOME}/.local/bin}}"

# fetch URL SHA256 FILE: download, and check the SHA-256 value
fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet -
}

tools_check_platform() {
  [ "$(uname -m)" = x86_64 ] || { printf 'error: the tools install on x86_64 Linux only\n' >&2; return 1; }
  mkdir -p "${tools_bin}"
}

install_cosign() {
  tools_check_platform || return 1
  # renovate: datasource=github-releases depName=sigstore/cosign extractVersion=^v(?<version>.*)$
  local cosign_version=3.1.3
  local cosign_sha256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
  local tmp; tmp="$(mktemp -d)"
  fetch "https://github.com/sigstore/cosign/releases/download/v${cosign_version}/cosign-linux-amd64" "${cosign_sha256}" "${tmp}/cosign"
  install -m 0755 "${tmp}/cosign" "${tools_bin}/cosign"
  rm -rf "${tmp}"
}

install_crane() {
  tools_check_platform || return 1
  # renovate: datasource=github-releases depName=google/go-containerregistry extractVersion=^v(?<version>.*)$
  local crane_version=0.22.1
  local crane_sha256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
  local tmp; tmp="$(mktemp -d)"
  fetch "https://github.com/google/go-containerregistry/releases/download/v${crane_version}/go-containerregistry_Linux_x86_64.tar.gz" \
    "${crane_sha256}" "${tmp}/crane.tar.gz"
  tar -xzf "${tmp}/crane.tar.gz" -C "${tmp}" crane
  install -m 0755 "${tmp}/crane" "${tools_bin}/crane"
  rm -rf "${tmp}"
}

# require_credentials: succeeds when the pipeline must publish. The setup gate sets REQUIRE_CREDENTIALS=true for main with both e2e tokens, the
# production project (docs/ci.md, "Publishing fails closed on main"): there a missing credential fails the job. Anywhere else, and in a project
# without the e2e context, the publication is skipped with a message and the pipeline stays green.
require_credentials() { case "${REQUIRE_CREDENTIALS:-}" in 1 | true) return 0 ;; *) return 1 ;; esac; }

# --- the ref of a signature ---------------------------------------------------------------------------------------------------------------
# The identity of a keyless signature (the pipeline definition of this project) is the same for every branch, and a job of any branch can get
# an OIDC token without a context. What tells a signature of main from the signature of a feature branch is the extension
# source-repository-ref (OID 1.3.6.1.4.1.57264.1.14) of the certificate: Fulcio fills it from the claim oidc.circleci.com/vcs-ref of the token,
# for example refs/heads/main. cosign has a flag for the GitHub extensions only, so the certificate is read here, with jq, base64 and od.
# The same check, by hand, is in docs/releasing.md ("How the signature works").

# der_len N: the DER length octets of a string of N bytes, as hex digits
der_len() {
  if [ "$1" -lt 128 ]; then printf '%02x' "$1"; elif [ "$1" -lt 256 ]; then printf '81%02x' "$1"; else printf '82%04x' "$1"; fi
}

# ref_pattern REF: an extended regular expression for the hex dump of a certificate that holds the extension with exactly the value REF:
# the OID, an OCTET STRING with the exact length, a UTF8String (0c) or a PrintableString (13) with the exact length, then REF. The lengths
# make it an equality, not a prefix or a suffix.
ref_pattern() {
  local n len
  n=$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')
  len=$(der_len "${n}")
  printf '2b0601040183bf30010e04%s(0c|13)%s%s' "$(der_len $((1 + ${#len} / 2 + n)))" "${len}" "$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
}

# signed_only_on REF < bundles: succeeds when the stdin holds at least one Sigstore bundle with a signing certificate and EVERY such
# certificate has the extension source-repository-ref equal to REF. Bundles come from `cosign verify-blob --bundle FILE` (one) or from
# `cosign download signature IMAGE` (every signature of an image). All of them must be of REF, not one of them: a signature that cosign
# verifies could be another one than the one that carries REF, and a stray signature from a feature branch must not pass because a
# signature of main sits next to it. Run cosign verify first: this checks the ref, not the signature.
signed_only_on() {
  local pattern certs b64 n=0
  pattern=$(ref_pattern "$1")
  certs=$(jq -r '.verificationMaterial | ((.certificate // .x509CertificateChain.certificates[0]) // {}) | .rawBytes // empty') || return 1
  while IFS= read -r b64; do
    [ -n "${b64}" ] || continue
    n=$((n + 1))
    printf '%s' "${b64}" | base64 -d 2> /dev/null | od -An -v -tx1 | tr -d ' \n' | grep -Eq "${pattern}" || return 1
  done <<< "${certs}"
  [ "${n}" -gt 0 ]
}
