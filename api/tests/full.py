#   Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.
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

from common_import import *


@benchmark_registry.register("full")
class PaddleFull(PaddleOpBenchmarkBase):
    def build_graph(self, config):
        result = paddle.full(
            shape=config.shape,
            fill_value=config.fill_value,
            dtype=config.dtype)

        self.feed_list = []
        self.fetch_list = [result]


@benchmark_registry.register("full")
class TorchFull(PytorchOpBenchmarkBase):
    def build_graph(self, config):
        torch_list = []
        torch_tensor = torch.tensor(config.shape, dtype=torch.float32)
        result = torch.nn.init.constant_(
            tensor=torch_tensor, val=config.fill_value)

        self.feed_list = []
        self.fetch_list = [result]


@benchmark_registry.register("full")
class TFFull(TensorflowOpBenchmarkBase):
    def build_graph(self, config):
        result = tf.constant(
            shape=config.shape,
            dtype=tf.as_dtype(config.dtype),
            value=config.fill_value)

        self.feed_list = []
        self.fetch_list = [result]
