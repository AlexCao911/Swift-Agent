#!/usr/bin/env bash

native_source_record() {
    local source_name="$1"
    local lock_file="$2"
    local record

    record="$(/usr/bin/awk -F'|' -v name="$source_name" '$1 == name { print; exit }' "$lock_file")"
    if [[ -z "$record" ]]; then
        echo "native.source_not_locked: $source_name" >&2
        return 1
    fi
    printf '%s\n' "$record"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "native.source_digest_mismatch: $file" >&2
        return 1
    fi
}

native_job_count() {
    local count
    count="$(/usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
        echo "$count"
    else
        echo 4
    fi
}

download_locked_source() {
    local source_name="$1"
    local lock_file="$2"
    local destination="$3"
    local record locked_name version url digest

    record="$(native_source_record "$source_name" "$lock_file")"
    IFS='|' read -r locked_name version url digest <<< "$record"
    if [[ "$locked_name" != "$source_name" || -z "$url" || -z "$digest" ]]; then
        echo "native.source_lock_invalid: $source_name" >&2
        return 1
    fi

    local partial="$destination.partial"

    /bin/mkdir -p "$(/usr/bin/dirname "$destination")"
    if [[ -f "$destination" ]] && verify_sha256 "$destination" "$digest" 2>/dev/null; then
        return
    fi

    /bin/rm -f "$destination" "$partial"
    if ! /usr/bin/curl --fail --location --retry 3 --retry-all-errors \
        "$url" --output "$partial"; then
        /bin/rm -f "$partial"
        return 1
    fi
    verify_sha256 "$partial" "$digest"
    /bin/mv "$partial" "$destination"
}
