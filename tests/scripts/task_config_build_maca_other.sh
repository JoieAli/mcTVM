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

# Mirrors task_config_build_gpu_other.sh as a compiler smoke build, but keeps
# the GPU surface MACA-only for local CI reproduction.
set -euxo pipefail

BUILD_DIR=$1
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cp ../cmake/config.cmake .

echo set\(USE_MACA ON\) >> config.cmake
echo set\(USE_MCBLAS ON\) >> config.cmake
echo set\(USE_MCDNN ON\) >> config.cmake
echo set\(USE_MCFFT ON\) >> config.cmake
echo set\(USE_LLVM \"/usr/bin/llvm-config-15 --link-static\"\) >> config.cmake
echo set\(CMAKE_CXX_FLAGS \"-Werror -Wno-error=maybe-uninitialized\"\) >> config.cmake
echo set\(USE_CCACHE OFF\) >> config.cmake
echo set\(SUMMARIZE ON\) >> config.cmake
