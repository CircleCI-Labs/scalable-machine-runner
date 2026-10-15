#!/usr/bin/env bash
# signature-ref.sh test: signed_only_on of ci/tools.sh, the check that the signing certificate of a keyless signature names a ref (the extension
# source-repository-ref, OID 1.3.6.1.4.1.57264.1.14). A table of certificates that openssl makes with that extension (UTF8String and PrintableString,
# as Fulcio may write it), put into Sigstore bundles of both shapes. Needs bash, openssl, jq, base64 and od; no network, no secret.
#
# The rows that matter most: refs/heads/main passes for main only; a ref that merely starts or ends with it does not; one signature of a feature
# branch next to a signature of main fails; no certificate, no extension and invalid JSON fail.
#
# Usage: ci/tests/signature-ref.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=ci/tools.sh
. "${here}/../tools.sh"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failed=0
rows=0
long_ref="refs/heads/$(printf 'x%.0s' $(seq 1 130))"

# cert NAME EXTENSION_VALUE_ARGS...: a self-signed certificate. Prints the base64 of its DER. No arguments after the name: no extension.
openssl ecparam -name prime256v1 -genkey -noout -out "${work}/key.pem" 2> /dev/null
cert() {
  local name=$1; shift
  local -a ext=()
  [ "$#" -eq 0 ] || ext=(-addext "1.3.6.1.4.1.57264.1.14=$1")
  openssl req -x509 -new -key "${work}/key.pem" -days 1 -subj "/CN=${name}" "${ext[@]}" -outform DER -out "${work}/${name}.der" 2> /dev/null
  base64 -w0 < "${work}/${name}.der"
}
# bundle CERT: a Sigstore bundle of the shape of cosign 3 (a single certificate), and chain CERT: the older shape
bundle() { jq -nc --arg c "$1" '{mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json", verificationMaterial: {certificate: {rawBytes: $c}}}'; }
chain() { jq -nc --arg c "$1" '{mediaType: "application/vnd.dev.sigstore.bundle+json;version=0.2", verificationMaterial: {x509CertificateChain: {certificates: [{rawBytes: $c}]}}}'; }

main_utf8=$(cert main_utf8 "ASN1:UTF8String:refs/heads/main")
main_printable=$(cert main_printable "ASN1:PRINTABLESTRING:refs/heads/main")
feature=$(cert feature "ASN1:UTF8String:refs/heads/feature/x")
longer=$(cert longer "ASN1:UTF8String:refs/heads/main2")
prefixed=$(cert prefixed "ASN1:UTF8String:refs/heads/x/refs/heads/main")
tag_ref=$(cert tag_ref "ASN1:UTF8String:refs/tags/v1.0.0")
long=$(cert long "ASN1:UTF8String:${long_ref}")
none=$(cert none)

# expect NAME WANT REF  (the bundles are on stdin)
expect() {
  local name=$1 want=$2 ref=$3 got=fail
  rows=$((rows + 1))
  if signed_only_on "${ref}" 2> /dev/null; then got=pass; fi
  if [ "${got}" = "${want}" ]; then
    echo "ok   ${name}: ${got}"
  else
    echo "FAIL ${name}: ${got}, want ${want}"
    failed=$((failed + 1))
  fi
}

expect "main, UTF8String"                  pass refs/heads/main < <(bundle "${main_utf8}")
expect "main, PrintableString"             pass refs/heads/main < <(bundle "${main_printable}")
expect "main, the chain shape of a bundle" pass refs/heads/main < <(chain "${main_utf8}")
expect "a feature branch, main wanted"     fail refs/heads/main < <(bundle "${feature}")
expect "a feature branch, itself wanted"   pass refs/heads/feature/x < <(bundle "${feature}")
expect "main, the feature branch wanted"   fail refs/heads/feature/x < <(bundle "${main_utf8}")
expect "main2 is not main"                 fail refs/heads/main < <(bundle "${longer}")
expect "main is not main2"                 fail refs/heads/main2 < <(bundle "${main_utf8}")
expect "a ref that ends with main"         fail refs/heads/main < <(bundle "${prefixed}")
expect "a tag"                             fail refs/heads/main < <(bundle "${tag_ref}")
expect "a ref of 130+ characters"          pass "${long_ref}" < <(bundle "${long}")
expect "a ref of 130+ characters is not main" fail refs/heads/main < <(bundle "${long}")
expect "no extension"                      fail refs/heads/main < <(bundle "${none}")
expect "two signatures of main"            pass refs/heads/main < <(bundle "${main_utf8}"; bundle "${main_printable}")
expect "main, then a feature branch"       fail refs/heads/main < <(bundle "${main_utf8}"; bundle "${feature}")
expect "a feature branch, then main"       fail refs/heads/main < <(bundle "${feature}"; bundle "${main_utf8}")
expect "main, then a bundle that is not JSON" fail refs/heads/main < <(bundle "${main_utf8}"; echo 'not json')
expect "a bundle with a key and no certificate" fail refs/heads/main < <(echo '{"verificationMaterial":{"publicKey":{"hint":"x"}}}')
expect "a certificate that is not base64 of DER" fail refs/heads/main < <(bundle "bm90IGEgY2VydGlmaWNhdGU=")
expect "an empty answer (no signature)"    fail refs/heads/main < /dev/null
expect "the legacy format (Cert as PEM)"   fail refs/heads/main < <(echo '{"Base64Signature":"x","Cert":"-----BEGIN CERTIFICATE-----"}')

# the pattern itself: a length that needs two bytes
[ "$(ref_pattern "${long_ref}" | cut -c1-37)" = '2b0601040183bf30010e048190(0c|13)818d' ] || { echo "FAIL the long form of the DER length"; failed=$((failed + 1)); }
rows=$((rows + 1))

echo "RESULT test=signature-ref rows=${rows} failed=${failed}"
[ "${failed}" -eq 0 ] || exit 1
echo "PASS (the ref of a signing certificate)"
