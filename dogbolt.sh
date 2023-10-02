#! /usr/bin/env bash

# dogbolt client

# upload an executable binary file to dogbolt.org
# and download all decompiled source files to src/

# license: "Public Domain" or "MIT License, Copyright (c) 2023 Milan Hauth"

# issue: https://github.com/decompiler-explorer/decompiler-explorer/issues/130

retry_sleep=30
retry_count=10

write_error_txt=true
#write_error_txt=false

# retry decompilers on timeout
requests_per_decompiler=3

use_decompiler_name_map=true

# map decompiler names to lowercase
declare -A decompiler_name_map
decompiler_name_map[BinaryNinja]=binary-ninja
decompiler_name_map[Boomerang]=boomerang
decompiler_name_map[Ghidra]=ghidra
decompiler_name_map[Hex-Rays]=hex-rays
decompiler_name_map[RecStudio]=recstudio
decompiler_name_map[Reko]=reko
decompiler_name_map[Relyze]=relyze
decompiler_name_map[RetDec]=retdec
decompiler_name_map[Snowman]=snowman

cpp_file_extension=cpp

file_path="$1"

if [ -z "$file_path" ]; then
  echo "usage: $0 file_path"
  exit 1
fi

echo "binary path: $file_path"

# check binary size: limit is 2 MB
file_size=$(stat -c%s "$file_path")
echo "binary size: $file_size"
# $ expr 2 \* 1024 \* 1024
# 2097152
if ((file_size > 2097152)); then
  echo "error: binary is too large. binary must be smaller than 2 MB"
  exit 1
fi

# get hashes of file
# no, the binary id seems to be random
#rhash --bsd --hex --lowercase --all "$file_path"

file_sha256=$(sha256sum "$file_path" | cut -d' ' -f1)

echo "binary hash: sha256:$file_sha256"

# keep a local mapping from binary hash to binary id
# to avoid repeating binary uploads
binary_id_cache_path="$HOME/.cache/dogbolt/binary_id.txt"

# store hashes of successful results
# "successful" means: no timeout
# so the hash is either the file hash of the decompiled source file
# or the file hash of the error.txt file
# to avoid repeating requests to decompilers
result_hash_cache_path="$HOME/.cache/dogbolt/result_hash.txt"

binary_id=""

if [ -e "$binary_id_cache_path" ]; then
  # read cache
  binary_id=$(grep "^sha256:$file_sha256 " "$binary_id_cache_path" | cut -d' ' -f2)
fi

if [ -z "$binary_id" ]; then
  echo uploading binary
  # the "binary id" seems to be a random uuid, not related to the file hashes produced by rhash
  binary_id="$(curl -s -X POST --form "file=@$file_path" https://dogbolt.org/api/binaries/ | jq -r .id)"

  # write cache
  mkdir -p "$(dirname "$binary_id_cache_path")"
  echo "sha256:$file_sha256 $binary_id" >>"$binary_id_cache_path"
fi

echo "binary id: $binary_id"

# get the list of all decompilers
# so we know how many results to expect
echo "fetching decompiler names"
# parse json from html
# TODO is there an api to fetch this json?
# https://dogbolt.org/api/decompilers/ has too many versions
decompilers_json="$(
  curl -s https://dogbolt.org/ |
  grep -F '<script id="decompilers_json" type="application/json">' |
  sed -E 's|^.*<script[^>]+>(.*)</script>.*|\1|'
)"
decompilers_names="$(echo "$decompilers_json" | jq -r 'keys | join("\n")')"
decompilers_count=$(echo "$decompilers_names" | wc -l)
echo "decompiler names:" $decompilers_names

done_decompiler_keys=""

declare -A request_count_by_decompiler_key

