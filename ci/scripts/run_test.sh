#!/usr/bin/env bash

# Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#=================================================
#                   Utils
#=================================================

set +ex

function LOG {
  echo [$0:${BASH_LINENO[0]}] $* >&2
}

LOG "[INFO] Start run op benchmark test ..."

BENCHMARK_ROOT=$(cd $(dirname $0)/../.. && pwd)
[ -z "$CUDA_VISIBLE_DEVICES" ] && CUDA_VISIBLE_DEVICES="0"

function prepare_env(){
  num_changed_files=$(git diff --name-only master | grep -E "api/(common)?(dynamic_)?(tests)?(_v2)?/(.*\.py|configs/.*\.json)" | wc -l)
  if [ ${num_changed_files} -eq 0 ]; then
    LOG "[INFO] This pull request doesn't change any files of op benchmark, skip the CI."
    exit 0
  fi

  LOG "[INFO] Device Id: ${CUDA_VISIBLE_DEVICES}"
  # Update pip
  LOG "[INFO] Update pip ..."
  env http_proxy="" https_proxy="" pip install -U pip > /dev/null
  [ $? -ne 0 ] && LOG "[FATAL] Update pip failed!" && exit -1

  PADDLE_WHL="paddlepaddle_gpu-0.0.0-cp37-cp37m-linux_x86_64.whl"
  if [ ! -f "${PADDLE_WHL}" ]
  then
    # if develop compiling failed, install the latest nightly built paddle
    PADDLE_WHL="paddlepaddle_gpu-0.0.0.post101-cp37-cp37m-linux_x86_64.whl"
    PADDLE_URL="https://paddle-wheel.bj.bcebos.com/develop/linux/linux-gpu-cuda10.1-cudnn7-mkl-gcc5.4-avx/${PADDLE_WHL}"
    LOG "[INFO] Downloading paddle wheel from ${PADDLE_URL}, this could take a few minutes ..."
    wget -q -O ${PADDLE_WHL} ${PADDLE_URL}
    [ $? -ne 0 ] && LOG "[FATAL] Download paddle wheel failed!" && exit -1
  fi
  LOG "[INFO] Installing paddlepaddle, this could take a few minutes ..."
  env http_proxy="" https_proxy="" pip install -U ${PADDLE_WHL} > /dev/null
  [ $? -ne 0 ] && LOG "[FATAL] Install paddle failed!" && exit -1
  
  # Install tensorflow, pytorch and other packages
  for package in "torch==1.12.0" "torchvision" "tensorflow==2.3.0" "tensorflow-probability" "pre-commit==1.21" "pylint==1.9.4" "pytest==4.6.9"
  do
    LOG "[INFO] Installing $package, this could take a few minutes ..."
    env http_proxy="" https_proxy="" pip install $package -i https://pypi.tuna.tsinghua.edu.cn/simple > /dev/null
    [ $? -ne 0 ] && LOG "[FATAL] Install $package failed!" && exit -1
  done
  python -c "import tensorflow as tf; print(tf.__version__)" > /dev/null
  [ $? -ne 0 ] && LOG "[FATAL] Install tensorflow success, but it can't work!" && exit -1
  python -c "import torch ; print(torch.__version__)" > /dev/null
  [ $? -ne 0 ] && LOG "[FATAL] Install pytorch success, but it can't work!" && exit -1
  
  apt-get update > /dev/null 2> /dev/null
}

