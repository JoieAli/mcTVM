#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -euxo pipefail

cd "$(dirname "$0")/../.."

# Local core CI reproduction for lint, CPU, and the GPU Python coverage
# retargeted to MACA.
#
# Usage:
#   ./tests/scripts/task_maca_ci.sh                  # run lint + cpu + maca
#   ./tests/scripts/task_maca_ci.sh lint cpu maca    # run selected lanes
#
# This script is intentionally sequential for local reproducibility.  Jenkins
# runs many of these lanes on separate workers.

DEFAULT_STAGES=(lint cpu maca)
if [ "$#" -eq 0 ]; then
    STAGES=("${DEFAULT_STAGES[@]}")
else
    STAGES=("$@")
fi

BUILD_PREFIX="${TVM_MACA_CI_BUILD_PREFIX:-build-maca-ci}"
CLEAN_BUILDS="${TVM_MACA_CI_CLEAN_BUILDS:-1}"
DEPS_PREFIX="${TVM_MACA_CI_DEPS_PREFIX:-$(pwd)/${BUILD_PREFIX}-deps}"
COMMUNITY_DNNL_TAG="v2.6"
COMMUNITY_DNNL_VERSION="2.6"
COMMUNITY_DNNL_SHA512="4cb7b80bfe16920bc096e18e7d8caa56b9ab7a4dab2a091a230bcf562c09533392f4a4ccd4db22754a10293670efdea20382db0994dc47949005a4c77f14b64c"

function expand_stages() {
    local expanded=()
    for stage in "${STAGES[@]}"; do
        case "${stage}" in
            all)
                expanded+=("${DEFAULT_STAGES[@]}")
                ;;
            *)
                expanded+=("${stage}")
                ;;
        esac
    done
    STAGES=("${expanded[@]}")
}

function stage_header() {
    echo
    echo "===== MACA CI stage: $1 ====="
}

function prepare_build_dir() {
    local build_dir="$1"
    if [ "${CLEAN_BUILDS}" = "1" ]; then
        rm -rf "${build_dir}"
    fi
}

function build_tvm() {
    local config_script="$1"
    local build_dir="$2"
    prepare_build_dir "${build_dir}"
    "${config_script}" "${build_dir}"
    ./tests/scripts/task_build.py --build-dir "${build_dir}"
}

function rebuild_tvm() {
    local config_script="$1"
    local build_dir="$2"
    rm -rf "${build_dir}"
    "${config_script}" "${build_dir}"
    ./tests/scripts/task_build.py --build-dir "${build_dir}"
}

