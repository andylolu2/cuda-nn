#pragma once

#include <cutlass/util/device_memory.h>

#include <cute/tensor.hpp>

#include "lib/fill.h"
#include "lib/matmul_bias_bwd.cuh"
#include "lib/matmul_bias_pointwise.cuh"
#include "lib/modules/linear.cuh"
#include "lib/op/add.cuh"
#include "lib/op/constant.cuh"
#include "lib/op/sgd.cuh"
#include "lib/op/unary_pointwise.cuh"
#include "lib/tensor_ops.cuh"

using namespace cute;
using namespace cutlass;

namespace lib {
    namespace module {
        template <typename ParamType, typename GradType, typename ActivationType>
        class MLP {
            using ActivationShape = Shape<int, int>;
            using ActivationTensor =
                Tensor<ViewEngine<gmem_ptr<ActivationType>>, Layout<ActivationShape>>;
            using DActivationTensor =
                Tensor<ViewEngine<gmem_ptr<GradType>>, Layout<ActivationShape>>;

           private:
            int in_features;
            std::vector<int> feature_sizes;
            std::vector<Linear<ParamType, GradType>> layers;
            std::vector<DeviceAllocation<ActivationType>> activations_data;
            std::vector<ActivationTensor> activations;
            std::vector<DeviceAllocation<GradType>> d_activations_data;
            std::vector<DActivationTensor> d_activations;

           public:
            MLP(int in_features, std::vector<int> feature_sizes, int batch_size)
                : in_features(in_features), feature_sizes(feature_sizes) {
                // Need to reserve space for the activations_data and d_activations_data in
                // particular Otherwise the DeviceAllocation will be moved and the pointers to
                // device will be invalid.

                activations.reserve(feature_sizes.size());
                d_activations.reserve(feature_sizes.size());
                activations_data.reserve(feature_sizes.size());
                d_activations_data.reserve(feature_sizes.size());

                for (size_t i = 0; i < feature_sizes.size(); i++) {
                    int in = i == 0 ? in_features : feature_sizes[i - 1];
                    int out = feature_sizes[i];
                    bool use_relu = i != 0;

                    layers.emplace_back(in, out, use_relu);

                    if (i != feature_sizes.size() - 1) {
                        activations_data.emplace_back(batch_size * out);
                        activations.emplace_back(make_tensor(
                            make_gmem_ptr(activations_data.back().get()),
                            make_shape(batch_size, out)));

                        d_activations_data.emplace_back(batch_size * out);
                        d_activations.emplace_back(make_tensor(
                            make_gmem_ptr(d_activations_data.back().get()),
                            make_shape(batch_size, out)));
                    }
                }
            }
            ~MLP() = default;

            void init() {
                for (auto& layer : layers) {
                    layer.init();
                }
                for (auto& activation : activations) {
                    lib::op::constant(activation, ActivationType(1));
                }
            }

            void forward(ActivationTensor& x, ActivationTensor& y) {
                for (size_t i = 0; i < layers.size(); i++) {
                    auto& layer = layers[i];
                    auto& x_in = i == 0 ? x : activations[i - 1];
                    auto& x_out = i == layers.size() - 1 ? y : activations[i];
                    layer.forward(x_in, x_out);
                }
            }

            void backward(ActivationTensor& x, DActivationTensor& dy, DActivationTensor& dx) {
                for (size_t i = layers.size(); i-- > 0;) {
                    auto& layer = layers[i];
                    auto x_in = i == 0 ? x : activations[i - 1];
                    auto dx_in = i == 0 ? dx : d_activations[i - 1];
                    auto dx_out = i == layers.size() - 1 ? dy : d_activations[i];
                    layer.backward(x_in, dx_out, dx_in);
                }
            }

            void update(GradType lr) {
                for (auto& layer : layers) {
                    layer.update(lr);
                }
            }

            void clear_grad() {
                for (auto& layer : layers) {
                    layer.clear_grad();
                }
            }
        };
    }  // namespace module
}  // namespace lib