function run_api(){
  LOG "[INFO] Start run api test ..."
  API_NAMES=()
  for file in $(git diff --name-only master | grep -E "api/(dynamic_)?tests(_v2)?/(.*\.py|configs/.*\.json)")
  do
    LOG "[INFO] Found ${file} modified."
    api=${file#*api/} && api=${api%.*}
    [[ "$api" =~ "common_import" ]] && continue
    [[ "$api" =~ "test_main" ]] && continue
    [[ "$api" =~ "__init__" ]] && continue
    [ -f "${BENCHMARK_ROOT}/api/${api}.py" ] && API_NAMES[${#API_NAMES[@]}]=$api
    if [[ "$file" =~ ".json" ]]
    then
      [ -f "${BENCHMARK_ROOT}/api/${api/configs\//}.py" ] && API_NAMES[${#API_NAMES[@]}]=${api/configs\//}
      for sub_file in $(grep -l "APIConfig(.${api##*/}.)" ${BENCHMARK_ROOT}/api/tests_v2/*.py)
      do
        sub_api=${sub_file#*api/} && sub_api=${sub_api%.*}
      done
    fi
  done
  API_NAMES=($(echo ${API_NAMES[@]} | tr ' ' '\n' | sort | uniq))
  [ -z "$(echo ${API_NAMES[@]} | grep -w 'tests_v2')" ] && API_NAMES[${#API_NAMES[@]}]=tests_v2/abs
  [ -z "$(echo ${API_NAMES[@]} | grep -w 'dynamic_tests_v2')" ] && API_NAMES[${#API_NAMES[@]}]=dynamic_tests_v2/abs
  LOG "[INFO] These APIs will run: ${API_NAMES[@]}"
  fail_name=()
  for name in ${API_NAMES[@]}
  do
    for device_type in "GPU"
    do
      [ $device_type == "GPU" ] && device_limit="" || device_limit="env CUDA_VISIBLE_DEVICES="
      ${device_limit} bash ${BENCHMARK_ROOT}/api/${name%/*}/run.sh ${name##*/} -1 accuracy >&2
      [ $? -ne 0 ] && fail_name[${#fail_name[@]}]="${name}(Run on ${device_type})"
    done
  done
  if [ ${#fail_name[@]} -ne 0 ]
  then
    LOG "[FATAL] Failed API tests: ${fail_name[@]}"
    echo ${fail_name[@]}
    exit -1
  fi
}

function check_style(){
  LOG "[INFO] Start check code style ..."
  # uninstall pre-commit firstly to avoid using old data
  pre-commit uninstall >&2
  pre-commit install >&2
  commit_files=on
  LOG "[INFO] Check code style via per-commit, this could take a few minutes ..."
  filenames=$(git diff --name-only upstream/master)
  env http_proxy="" https_proxy="" pre-commit run --files $filenames >&2 || commit_files=off
  [ $commit_files == 'off' ] && git diff && return -1 || return 0
}

function summary_problems(){
  local check_style_code=$1
  local check_style_info=$2
  local run_api_code=$3
  local run_api_info=$4
  if [ $check_style_code -ne 0 -o $run_api_code -ne 0 ]
  then
    LOG "[FATAL] ============================================"
    LOG "[FATAL] Summary problems:"
    if [ $check_style_code -ne 0 -a $run_api_code -ne 0 ]
    then
      LOG "[FATAL] There are 2 errors: Code style error and API test error."
    else
      [ $check_style_code -ne 0 ] && LOG "[FATAL] There is 1 error: Code style error."
      [ $run_api_code -ne 0 ] && LOG "[FATAL] There is 1 error: API test error."
    fi
    LOG "[FATAL] ============================================"
    if [ $check_style_code -ne 0 ]
    then
      LOG "[FATAL] === Code style error - Please fix it according to the diff information:"
      echo "$check_style_info"
    fi
    if [ $run_api_code -ne 0 ]
    then
      LOG "[FATAL] === API test error - Please fix the failed API tests accroding to fatal log:"
      LOG "[FATAL] $run_api_info"
    fi
    [ $check_style_code -ne 0 ] && exit $check_style_code
    [ $run_api_code -ne 0 ] && exit $run_api_code
  fi
}

function main(){
  prepare_env
  check_style_info=$(check_style)
  check_style_code=$?
  # `check_style_info` is empty means the check passed even if there are errors.
  [ -z "${check_style_info}" ] && check_style_code=0
  run_api_info=$(run_api)
  run_api_code=$?
  summary_problems $check_style_code "$check_style_info" $run_api_code "$run_api_info"
  LOG "[INFO] Op benchmark run success and no error!"
}

main