function abspath() {
    local path="$1"
    if [[ "${path}" = /* ]]; then
        echo "${path}"
    else
        echo "$(pwd)/${path}"
    fi
}

function community_dnnl_path() {
    abspath "${TVM_MACA_CI_DNNL_PATH:-${DEPS_PREFIX}/onednn-${COMMUNITY_DNNL_VERSION}}"
}

function ensure_community_dnnl() {
    if [ "${TVM_MACA_CI_USE_COMMUNITY_DNNL:-1}" = "0" ]; then
        return
    fi

    local install_dir
    install_dir="$(community_dnnl_path)"
    if [ -f "${install_dir}/lib/libdnnl.so" ] && [ -f "${install_dir}/include/dnnl.hpp" ]; then
        return
    fi

    local work_dir="${DEPS_PREFIX}/src"
    local archive_name="${COMMUNITY_DNNL_TAG}.tar.gz"
    local archive_path="${work_dir}/${archive_name}"
    local source_dir="${work_dir}/oneDNN-${COMMUNITY_DNNL_VERSION}"
    local build_dir="${work_dir}/oneDNN-${COMMUNITY_DNNL_VERSION}-build"
    local archive_url="https://github.com/oneapi-src/oneDNN/archive/refs/tags/${archive_name}"

    mkdir -p "${work_dir}"
    if [ ! -f "${archive_path}" ]; then
        curl -fsSL "${archive_url}" -o "${archive_path}"
    fi
    printf "%s  %s\n" "${COMMUNITY_DNNL_SHA512}" "${archive_path}" | sha512sum -c -

    rm -rf "${source_dir}" "${build_dir}"
    tar -C "${work_dir}" -xf "${archive_path}"
    cmake -S "${source_dir}" -B "${build_dir}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DDNNL_BUILD_TESTS=OFF \
        -DDNNL_BUILD_EXAMPLES=OFF
    cmake --build "${build_dir}" --parallel "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))"
    cmake --install "${build_dir}"
}

function apply_community_dnnl_config() {
    if [ "${TVM_MACA_CI_USE_COMMUNITY_DNNL:-1}" = "0" ]; then
        return
    fi

    ensure_community_dnnl

    local build_dir="$1"
    local install_dir
    install_dir="$(community_dnnl_path)"
    {
        echo "set(USE_DNNL \"${install_dir}\")"
        echo "set(CMAKE_INCLUDE_PATH \"${install_dir}/include;\${CMAKE_INCLUDE_PATH}\")"
        echo "set(CMAKE_LIBRARY_PATH \"${install_dir}/lib;\${CMAKE_LIBRARY_PATH}\")"
    } >> "${build_dir}/config.cmake"
    export TVM_MACA_CI_EXTRA_LD_LIBRARY_PATH="${install_dir}/lib:${TVM_MACA_CI_EXTRA_LD_LIBRARY_PATH:-}"
}

function build_cpptest() {
    local build_dir="$1"
    ./tests/scripts/task_build.py --cmake-target cpptest --build-dir "${build_dir}"
}

function run_unittest_shard() {
    local platform="$1"
    local shard_index="$2"
    local num_shards="$3"
    shift 3

    (
        export TVM_NUM_SHARDS="${num_shards}"
        export TVM_SHARD_INDEX="${shard_index}"
        export TEST_STEP_NAME="unittest: ${platform}"
        export SKIP_SLOW_TESTS="${SKIP_SLOW_TESTS:-0}"
        export CI="${CI:-true}"
        "$@"
    )
}

function with_tvm_build() {
    local build_dir="$1"
    local abs_build_dir
    local abs_lib_dir
    local extra_ld_path="${TVM_MACA_CI_EXTRA_LD_LIBRARY_PATH:-}"
    shift
    if [[ "${build_dir}" = /* ]]; then
        abs_build_dir="${build_dir}"
    else
        abs_build_dir="$(pwd)/${build_dir}"
    fi
    abs_lib_dir="${abs_build_dir}/lib"
    TVM_LIBRARY_PATH="${abs_lib_dir}" \
    TVM_BUILD_PATH="${abs_build_dir}" \
    LD_LIBRARY_PATH="${abs_lib_dir}:${abs_build_dir}:${extra_ld_path}${extra_ld_path:+:}${LD_LIBRARY_PATH:-}" \
        "$@"
}

function run_lint() {
    stage_header "lint"
    uv sync --group lint --no-install-project
    uv run pre-commit run --all-files
}

function run_cpu() {
    stage_header "cpu"
    local build_dir="${TVM_MACA_CI_CPU_BUILD_DIR:-${BUILD_PREFIX}-cpu}"
    prepare_build_dir "${build_dir}"
    ./tests/scripts/task_config_build_cpu.sh "${build_dir}"
    apply_community_dnnl_config "${build_dir}"
    ./tests/scripts/task_build.py --build-dir "${build_dir}"
    build_cpptest "${build_dir}"
    ./tests/scripts/task_clear_pytest.sh
    for shard in 0 1; do
        run_unittest_shard CPU "${shard}" 2 \
            with_tvm_build "${build_dir}" ./tests/scripts/task_cpp_unittest.sh "${build_dir}"
        run_unittest_shard CPU "${shard}" 2 \
            with_tvm_build "${build_dir}" ./tests/scripts/task_python_unittest.sh
    done
}

function run_maca() {
    stage_header "maca"
    local build_dir="${TVM_MACA_CI_GPU_BUILD_DIR:-${BUILD_PREFIX}-gpu-maca}"
    local other_build_dir="${TVM_MACA_CI_GPU_OTHER_BUILD_DIR:-${BUILD_PREFIX}-gpu-maca-other}"
    build_tvm ./tests/scripts/task_config_build_maca.sh "${build_dir}"
    rebuild_tvm ./tests/scripts/task_config_build_maca_other.sh "${other_build_dir}"
    ./tests/scripts/task_clear_pytest.sh
    for shard in 0 1; do
        run_unittest_shard GPU "${shard}" 2 \
            with_tvm_build "${build_dir}" ./tests/scripts/task_gpu_maca.sh
    done
}

expand_stages
for stage in "${STAGES[@]}"; do
    case "${stage}" in
        lint)
            run_lint
            ;;
        cpu)
            run_cpu
            ;;
        maca)
            run_maca
            ;;
        *)
            echo "Unknown stage '${stage}'. Expected one of: all lint cpu maca" >&2
            exit 2
            ;;
    esac
done