# fetch responses
for ((retry_step=0; retry_step<retry_count; retry_step++)); do

  echo fetching results
  status_json="$(curl -s https://dogbolt.org/api/binaries/$binary_id/decompilations/?completed=true)"

  count=$(echo "$status_json" | jq -r .count)

  # note: the results array has no stable order
  # so new items can be inserted into the array
  # so we use $decompiler_key to identify results

  # loop results of this response
  for ((result_id=0; result_id<count; result_id++)); do

    result_json="$(echo "$status_json" | jq -r ".results[$result_id]")"

    decompiler_name=$(echo "$result_json" | jq -r .decompiler.name)
    decompiler_version=$(echo "$result_json" | jq -r .decompiler.version)

    decompiler_key="$decompiler_name-$decompiler_version"
    if [[ " $done_decompiler_keys " =~ " $decompiler_key " ]]; then
      continue
    fi

    output_extension=c
    if [[ "$decompiler_name" == "Snowman" ]]; then
      output_extension=$cpp_file_extension
    fi
    # TODO retdec should produce cpp with "namespace main { ... }"
    # to fix "error: redefinition of struct"
    # https://github.com/avast/retdec/issues/203

    if $use_decompiler_name_map; then
      new_decompiler_name=${decompiler_name_map[$decompiler_name]}
      if [ -n "$new_decompiler_name" ]; then
        decompiler_name="$new_decompiler_name"
      fi
    fi

    output_path="$(dirname "$file_path")/src/$decompiler_name-$decompiler_version/"
    output_path+="$(basename "$file_path" | sed -E 's/\.(exe|dll|o|so)$//').$output_extension"
    output_path=$(echo "$output_path" | sed 's|^\./||')

    error_path="$(dirname "$file_path")/src/$decompiler_name-$decompiler_version/error.txt"
    error_path=$(echo "$error_path" | sed 's|^\./||')

    result_hashes=""
    if [ -e "$result_hash_cache_path" ]; then
      # read cache
      result_hashes=$(grep "^sha256:$file_sha256 " "$result_hash_cache_path" | cut -d' ' -f2-)
    fi
    result_hashes_bak="$result_hashes"

    if [ -e "$output_path" ]; then
      output_hash=sha256:$(sha256sum "$output_path" | cut -d' ' -f1)
      result_hash="$decompiler_key/ok/$output_hash"
      if [[ " $result_hashes " =~ " $result_hash " ]]; then
        echo "already done: $output_path"
        done_decompiler_keys+=" $decompiler_key"
        continue
      fi
      # $output_path exists but has an unknown hash
      echo "moving existing output file to $output_path.bak-$output_hash"
      mv "$output_path" "$output_path.bak-$output_hash"
    fi

    if [ -e "$error_path" ]; then
      error_hash=$(sha256sum "$error_path" | cut -d' ' -f1)
      result_hash="$decompiler_key/error/$error_hash"
      if [[ " $result_hashes " =~ " $result_hash " ]]; then
        echo "already done: $error_path"
        done_decompiler_keys+=" $decompiler_key"
        continue
      fi
      # $error_path exists but has an unknown hash
      echo -n "moving existing error file to $error_path.bak-$error_hash"
      mv -v "$error_path" "$error_path.bak-$error_hash"
    fi

    # TODO keep only one output file
    # if success and $error_path exists then delete $error_path
    # if error and $output_path exists then delete $output_path

    error=$(echo "$result_json" | jq -r .error)

    if [[ "$error" == "Exceeded time limit" ]]; then
      # decompiler timeout. dont write error.txt
      if [ -z "${request_count_by_decompiler_key[$decompiler_key]}" ]; then
        request_count_by_decompiler_key[$decompiler_key]=1
      else
        request_count_by_decompiler_key[$decompiler_key]=$((${request_count_by_decompiler_key[$decompiler_key]} + 1))
      fi
      if ((${request_count_by_decompiler_key[$decompiler_key]} >= $requests_per_decompiler)); then
        echo "error: timeout from decompiler $decompiler_key"
        # dont retry
        done_decompiler_keys+=" $decompiler_key"
        continue
      fi
      echo "error: timeout from decompiler $decompiler_key - retrying (done ${request_count_by_decompiler_key[$decompiler_key]} of $requests_per_decompiler requests)"
      decompilation_id=$(echo "$result_json" | jq -r .id)
      # this can return html with "<title>Server Error (500)</title>"
      rerun_response="$(curl -s -X POST https://dogbolt.org/api/binaries/$binary_id/decompilations/$decompilation_id/rerun/)"
      if echo "$rerun_response" | grep -q -F "<title>Server Error (500)</title>"; then
        echo "error: the rerun API returned server error 500"
      elif [[ -n "$rerun_response" ]]; then
        echo "error: the rerun API returned something:"
        echo "$rerun_response"
      fi
      continue

    elif [[ "$error" != "null" ]]; then

      error_hash=$(echo "$error" | sha256sum - | cut -d' ' -f1)
      result_hash="$decompiler_key/error/$error_hash"
      [ -n "$result_hashes" ] && result_hashes+=" "
      result_hashes+="$result_hash"

      if $write_error_txt; then
        # write error.txt
        echo "writing $error_path"
        mkdir -p "$(dirname "$error_path")"
        echo "$error" >"$error_path"
        # remove duplicate error file
        find "$(dirname "$error_path")" -name "*.bak-$error_hash" -delete
      else
        echo "error: $decompiler_name-$decompiler_version"
      fi

    else
      # success
      download_url=$(echo "$result_json" | jq -r .download_url)

      # no. replacing existing files can be desired
      # the result may be for a different binary with the same name
      #if [ -e "$output_path" ]; then
      #  echo "keeping $output_path"
      #  continue
      #fi
      echo "writing $output_path"
      mkdir -p "$(dirname "$output_path")"
      curl -s "$download_url" >"$output_path"

      output_hash=sha256:$(sha256sum "$output_path" | cut -d' ' -f1)
      result_hash="$decompiler_key/ok/$output_hash"
      [ -n "$result_hashes" ] && result_hashes+=" "
      result_hashes+="$result_hash"

      # remove duplicate output file
      find "$(dirname "$output_path")" -name "*.bak-$output_hash" -delete
    fi

    done_decompiler_keys+=" $decompiler_key"

    if [ -z "$result_hashes_bak" ]; then
      # write cache
      mkdir -p "$(dirname "$result_hash_cache_path")"
      echo "sha256:$file_sha256 $result_hashes" >>"$result_hash_cache_path"
    else
      # the cache already has an entry for sha256:$file_sha256
      # update cache
      result_hashes_esc=$(echo "$result_hashes" | sed 's/|/\\|/g')
      sed -i "s|^sha256:$file_sha256 .*$|sha256:$file_sha256 $result_hashes_esc|" "$result_hash_cache_path"
    fi

  done

  done_decompilers_count=$(printf "%s\n" $done_decompiler_keys | wc -l)

  if ((done_decompilers_count == decompilers_count)); then
    echo "fetched all results"
    break
  fi

  echo "fetched $done_decompilers_count of $decompilers_count results. retrying in $retry_sleep seconds"
  sleep $retry_sleep
  # retry to fetch more results

done

if ((count != decompilers_count)); then
  echo "timeout after $((retry_count * retry_sleep)) seconds. fetched $count of $decompilers_count results"
fi
